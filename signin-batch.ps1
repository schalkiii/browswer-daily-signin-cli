param(
    [string]$ConfigFile = "$PSScriptRoot\sites.json",
    [string]$ResultFile = "$PSScriptRoot\signin-log.json",
    [string]$WebArticlesDir = "$PSScriptRoot\web-articles",
    [string]$FeishuChatId = "",
    [string]$FeishuWebhook = ""
)

$ErrorActionPreference = "Continue"

if ($PSVersionTable.PSVersion.Major -lt 6) {
    Write-Error "signin-batch.ps1 需要 PowerShell 7+ (pwsh.exe)，当前版本为 $($PSVersionTable.PSVersion)。请安装 https://aka.ms/powershell"
    exit 1
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$results = @()

# kimi webbridge 集成
. "$PSScriptRoot\signin-web.ps1"

# === 从 config.json 加载集中配置（飞书、浏览器路径等） ===
$GlobalCfg = $null
$GlobalCfgPath = Join-Path $PSScriptRoot "config.json"
if (Test-Path $GlobalCfgPath) {
    try { $GlobalCfg = Get-Content $GlobalCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Write-Output "[WARN] config.json parse error, using built-in defaults"
    }
}

if (-not (Test-Path $ConfigFile)) { Write-Output "[ERROR] Config not found: $ConfigFile"; exit 1 }
$configRaw = Get-Content $ConfigFile -Raw -Encoding UTF8
$configRaw = $configRaw -replace '^\uFEFF', ''
$config = $configRaw | ConvertFrom-Json

# 飞书配置优先级: 命令行参数 > config.json > sites.json（旧字段, 向后兼容）
if ([string]::IsNullOrEmpty($FeishuWebhook) -and $GlobalCfg -and $GlobalCfg.feishu) {
    if ($GlobalCfg.feishu.webhook) { $FeishuWebhook = $GlobalCfg.feishu.webhook }
    if ([string]::IsNullOrEmpty($FeishuChatId) -and $GlobalCfg.feishu.chatId) {
        $FeishuChatId = $GlobalCfg.feishu.chatId
    }
}
if ([string]::IsNullOrEmpty($FeishuWebhook) -and $config.feishu) {
    if ($config.feishu.webhook) { $FeishuWebhook = $config.feishu.webhook }
    if ([string]::IsNullOrEmpty($FeishuChatId) -and $config.feishu.chatId) {
        $FeishuChatId = $config.feishu.chatId
    }
}

# Reset signals
$signals = @{ ok = $false; ok_sites = @(); fail_sites = @(); skip_sites = @(); login_expired = @() }

# === BASELINE: load known-successful sites for regression detection ===
$BaselineFile = if ($config.baseline_file) { "$PSScriptRoot\$($config.baseline_file)" } else { "$PSScriptRoot\baseline.json" }
$baseline = @{ sites = @(); manual_sites = @() }
if (Test-Path $BaselineFile) {
    try {
        $braw = Get-Content $BaselineFile -Raw -Encoding UTF8
        $braw = $braw -replace '^\uFEFF', ''
        $baseline = $braw | ConvertFrom-Json
    } catch {
        Write-Output "[WARN] baseline.json parse error, starting fresh"
        $baseline = @{ sites = @(); manual_sites = @() }
    }
}
$tracking = @{ new_sites = @(); regressions = @(); exploratory_total = 0 }
Write-Output "Baseline: $($baseline.sites.Count) known-success sites"

# Signal check function - the deterministic pass/fail signal
function Test-SignIn($session) {
    $checkJS = @'
(function(){var t=document.body.innerText||'';if(t.indexOf('\u7B7E\u5230\u6210\u529F')>-1||t.indexOf('\u7C3D\u5230\u6210\u529F')>-1)return'SIGN_OK';if(t.indexOf('\u7B7E\u5230\u5DF2\u5F97')>-1||t.indexOf('\u7C3D\u5230\u5DF2\u5F97')>-1||t.indexOf('\u7B7E\u5230\u5F97')>-1||t.indexOf('\u7C3D\u5230\u5F97')>-1)return'SIGN_OK';if(t.indexOf('\u5DF2\u7B7E\u5230')>-1||t.indexOf('\u5DF2\u7C3D\u5230')>-1)return'SIGN_OK';if(t.indexOf('\u8FD9\u662F\u60A8\u7684\u7B2C')>-1||t.indexOf('\u9019\u662F\u60A8\u7684\u7B2C')>-1)return'SIGN_OK';if(t.indexOf('\u7B7E\u5230\u83B7\u5F97')>-1||t.indexOf('\u7C3D\u5230\u7372\u5F97')>-1)return'SIGN_OK';if(t.indexOf('Already checked')>-1||t.indexOf('Daily Bonus')>-1)return'SIGN_OK';if(t.indexOf('\u6BCF\u65E5\u767B\u5F55\u5956\u52B1\u5DF2\u9886\u53D6')>-1)return'SIGN_OK';if(t.indexOf('\u6253\u5361\u6210\u529F')>-1||t.indexOf('\u5DF2\u5B8C\u6210')>-1)return'SIGN_OK';if(t.indexOf('\u7B7E\u5230\u9886\u5956')>-1)return'SIGN_OK';if(t.indexOf('\u7B7E\u5230\u5B8C\u6210')>-1)return'SIGN_OK';if(t.indexOf('\u8FDE\u7EED\u7B7E\u5230')>-1)return'SIGN_OK';if(t.indexOf('\u83B7\u5F97\u5956\u52B1')>-1||t.indexOf('\u7372\u5F97\u5956\u52F5')>-1)return'SIGN_OK';if(t.indexOf('cf-turnstile')>-1||t.indexOf('challenges.cloudflare')>-1||t.indexOf('\u5B89\u5168\u9A57\u8B49')>-1||t.indexOf('\u5B89\u5168\u9A8C\u8BC1')>-1)return'CF_CHALLENGE';if(t.indexOf('\u8BF7\u7A0D\u5019')>-1)return'WAITING';if(t.indexOf('\u6ED1\u52A8')>-1||t.indexOf('\u62D6\u52A8\u6ED1\u5757')>-1)return'SLIDER';if(t.indexOf('\u8BF7\u767B\u5F55')>-1||t.indexOf('\u5FC5\u9808\u767B\u9304')>-1)return'LOGIN_REQUIRED';if(t.indexOf('\u6B22\u8FCE\u56DE\u6765')>-1||t.indexOf('\u6B61\u8FCE\u56DE\u4F86')>-1)return'LOGGED_IN';return'UNKNOWN';})()
'@
    $result = opencli browser $session eval $checkJS 2>&1
    $combined = if ($result -is [array]) { $result -join "`n" } else { [string]$result }
    $allMatches = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($combined -split '\r?\n')) {
        if ($line -match '\b(SIGN_OK|CF_CHALLENGE|WAITING|SLIDER|LOGIN_REQUIRED|LOGGED_IN|UNKNOWN)\b') {
            $allMatches.Add($matches[1])
        }
    }
    if ($allMatches.Count -gt 0) {
        return $allMatches[0].Trim()
    } else {
        return "ERROR_NO_SIGNAL"
    }
}

function Wait-PageReady($session, $maxWaitSec) {
    $readyJS = @'
(function(){ return document.readyState || 'unknown'; })()
'@
    $end = (Get-Date).AddSeconds($maxWaitSec)
    while ((Get-Date) -lt $end) {
        $out = opencli browser $session eval $readyJS 2>&1
        $resultStr = if ($out -is [array]) { $out -join "`n" } else { [string]$out }
        if ($resultStr -match 'complete') { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Browser-SignIn($site, $session) {
    $r = @{ status = "UNKNOWN"; signal = "" }
    $baseWait = 8
    if ($site.note -match "CF") { $baseWait = 15 }
    if ($site.name -eq "UBits") { $baseWait = 15 }

    $null = opencli browser $session open $site.url 2>&1
    Start-Sleep -Seconds $baseWait

    $ready = Wait-PageReady $session 5
    if (-not $ready) { Write-Output "  [WARN] page not ready after ${baseWait}s" }

    $signal = Test-SignIn $session
    $r.signal = $signal

    if ($signal -eq "UNKNOWN" -or $signal -eq "CF_CHALLENGE") {
        Write-Output "  [RETRY] signal=$signal, waiting 10s..."
        Start-Sleep -Seconds 10
        $signal = Test-SignIn $session
        $r.signal = $signal
    }

    switch ($signal) {
        "SIGN_OK"       { $r.status = "SUCCESS" }
        "CF_CHALLENGE"  { $r.status = "CF_BLOCKED" }
        "SLIDER"        { $r.status = "SLIDER" }
        "LOGIN_REQUIRED"{ $r.status = "NO_LOGIN" }
        "LOGGED_IN"     { $r.status = "LOGGED_IN" }
        "UNKNOWN"       { $r.status = "NO_DETECT" }
        default         { $r.status = "ERROR"; $r.signal = $signal }
    }
    return $r
}

# === SELF-ITERATION: Web page change detection & auto-repair ===

$script:iterationLog = @()
$iterationLogFile = "$PSScriptRoot\iterations.json"
if (Test-Path $iterationLogFile) {
    try { $script:iterationLog = @(Get-Content $iterationLogFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $script:iterationLog = @() }
}

function Save-IterationLog {
    $script:iterationLog | ConvertTo-Json -Depth 3 | Out-File $iterationLogFile -Encoding UTF8
}

function Get-PageContent($session) {
    $dumpJS = @'
(function(){var t=document.body.innerText||'';return t.substring(0,800).replace(/[\r\n]+/g,'\\n');})()
'@
    $out = opencli browser $session eval $dumpJS 2>&1
    $resultStr = if ($out -is [array]) { $out -join "`n" } else { [string]$out }
    $content = ($resultStr -split '\r?\n' | Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch 'Warning:|Update available|npm install|node --trace' } | Select-Object -First 1)
    if ($null -eq $content) { return "" }
    return $content.Trim()
}

function Find-NewSignPatterns($content) {
    $found = @()
    if ($content -match '(sign.?in|check.?in|attendance|sign|check)') {
        $found += "has sign-in related text"
    }
    return $found
}

function Invoke-FreeFarmTokenRefresh {
    param($session, $siteName, $configFile)
    Write-Output "  [ITER] Attempting FreeFarm token refresh..."
    try {
        $scriptsOut = opencli browser $session eval @'
JSON.stringify(Array.from(document.querySelectorAll('script[src]')).map(s=>s.src))
'@ 2>&1 | Out-String
        $scriptsJson = ($scriptsOut -split '\r?\n' | Where-Object { $_ -match 'slide_check_' } | Select-Object -First 1)
        if (-not $scriptsJson) {
            Write-Output "  [ITER] No slide_check script found in page"
            return $false
        }
        $slideUrl = ($scriptsJson -replace '.*"(https://pt\.0ff\.cc/slide_check_[^"]+\.js)".*', '$1')
        if ($slideUrl -notmatch 'slide_check_') {
            Write-Output "  [ITER] Could not extract slide URL from: $scriptsJson"
            return $false
        }
        Write-Output "  [ITER] Slide JS: $slideUrl"

        $fetchJS = "fetch('$slideUrl').then(r=>r.text())"
        $jsOut = opencli browser $session eval $fetchJS 2>&1 | Out-String
        $tokenMatch = [regex]::Match($jsOut, 'https://pt\.0ff\.cc/set_access_token-[a-f0-9]+-[a-f0-9]+-YWNs-\d+\+5Yiw-')
        if (-not $tokenMatch.Success) {
            Write-Output "  [ITER] No set_access_token URL found in slide JS"
            return $false
        }
        $newTokenUrl = $tokenMatch.Value
        Write-Output "  [ITER] New token: $newTokenUrl"

        $cfgRaw145 = Get-Content $configFile -Raw -Encoding UTF8
        $cfgRaw145 = $cfgRaw145 -replace '^\uFEFF', ''
        $cfg = $cfgRaw145 | ConvertFrom-Json
        foreach ($s in $cfg.sites) {
            if ($s.name -eq $siteName) {
                $newEval = "fetch('$newTokenUrl').then(()=>setTimeout(()=>location.reload(),2000))"
                $s.eval = $newEval
            }
        }
        $cfg | ConvertTo-Json -Depth 4 | Out-File $configFile -Encoding UTF8
        Write-Output "  [ITER] sites.json updated with new token"

        opencli browser $session eval "fetch('$newTokenUrl').then(()=>setTimeout(()=>location.reload(),2000))" 2>&1 | Out-Null
        Start-Sleep -Seconds 10

        $script:iterationLog += @{
            timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            site = $siteName
            action = "token_refresh"
            oldToken = $site.eval
            newToken = $newEval
        }
        Save-IterationLog
        return $true
    } catch {
        Write-Output "  [ITER] Token refresh error: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-WebReadFallback {
    param($site, $session)
    Write-Output "  [ITER] web-read failed, attempting browser-open fallback..."
    try {
        opencli browser $session open $site.url 2>&1 | Out-Null
        Start-Sleep -Seconds 10
        $content = Get-PageContent $session
        $patterns = Find-NewSignPatterns $content
        Write-Output "  [ITER] Page content (200 chars): $($content.Substring(0, [Math]::Min(200, $content.Length)))"
        Write-Output "  [ITER] Detected patterns: $($patterns -join ', ')"

        if ($content -match "cf-turnstile|Cloudflare|Ray ID|challenges.cloudflare|just a moment") {
            Write-Output "  [ITER] Site now behind CF challenge -> recommend switching to browser-open+CF"
            $script:iterationLog += @{
                timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                site = $site.name
                action = "cf_detected_on_webread"
                content = $content.Substring(0, [Math]::Min(500, $content.Length))
            }
            Save-IterationLog
            try { opencli browser $session close 2>&1 | Out-Null } catch {}
            return @{ status = "CF_DETECTED"; signal = "CF_ON_WEBREAD" }
        }

        $signal = Test-SignIn $session
        try { opencli browser $session close 2>&1 | Out-Null } catch {}
        return @{ status = $signal; signal = $signal }
    } catch {
        Write-Output "  [ITER] Fallback error: $($_.Exception.Message)"
        try { opencli browser $session close 2>&1 | Out-Null } catch {}
        return @{ status = "FALLBACK_ERROR"; signal = $_.Exception.Message }
    }
}

function Invoke-PatternDiscovery {
    param($session, $siteName)
    Write-Output "  [ITER] Discovering page content for unknown signal..."
    try {
        $content = Get-PageContent $session
        $signal = Test-SignIn $session
        $found = ($signal -eq "SIGN_OK" -or $signal -eq "LOGGED_IN")
        Write-Output "  [ITER] Browser sign-in signal: $signal"
        Write-Output "  [ITER] Content preview (200 chars): $($content.Substring(0, [Math]::Min(200, $content.Length)))"

        $script:iterationLog += @{
            timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            site = $siteName
            action = "pattern_discovery"
            signal = $signal
            contentPreview = $content.Substring(0, [Math]::Min(500, $content.Length))
        }
        Save-IterationLog
        return @{ found = $found; signal = $signal }
    } catch {
        Write-Output "  [ITER] Discovery error: $($_.Exception.Message)"
        return @{ found = $false; signal = "ERROR" }
    }
}

function Sync-Bookmarks {
    param($ConfigFile, $ConfigObject)
    $bookmarkFile = if ($GlobalCfg -and $GlobalCfg.browser -and $GlobalCfg.browser.userDataPath -and $GlobalCfg.browser.profilePath) {
        Join-Path $GlobalCfg.browser.userDataPath (Join-Path $GlobalCfg.browser.profilePath "Bookmarks")
    } else {
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks"
    }
    $bookmarkFolderPattern = if ($GlobalCfg -and $GlobalCfg.browser -and $GlobalCfg.browser.bookmarkFolder) {
        [regex]::Escape($GlobalCfg.browser.bookmarkFolder)
    } else {
        'PT.*签到|签到|Sign|signin|checkin'
    }
    if (-not (Test-Path $bookmarkFile)) {
        Write-Output "[SYNC] Edge bookmarks not found, skipping sync"
        return $ConfigObject
    }
    Write-Output "[SYNC] Scanning Edge bookmarks..."
    $bookmarks = Get-Content $bookmarkFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $bookmarkUrls = [System.Collections.Generic.List[string]]::new()
    function Walk-BookmarkNodes($node, $list) {
        if ($node.type -eq 'folder') {
            if ($node.name -match $bookmarkFolderPattern) {
                foreach ($child in $node.children) {
                    if ($child.type -eq 'url') { $list.Add($child.url) }
                }
            }
            foreach ($child in $node.children) { Walk-BookmarkNodes $child $list }
        }
    }
    Walk-BookmarkNodes $bookmarks.roots.bookmark_bar $bookmarkUrls
    $bookmarkUrls = $bookmarkUrls | Select-Object -Unique
    if ($bookmarkUrls.Count -eq 0) {
        Write-Output "[SYNC] No PT签到 bookmarks found, keeping all existing sites"
        return $ConfigObject
    }
    Write-Output "[SYNC] Found $($bookmarkUrls.Count) bookmark URLs"
    $bookmarkDomains = @{}
    foreach ($url in $bookmarkUrls) {
        try {
            $uri = [uri]$url
            $domain = $uri.Host -replace '^www\.', ''
            if (-not $bookmarkDomains.ContainsKey($domain)) { $bookmarkDomains[$domain] = $url }
        } catch {}
    }
    $currentSites = @($ConfigObject.sites)
    $newSites = [System.Collections.Generic.List[object]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    $added = [System.Collections.Generic.List[string]]::new()
    foreach ($site in $currentSites) {
        try {
            $siteDomain = ([uri]$site.url).Host -replace '^www\.', ''
            if ($bookmarkDomains.ContainsKey($siteDomain)) {
                $newSites.Add($site)
                $bookmarkDomains.Remove($siteDomain)
            } else {
                $removed.Add("$($site.name) ($siteDomain)")
            }
        } catch { $newSites.Add($site) }
    }
    foreach ($domain in $bookmarkDomains.Keys) {
        $url = $bookmarkDomains[$domain]
        $parts = $domain -split '\.'
        $nameGuess = if ($parts.Count -ge 3) { $parts[-2] } else { $parts[0] }
        $strategy = if ($url -match 'attendance\.php') { 'web-read' } else { 'browser-open' }
        $newSite = [PSCustomObject]@{
            name = $nameGuess
            url = $url
            strategy = $strategy
            note = 'auto: 书签同步新增'
        }
        $newSites.Add($newSite)
        $added.Add("$nameGuess ($url)")
    }
    if ($removed.Count -gt 0) {
        Write-Output "[SYNC] Removed: $($removed -join ', ')"
    }
    if ($added.Count -gt 0) {
        Write-Output "[SYNC] Added: $($added -join ', ')"
    }
    if ($removed.Count -gt 0 -or $added.Count -gt 0) {
        $ConfigObject.sites = @($newSites)
        $ConfigObject.total = $newSites.Count
        $json = $ConfigObject | ConvertTo-Json -Depth 5
        $json | Out-File $ConfigFile -Encoding UTF8
        Write-Output "[SYNC] Done: total=$($newSites.Count) (-$($removed.Count) +$($added.Count))"
    } else {
        Write-Output "[SYNC] No changes"
    }
    return $ConfigObject
}

$config = Sync-Bookmarks $ConfigFile $config

# Cleanup old articles
if (Test-Path $WebArticlesDir) {
    Get-ChildItem $WebArticlesDir -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $WebArticlesDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Output "=== PT Sign-in v3.8 (self-iterating + baseline + forum click + cleanup + bookmark-sync) ==="
Write-Output "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Sites: $($config.sites.Count)"
Write-Output ""

$script:scriptStart = Get-Date

$total = $config.sites.Count

# Track site result against baseline: detect new successes and regressions
function Track-Baseline($siteName, $status) {
    $inBaseline = $siteName -in $baseline.sites
    $isManual = $status -eq "SKIPPED"
    if ($isManual) { return }
    if ($status -eq "SUCCESS" -or $status -eq "ALREADY_DONE" -or $status -eq "LOGGED_IN" -or $status -eq "VISITED") {
        if (-not $inBaseline) {
            $tracking.new_sites += $siteName
            $baseline.sites += $siteName
        }
    } else {
        if ($inBaseline) {
            $tracking.regressions += $siteName
        } else {
            $tracking.exploratory_total++
        }
    }
}

# webbridge daemon 健康检查：不可用时自动清理 pid 并重启
$script:webbridgeAvailable = Ensure-WebBridgeDaemon

foreach ($site in $config.sites) {
    $idx = $config.sites.IndexOf($site) + 1
    $session = "pt$idx"
    $start = Get-Date
    $r = @{ index = $idx; name = $site.name; url = $site.url; strategy = $site.strategy; status = "UNKNOWN"; signal = ""; elapsed = "" }

    Write-Output "[$idx/$total] $($site.name) [$($site.strategy)]"

    try {
        switch ($site.strategy) {
            "web-read" {
                $before = @(Get-ChildItem $WebArticlesDir -Directory -EA SilentlyContinue | % Name)
                opencli web read --url $site.url 2>&1 | Out-Null
                Start-Sleep -Seconds 3
                $after = @(Get-ChildItem $WebArticlesDir -Directory -EA SilentlyContinue | % Name)
                $newDir = $after | Where-Object { $_ -notin $before } | Select-Object -First 1

                if ($newDir) {
                    $md = Get-ChildItem "$WebArticlesDir\$newDir\*.md" -EA SilentlyContinue | Select-Object -First 1
                    if ($md) {
                        $c = Get-Content $md.FullName -Raw -EA SilentlyContinue
                        if ($c -match 'Already checked' -or ($md.Length -gt 2000 -and $c -notmatch 'cf-turnstile')) {
                            $r.status = "SUCCESS"; $r.signal = "SIGN_OK"
                            $signals.ok_sites += $site.name; Write-Output "  => SUCCESS"
                        } elseif ($md.Length -lt 800) {
                            $r.status = "CAPTCHA"; $r.signal = "TOO_SMALL"
                            $signals.fail_sites += $site.name; Write-Output "  => TOO_SMALL"
                        } elseif ($c -match 'cf-turnstile') {
                            $r.status = "CAPTCHA"; $r.signal = "CF_DETECTED"
                            $signals.fail_sites += $site.name; Write-Output "  => CF_DETECTED"
                        } else {
                            $r.status = "NO_DETECT"; $r.signal = "UNKNOWN"
                            $signals.fail_sites += $site.name; Write-Output "  => NO_DETECT"
                        }
                    } else { $r.status = "NO_ARTICLE"; $signals.fail_sites += $site.name }
                } else { $r.status = "NO_ARTICLE"; $signals.fail_sites += $site.name }

                if ($r.status -ne "SUCCESS") {
                    Write-Output "  [ITER] web-read failed (status=$($r.status)), running fallback..."
                    $fb = Invoke-WebReadFallback $site $session
                    if ($fb.status -eq "SIGN_OK") {
                        $r.status = "SUCCESS"; $r.signal = "SIGN_OK_ITER"
                        $signals.fail_sites = @($signals.fail_sites | Where-Object { $_ -ne $site.name })
                        $signals.ok_sites += $site.name
                        Write-Output "  => ITER_FIX: SIGN_OK via browser-open"
                    } else {
                        Write-Output "  => ITER: fallback also failed ($($fb.status))"
                    }
                }
            }
            "browser-open" {
                if ($site.note -match "webbridge") {
                    if (-not $script:webbridgeAvailable) {
                        $r.status = "SKIPPED"; $r.signal = "DAEMON_DOWN"
                        $signals.skip_sites += $site.name; Write-Output "  => SKIPPED (webbridge daemon 不可用)"
                    } else {
                        $wbResult = Invoke-WebSignIn $site.name
                        $r.signal = $wbResult
                        switch -Wildcard ($wbResult) {
                            "SIGN_OK"       { $r.status = "SUCCESS"; $signals.ok_sites += $site.name; Write-Output "  => SIGN_OK (webbridge)" }
                            "LOGIN_REQUIRED"{ $r.status = "NO_LOGIN"; $signals.login_expired += $site.name; Write-Output "  => NO_LOGIN" }
                            "CF_CHALLENGE"  { $r.status = "CF_BLOCKED"; $signals.fail_sites += $site.name; Write-Output "  => CF_BLOCKED" }
                            "SLIDER"        { $r.status = "SLIDER_FAIL"; $signals.fail_sites += $site.name; Write-Output "  => SLIDER_FAIL" }
                            "NAV_FAIL"      { $r.status = "TIMEOUT"; $signals.fail_sites += $site.name; Write-Output "  => TIMEOUT" }
                            "NO_CONFIG"     { $r.status = "SKIPPED"; $signals.skip_sites += $site.name; Write-Output "  => NO_CONFIG" }
                            "BODY_NULL"     { $r.status = "PAGE_ERROR"; $signals.fail_sites += $site.name; Write-Output "  => PAGE_ERROR (body null)" }
                            "REDIRECTING"   { $r.status = "PAGE_ERROR"; $signals.fail_sites += $site.name; Write-Output "  => REDIRECTING" }
                            default         { $r.status = "NO_DETECT"; $signals.fail_sites += $site.name; Write-Output "  => $wbResult (webbridge)" }
                        }
                        # 失败重试：CF_BLOCKED / SLIDER_FAIL / PAGE_ERROR / NO_DETECT / TIMEOUT 最多重试 2 次
                        $retryable = @("CF_BLOCKED", "SLIDER_FAIL", "PAGE_ERROR", "NO_DETECT", "TIMEOUT")
                        if ($r.status -in $retryable) {
                            for ($retry = 1; $retry -le 2; $retry++) {
                                Write-Output "  [RETRY $retry/2] $($site.name) - waiting 10s..."
                                Start-Sleep -Seconds 10
                                $wbResult2 = Invoke-WebSignIn $site.name
                                $r.signal = $wbResult2
                                if ($wbResult2 -eq "SIGN_OK") {
                                    $r.status = "SUCCESS"
                                    $signals.fail_sites = @($signals.fail_sites | Where-Object { $_ -ne $site.name })
                                    $signals.ok_sites += $site.name
                                    Write-Output "  => SIGN_OK (webbridge retry $retry)"
                                    break
                                }
                                Write-Output "  [RETRY $retry/2] $site.name => $wbResult2"
                            }
                        }
                    }
                } else {
                    $br = Browser-SignIn $site $session
                    $r.signal = $br.signal
                    $r.status = $br.status
                    if ($r.status -eq "SUCCESS") {
                        $signals.ok_sites += $site.name; Write-Output "  => SIGN_OK"
                    } else {
                        $signals.fail_sites += $site.name; Write-Output "  => $($r.status)"
                        if ($r.status -eq "NO_DETECT" -or $r.status -eq "UNKNOWN") {
                            Write-Output "  [ITER] Running pattern discovery..."
                            $pdResult = Invoke-PatternDiscovery $session $site.name
                            if ($pdResult.found) {
                                Write-Output "  [ITER] Sign-in text FOUND in page! Possible false negative."
                                Write-Output "  [ITER] Signal from browser: $($pdResult.signal)"
                            }
                        }
                    }
                    try { opencli browser $session close 2>&1 | Out-Null } catch {}
                }
            }
            "browser-eval" {
                opencli browser $session open $site.url 2>&1 | Out-Null
                Start-Sleep -Seconds 5
                opencli browser $session eval $site.eval 2>&1 | Out-Null
                Start-Sleep -Seconds 10
                $signal = Test-SignIn $session
                if ($signal -eq "UNKNOWN" -or $signal -eq "CF_CHALLENGE") {
                    Write-Output "  [RETRY] signal=$signal, waiting 8s more..."
                    Start-Sleep -Seconds 8
                    $signal = Test-SignIn $session
                    Write-Output "  [RETRY] result=$signal"
                }
                $r.signal = $signal
                switch ($signal) {
                    "SIGN_OK"  { $r.status = "SUCCESS"; $signals.ok_sites += $site.name; Write-Output "  => SIGN_OK" }
                    "SLIDER"   {
                        $r.status = "SLIDER_FAIL"; $signals.fail_sites += $site.name; Write-Output "  => SLIDER_FAIL"
                        if ($site.name -eq "FreeFarm") {
                            Write-Output "  [ITER] Detected FreeFarm token expiry, refreshing..."
                            $refreshed = Invoke-FreeFarmTokenRefresh $session $site.name $ConfigFile
                            if ($refreshed) {
                                $signal = Test-SignIn $session
                                $r.signal = $signal
                                if ($signal -eq "SIGN_OK") {
                                    $r.status = "SUCCESS"
                                    $signals.fail_sites = @($signals.fail_sites | Where-Object { $_ -ne $site.name })
                                    $signals.ok_sites += $site.name
                                    Write-Output "  => ITER_FIX: SIGN_OK after token refresh"
                                } else {
                                    Write-Output "  => ITER: refresh applied but signal=$signal"
                                }
                            }
                        }
                    }
                    default    { $r.status = "EVAL_FAIL"; $signals.fail_sites += $site.name; Write-Output "  => $signal" }
                }
                try { opencli browser $session close 2>&1 | Out-Null } catch {}
            }
            "browser-eval-click" {
                opencli browser $session open $site.url 2>&1 | Out-Null
                Start-Sleep -Seconds 6
                if ($site.eval) {
                    $clickResult = opencli browser $session eval $site.eval 2>&1
                    Write-Output "  [CLICK] $($clickResult -join ' ')"
                    Start-Sleep -Seconds 5
                }
                $signal = Test-SignIn $session
                if ($signal -eq "UNKNOWN") {
                    Write-Output "  [RETRY] signal=$signal, waiting 8s more..."
                    Start-Sleep -Seconds 8
                    $signal = Test-SignIn $session
                    Write-Output "  [RETRY] result=$signal"
                }
                $r.signal = $signal
                switch ($signal) {
                    "SIGN_OK"  { $r.status = "SUCCESS"; $signals.ok_sites += $site.name; Write-Output "  => SIGN_OK" }
                    "LOGGED_IN"{ $r.status = "ALREADY_DONE"; $signals.ok_sites += $site.name; Write-Output "  => ALREADY_DONE" }
                    default    { $r.status = "EVAL_FAIL"; $signals.fail_sites += $site.name; Write-Output "  => $signal" }
                }
                # 失败重试：EVAL_FAIL 最多重试 2 次
                if ($r.status -eq "EVAL_FAIL") {
                    for ($retry = 1; $retry -le 2; $retry++) {
                        Write-Output "  [RETRY $retry/2] $($site.name) - waiting 10s..."
                        Start-Sleep -Seconds 10
                        opencli browser $session open $site.url 2>&1 | Out-Null
                        Start-Sleep -Seconds 6
                        if ($site.eval) {
                            $clickResult2 = opencli browser $session eval $site.eval 2>&1
                            Write-Output "  [CLICK R$retry] $($clickResult2 -join ' ')"
                            Start-Sleep -Seconds 5
                        }
                        $signal2 = Test-SignIn $session
                        Write-Output "  [RETRY $retry/2] $site.name => $signal2"
                        if ($signal2 -eq "SIGN_OK" -or $signal2 -eq "LOGGED_IN") {
                            $r.status = "SUCCESS"
                            $r.signal = $signal2
                            $signals.fail_sites = @($signals.fail_sites | Where-Object { $_ -ne $site.name })
                            $signals.ok_sites += $site.name
                            Write-Output "  => SIGN_OK (eval-click retry $retry)"
                            break
                        }
                    }
                }
                try { opencli browser $session close 2>&1 | Out-Null } catch {}
            }
            "browser-visit" {
                $null = opencli browser $session open $site.url 2>&1
                Start-Sleep -Seconds 8
                $ready = Wait-PageReady $session 5
                $signal = Test-SignIn $session
                $r.signal = $signal
                if ($signal -eq "LOGIN_REQUIRED") {
                    $r.status = "NO_LOGIN"
                    $signals.login_expired += $site.name
                    Write-Output "  => NO_LOGIN (session expired!)"
                } elseif ($signal -eq "LOGGED_IN") {
                    $r.status = "VISITED"
                    $signals.ok_sites += $site.name
                    Write-Output "  => VISITED (logged in)"
                } else {
                    $r.status = "VISITED"
                    $signals.ok_sites += $site.name
                    Write-Output "  => VISITED"
                }
                try { opencli browser $session close 2>&1 | Out-Null } catch {}
            }
            "manual" {
                $r.status = "SKIPPED"; $r.signal = $site.reason
                $signals.skip_sites += $site.name; Write-Output "  => SKIPPED"
            }
            default {
                $r.status = "SKIPPED"; $r.signal = "UNKNOWN_STRATEGY"
                $signals.skip_sites += $site.name
            }
        }
    } catch {
        $r.status = "ERROR"; $r.signal = $_.Exception.Message
        $signals.fail_sites += $site.name; Write-Output "  => ERROR"
        try { opencli browser $session close 2>&1 | Out-Null } catch {}
    }

    Track-Baseline $site.name $r.status

    $r.elapsed = "$([math]::Round(((Get-Date)-$start).TotalSeconds,1))s"
    $results += $r
    Write-Output ""
}

$signals.ok = ($signals.fail_sites.Count -eq 0)

$iterCount = $script:iterationLog.Count
Write-Output "---"
Write-Output "Self-iterations: $iterCount change(s) detected/applied"
if ($iterCount -gt 0) {
    foreach ($it in $script:iterationLog) {
        Write-Output "  [$($it.timestamp)] $($it.site): $($it.action)"
    }
    Write-Output "Log: $iterationLogFile"
}

# Update baseline if new sites discovered
if ($tracking.new_sites.Count -gt 0) {
    $baseline.last_updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $baseline.auto_total = $baseline.sites.Count
    $baseline | ConvertTo-Json -Depth 3 | Out-File $BaselineFile -Encoding UTF8
    Write-Output "Baseline: +$($tracking.new_sites.Count) new -> $($baseline.sites.Count) total"
    Write-Output "New:   $($tracking.new_sites -join ', ')"
}
if ($tracking.regressions.Count -gt 0) {
    Write-Output "REGRESSION: $($tracking.regressions.Count) baseline site(s) failed: $($tracking.regressions -join ', ')"
}

$summary = @{
    timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    total         = $total
    success       = $signals.ok_sites.Count
    failed        = $signals.fail_sites.Count
    skipped       = $signals.skip_sites.Count
    iterations    = $iterCount
    baseline_known= $baseline.sites.Count
    new_successes = $tracking.new_sites
    regressions   = $tracking.regressions
    ok_sites      = $signals.ok_sites
    fail_sites    = $signals.fail_sites
    skip_sites    = $signals.skip_sites
    iteration_log = $script:iterationLog
    results       = $results
}
$summary | ConvertTo-Json -Depth 4 | Out-File $ResultFile -Encoding UTF8

Write-Output ""
Write-Output "=== Signal ==="
Write-Output "PASS: $([string]$signals.ok). AUTO_OK=$($signals.ok_sites.Count) AUTO_FAIL=$($signals.fail_sites.Count) MANUAL_SKIP=$($signals.skip_sites.Count) BASELINE=$($baseline.sites.Count)"
if ($tracking.new_sites.Count -gt 0) { Write-Output "NEW:  $($tracking.new_sites -join ', ')" }
if ($tracking.regressions.Count -gt 0) { Write-Output "REGR: $($tracking.regressions -join ', ')" }
Write-Output "OK:   $($signals.ok_sites -join ', ')"
if ($signals.fail_sites.Count -gt 0) { Write-Output "FAIL: $($signals.fail_sites -join ', ')" }
Write-Output "Log:  $ResultFile"

function Send-FeishuSummary {
    param([string]$Webhook, [string]$ChatId, $Summary)
    if ([string]::IsNullOrEmpty($Webhook) -and [string]::IsNullOrEmpty($ChatId)) { return }
    Write-Output ""
    Write-Output "=== Feishu Push ==="

    $passIcon = if ($signals.ok) { "$([char]0x2705)" } else { "$([char]0x26A0)$([char]0xFE0F)" }
    $totalTime = "$([math]::Round(((Get-Date) - $script:scriptStart).TotalMinutes, 1))min"
    $autoTotal = $Summary.total - $Summary.skipped

    # Emoji variables (use [char] codepoints to avoid file encoding issues)
    $e_new    = "$([System.Char]::ConvertFromUtf32(0x1F195))"
    $e_alarm  = "$([System.Char]::ConvertFromUtf32(0x1F6A8))"
    $e_iter   = "$([System.Char]::ConvertFromUtf32(0x1F504))"
    $e_stats  = "$([System.Char]::ConvertFromUtf32(0x1F4CA))"
    $e_green  = "$([System.Char]::ConvertFromUtf32(0x1F7E2))"
    $e_red    = "$([System.Char]::ConvertFromUtf32(0x1F534))"
    $e_skip   = "$([char]0x23ED)"
    $e_cf     = "$([System.Char]::ConvertFromUtf32(0x1F6AB))"
    $e_q      = "$([char]0x2753)"
    $e_search = "$([System.Char]::ConvertFromUtf32(0x1F50D))"
    $e_cross  = "$([char]0x274C)"
    $e_date   = "$([System.Char]::ConvertFromUtf32(0x1F4C5))"

    $okJoined = ($signals.ok_sites | Sort-Object) -join ", "
    $skipJoined = if ($signals.skip_sites.Count -gt 0) { ($signals.skip_sites | Sort-Object) -join ", " } else { "(none)" }

    # ===== Classify failures by reason =====
    $capSites = @(); $deadSites = @(); $nodetectSites = @(); $otherSites = @()
    foreach ($r in $results) {
        if ($r.status -ne "SUCCESS" -and $r.status -ne "ALREADY_DONE" -and $r.status -ne "LOGGED_IN" -and $r.status -ne "SKIPPED" -and $r.status -ne "VISITED") {
            switch ($r.status) {
                "CAPTCHA"      { $capSites += $r.name }
                "TOO_SMALL"    { $capSites += $r.name }
                "CF_DETECTED"  { $capSites += $r.name }
                "CF_BLOCKED"   { $capSites += $r.name }
                "NO_ARTICLE"   { $deadSites += $r.name }
                "NO_DETECT"    { $nodetectSites += $r.name }
                "UNKNOWN"      { $otherSites += $r.name }
                default        { $otherSites += $r.name }
            }
        }
    }

    # ===== Baseline delta =====
    $baselineMd = ""
    if ($tracking.new_sites.Count -gt 0) {
        $newJoined = ($tracking.new_sites | Sort-Object) -join ", "
        $baselineMd += "$e_new 新基线: **+$($tracking.new_sites.Count)** ($newJoined)`n"
    }
    if ($tracking.regressions.Count -gt 0) {
        $regJoined = ($tracking.regressions | Sort-Object) -join ", "
        $baselineMd += "$e_alarm 基线回归: **$($tracking.regressions.Count)** 站 ($regJoined)`n"
    }

    # ===== Iteration summary =====
    $iterMd = ""
    if ($Summary.iterations -gt 0) {
        $iterCounts = @{}
        foreach ($it in $Summary.iteration_log) {
            $key = $it.action
            if ($null -eq $key -or $key -isnot [string] -or [string]::IsNullOrEmpty($key)) { continue }
            if (-not $iterCounts.ContainsKey($key)) { $iterCounts[$key] = 0 }
            $iterCounts[$key] = [int]$iterCounts[$key] + 1
        }
        $iterParts = @()
        foreach ($k in $iterCounts.Keys | Sort-Object) {
            $cnt = $iterCounts[$k]
            $label = switch ($k) {
                "token_refresh" { "Token刷新" }
                "pattern_discovery" { "模式探测" }
                default { $k }
            }
            $iterParts += "$label×$cnt"
        }
        $iterMd = "$e_iter 自迭代: **$($Summary.iterations)** 次 ($($iterParts -join ', '))"
    }

    # ==================== CARD ELEMENTS ====================
    $cardElements = @()

    # --- Stats section ---
    $statsMd = "$e_stats 总计 **$($Summary.total)** 站 | 基线 **$($Summary.baseline_known)** | ⏱ **$totalTime**`n"
    $statsMd += "$e_green 成功 **$($Summary.success)**/$autoTotal | $e_red 失败 **$($Summary.failed)** | $e_skip 跳过 **$($Summary.skipped)**"
    if ($baselineMd) { $statsMd += "`n" + $baselineMd.TrimEnd("`n") }
    $cardElements += @{
        tag = "div"
        text = @{ tag = "lark_md"; content = $statsMd }
    }

    # --- Success section ---
    $cardElements += @{ tag = "hr" }
    $successMd = "**$e_green 签到成功 ($($Summary.success))**`n$okJoined"
    $cardElements += @{
        tag = "div"
        text = @{ tag = "lark_md"; content = $successMd }
    }

    # --- Failure section ---
    if ($Summary.failed -gt 0) {
        $cardElements += @{ tag = "hr" }
        $failMd = "**🔴 签到失败 ($($Summary.failed))**"
        if ($capSites.Count -gt 0) {
            $capJoined = ($capSites | Sort-Object) -join ", "
            $failMd += "`n$e_cf CF拦截 ($($capSites.Count)): $capJoined"
        }
        if ($deadSites.Count -gt 0) {
            $deadJoined = ($deadSites | Sort-Object) -join ", "
            $failMd += "`n❓ 无响应 ($($deadSites.Count)): $deadJoined"
        }
        if ($nodetectSites.Count -gt 0) {
            $ndJoined = ($nodetectSites | Sort-Object) -join ", "
            $failMd += "`n🔍 未识别 ($($nodetectSites.Count)): $ndJoined"
        }
        if ($otherSites.Count -gt 0) {
            $otherJoined = ($otherSites | Sort-Object) -join ", "
            $failMd += "`n❌ 其他 ($($otherSites.Count)): $otherJoined"
        }
        $cardElements += @{
            tag = "div"
            text = @{ tag = "lark_md"; content = $failMd }
        }
    }

    # --- Skipped section ---
    if ($Summary.skipped -gt 0) {
        $cardElements += @{ tag = "hr" }
        $cardElements += @{
            tag = "div"
            text = @{ tag = "lark_md"; content = "**$e_skip 人工签到 ($($Summary.skipped))**`n$skipJoined" }
        }
    }

    # --- Login expired warning ---
    if ($signals.login_expired.Count -gt 0) {
        $cardElements += @{ tag = "hr" }
        $loginExpJoined = ($signals.login_expired | Sort-Object) -join ", "
        $loginMd = "**$e_alarm 会话失效 ($($signals.login_expired.Count))**`n$loginExpJoined"
        $cardElements += @{
            tag = "div"
            text = @{ tag = "lark_md"; content = $loginMd }
        }
    }

    # --- Iteration section ---
    if ($iterMd) {
        $cardElements += @{ tag = "hr" }
        $cardElements += @{
            tag = "div"
            text = @{ tag = "lark_md"; content = $iterMd }
        }
    }

    # --- Footer ---
    $cardElements += @{ tag = "hr" }
    $cardElements += @{
        tag = "note"
        elements = @(
            @{ tag = "plain_text"; content = "$e_date $($Summary.timestamp)  |  signin-log.json" }
        )
    }

    # ==================== BUILD CARD JSON ====================
    $cardJson = @{
        msg_type = "interactive"
        card = @{
            config = @{ wide_screen_mode = $true }
            header = @{
                title = @{ tag = "plain_text"; content = "$passIcon PT 签到报告" }
                template = if ($signals.ok) { "green" } else { "red" }
            }
            elements = $cardElements
        }
    } | ConvertTo-Json -Depth 5 -Compress

    # ==================== PUSH ====================
    if (-not [string]::IsNullOrEmpty($Webhook)) {
        try {
            $tmpFile = Join-Path $env:TEMP "ptsign_feishu_$([System.Guid]::NewGuid().ToString('N')).json"
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($tmpFile, $cardJson, $utf8NoBom)
            $result = Invoke-RestMethod -Uri $Webhook -Method Post -ContentType "application/json; charset=utf-8" -InFile $tmpFile -TimeoutSec 10
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            if ($result.StatusCode -eq 0 -or $result.code -eq 0) {
                Write-Output "Feishu webhook (card): OK"
            } else {
                Write-Output "Feishu webhook (card): FAIL - $($result | ConvertTo-Json -Compress)"
            }
        } catch {
            Write-Output "Feishu webhook (card): ERROR - $($_.Exception.Message)"
        }
    } elseif (-not [string]::IsNullOrEmpty($ChatId)) {
        # lark-cli only supports text, build plain text fallback
        $text = "$passIcon PT签到报告"
        $text += "`n━━━━━━━━━━━━━━━━━━"
        $text += "`n📅 $($Summary.timestamp)"
        $text += "`n📊 总计: $($Summary.total) | 基线: $($Summary.baseline_known) | ⏱ $totalTime"
        $text += "`n🟢 成功: $($Summary.success)/$autoTotal | 🔴 失败: $($Summary.failed) | ⏭ 跳过: $($Summary.skipped)"
        if ($baselineMd) { $text += "`n$($baselineMd -replace '\*\*','' -replace '`n',' ')" }
        $text += "`n`n🟢 签到成功 ($($Summary.success))"
        $text += "`n━━━━━━━━━━━━━━━━━━"
        $text += "`n$okJoined"
        if ($Summary.failed -gt 0) {
            $text += "`n`n🔴 签到失败 ($($Summary.failed))"
            $text += "`n━━━━━━━━━━━━━━━━━━"
            if ($capSites.Count -gt 0) { $text += "`n🚫 CF拦截 ($($capSites.Count)): $(($capSites | Sort-Object) -join ', ')" }
            if ($deadSites.Count -gt 0) { $text += "`n❓ 无响应 ($($deadSites.Count)): $(($deadSites | Sort-Object) -join ', ')" }
            if ($nodetectSites.Count -gt 0) { $text += "`n🔍 未识别 ($($nodetectSites.Count)): $(($nodetectSites | Sort-Object) -join ', ')" }
            if ($otherSites.Count -gt 0) { $text += "`n❌ 其他 ($($otherSites.Count)): $(($otherSites | Sort-Object) -join ', ')" }
        }
        if ($Summary.skipped -gt 0) {
            $text += "`n`n⏭ 人工签到 ($($Summary.skipped))"
            $text += "`n━━━━━━━━━━━━━━━━━━"
            $text += "`n$skipJoined"
        }
        if ($iterMd) { $text += "`n`n$($iterMd -replace '\*\*','')" }
        try {
            $result = lark-cli im +messages-send --chat-id $ChatId --as bot --text $text 2>&1 | Out-String
            if ($result -match '"ok":\s*true') {
                Write-Output "Feishu lark-cli: OK"
            } else {
                Write-Output "Feishu lark-cli: FAIL"
                Write-Output $result
            }
        } catch {
            Write-Output "Feishu lark-cli: ERROR - $($_.Exception.Message)"
        }
    }
}

Send-FeishuSummary $FeishuWebhook $FeishuChatId $summary

# 关闭统一 webbridge session
if ($script:webbridgeAvailable) {
    try { $null = Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session "daily-signin" -TimeoutSec 5 } catch {}
}

# Cleanup web-articles after run
if (Test-Path $WebArticlesDir) {
    Get-ChildItem $WebArticlesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $WebArticlesDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

if ($signals.ok) { exit 0 } else { exit 1 }
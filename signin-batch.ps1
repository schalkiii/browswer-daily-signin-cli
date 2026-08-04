param(
    [string]$ConfigFile = "$PSScriptRoot\sites.json",
    [string]$ResultFile = "$PSScriptRoot\signin-log.json",
    [string]$WebArticlesDir = "$PSScriptRoot\web-articles",
    [string]$DebugDir = "$PSScriptRoot\debug-snapshots",
    [string]$FeishuChatId = "",
    [string]$FeishuWebhook = "",
    [switch]$SaveDebugSnapshot,
    # v4.13.0: 仅执行配置一致性校验并退出（不打开浏览器、不签到）
    [switch]$ValidateConfig
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

# v4.13.0: 配置一致性校验（防止"非 manual 站点缺 $WebSignInConfigs → NO_CONFIG 静默跳过"）
# 不依赖浏览器，运行前即可发现配置债务。-ValidateConfig 时仅校验并退出。
$configIssues = Test-SigninConfigConsistency -Config $config
if ($configIssues.Count -gt 0) {
    foreach ($iss in $configIssues) {
        if ($iss.severity -eq 'WARN') { Write-Warning "CONFIG[$($iss.site)]: $($iss.message)" }
        else { Write-Output "  [config-note] $($iss.site): $($iss.message)" }
    }
}
if ($ValidateConfig) {
    $warnCount = ($configIssues | Where-Object { $_.severity -eq 'WARN' }).Count
    Write-Output ""
    Write-Output "Config validation done: $($configIssues.Count) issue(s), $warnCount warning(s)."
    if ($warnCount -gt 0) { exit 1 } else { exit 0 }
}

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
$tracking = @{ new_sites = @(); regressions = @(); exploratory_total = 0; needs_manual_review = @() }
Write-Output "Baseline: $($baseline.sites.Count) known-success sites"

# === SELF-ITERATION: Web page change detection & auto-repair ===
# 注: v4.10 起，签到迭代统一改用 kimi webbridge 后端（Test-WebBridgeSignIn 内置检测+点击+重试）。
# $script:iterationLog 框架保留以兼容现有输出。

$script:iterationLog = @()
$iterationLogFile = "$PSScriptRoot\iterations.json"
if (Test-Path $iterationLogFile) {
    try { $script:iterationLog = @(Get-Content $iterationLogFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $script:iterationLog = @() }
}

function Save-IterationLog {
    $script:iterationLog | ConvertTo-Json -Depth 3 | Out-File $iterationLogFile -Encoding UTF8
}

# 同步浏览器书签中的 PT 站点列表
# ⚠️  禁止自动添加 manual 策略：新增站点统一使用 web-read 或 browser-open。
# 如需标记为 manual，必须由用户人工确认后手动修改 sites.json。
# 失败站点仅记入 needs_manual_review 列表，通过飞书通知用户处理。
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
    # 提取书签 url + name（display_name 来源）
    $bookmarkInfos = [System.Collections.Generic.List[object]]::new()
    function Walk-BookmarkNodes($node, $path, $list) {
        if ($node.type -eq 'folder') {
            $curPath = "$path/$($node.name)"
            if ($curPath -match $bookmarkFolderPattern) {
                foreach ($child in $node.children) {
                    if ($child.type -eq 'url') { $list.Add(@{ url = $child.url; name = $child.name }) }
                }
            }
            foreach ($child in $node.children) { Walk-BookmarkNodes $child $curPath $list }
        }
    }
    Walk-BookmarkNodes $bookmarks.roots.bookmark_bar "" $bookmarkInfos
    $bookmarkInfos = $bookmarkInfos | Sort-Object url -Unique
    if ($bookmarkInfos.Count -eq 0) {
        Write-Output "[SYNC] No PT签到 bookmarks found, keeping all existing sites"
        return $ConfigObject
    }
    Write-Output "[SYNC] Found $($bookmarkInfos.Count) bookmark URLs"
    $bookmarkDomains = @{}
    foreach ($info in $bookmarkInfos) {
        try {
            $uri = [uri]$info.url
            $domain = $uri.Host -replace '^www\.', ''
            if (-not $bookmarkDomains.ContainsKey($domain)) { $bookmarkDomains[$domain] = $info }
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
        $info = $bookmarkDomains[$domain]
        $url = $info.url
        $bmName = $info.name
        $parts = $domain -split '\.'
        $nameGuess = if ($parts.Count -ge 3) { $parts[-2] } else { $parts[0] }
        $strategy = if ($url -match 'attendance\.php') { 'web-read' } else { 'browser-open' }
        $newSite = [PSCustomObject]@{
            name = $nameGuess
            url = $url
            strategy = $strategy
        }
        # 书签名与 nameGuess 不同时写入 display_name，避免冗余
        if ($bmName -and $bmName -ne $nameGuess) {
            $newSite | Add-Member -NotePropertyName display_name -NotePropertyValue $bmName
        }
        $newSite | Add-Member -NotePropertyName note -NotePropertyValue 'auto: 书签同步新增'
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

    # 同步日志落盘，便于排查"新书签为何没同步进来"
    $syncLogFile = "$PSScriptRoot\sync-log.json"
    $syncRecord = [PSCustomObject]@{
        timestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        bookmarkCount  = $bookmarkInfos.Count
        total          = $newSites.Count
        added          = @($added)
        removed        = @($removed)
    }
    try {
        $syncLog = @()
        if (Test-Path $syncLogFile) {
            $slRaw = Get-Content $syncLogFile -Raw -Encoding UTF8
            $slRaw = $slRaw -replace '^\uFEFF', ''
            $syncLog = @($slRaw | ConvertFrom-Json)
        }
        $syncLog = @($syncLog) + $syncRecord
        # 只保留最近 50 条，避免无限增长
        if ($syncLog.Count -gt 50) { $syncLog = $syncLog[($syncLog.Count - 50)..($syncLog.Count - 1)] }
        $syncLog | ConvertTo-Json -Depth 3 | Out-File $syncLogFile -Encoding UTF8
    } catch {
        Write-Output "[SYNC] log write failed: $($_.Exception.Message)"
    }

    return $ConfigObject
}

$config = Sync-Bookmarks $ConfigFile $config

# Cleanup old articles
if (Test-Path $WebArticlesDir) {
    Get-ChildItem $WebArticlesDir -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $WebArticlesDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Output "=== PT Sign-in v4.12.25 (self-iterating + baseline + forum click + cleanup + bookmark-sync) ==="
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

# v4.12.19: 批处理开始前整会话强关残留 tab（上一轮被硬杀时 per-site finally 未执行会残留）
if ($script:webbridgeAvailable) {
    try { $null = Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session "daily-signin" -TimeoutSec 8 } catch {}
}

foreach ($site in $config.sites) {
    $idx = $config.sites.IndexOf($site) + 1
    # v4.12.25: 删除原 $session="pt$idx" 死变量。所有站点必须共用 "daily-signin" 单一会话，
    #   这是 Open-SiteTab(Close-SiteTabs-Verified) 能"关掉上一站点 tab"的前提；若改传独立 session，
    #   close_session 只清自己 → 上一站 tab 永不关 → 泄漏重现。Test-WebBridgeSignIn 内 $session 硬编码 "daily-signin"。
    $start = Get-Date
    $siteResult = @{ index = $idx; name = $site.name; url = $site.url; strategy = $site.strategy; status = "UNKNOWN"; signal = ""; elapsed = "" }

    Write-Output "[$idx/$total] $($site.name) [$($site.strategy)]"

    try {
        # v4.10: 所有非 manual 站点统一走 kimi webbridge（兼容旧 strategy 值 web-read/browser-open/
        # browser-eval/browser-eval-click/browser-visit，由 default 分支兜底）
        switch ($site.strategy) {
            "manual" {
                $siteResult.status = "SKIPPED"; $siteResult.signal = $site.reason
                $signals.skip_sites += $site.name; Write-Output "  => SKIPPED"
            }
            default {
                if (-not $script:webbridgeAvailable) {
                    $siteResult.status = "SKIPPED"; $siteResult.signal = "DAEMON_DOWN"
                    $signals.skip_sites += $site.name; Write-Output "  => SKIPPED (webbridge daemon 不可用)"
                } else {
                    # v4.12.24: 批处理全程后台，绝不弹前台（用户明确要求）。
                    #   单独站点调试可用 signin-single.ps1（其已硬编码 -NoFocus:$true）。
                    $wbResult = Invoke-WebSignIn -SiteName $site.name -Strategy $site.strategy -SaveDebugSnapshot $SaveDebugSnapshot -DebugDir $DebugDir -NoFocus:$true
                    $siteResult.signal = $wbResult
                    switch -Wildcard ($wbResult) {
                        "SIGN_OK"       { $siteResult.status = "SUCCESS"; $signals.ok_sites += $site.name; Write-Output "  => SIGN_OK (webbridge)" }
                        "ALREADY_SIGNED"{ $siteResult.status = "ALREADY_DONE"; $signals.ok_sites += $site.name; Write-Output "  => ALREADY_DONE (今日已签到，非本次点击)" }
                        "VISITED"       { $siteResult.status = "VISITED"; $signals.ok_sites += $site.name; Write-Output "  => VISITED (visit-only)" }
                        "LOGIN_REQUIRED"{ $siteResult.status = "NO_LOGIN"; $signals.login_expired += $site.name; Write-Output "  => NO_LOGIN" }
                        "CF_CHALLENGE"  { $siteResult.status = "CF_BLOCKED"; $signals.fail_sites += $site.name; Write-Output "  => CF_BLOCKED" }
                        "SLIDER"        { $siteResult.status = "SLIDER_FAIL"; $signals.fail_sites += $site.name; Write-Output "  => SLIDER_FAIL" }
                        "NAV_FAIL"      { $siteResult.status = "TIMEOUT"; $signals.fail_sites += $site.name; Write-Output "  => TIMEOUT" }
                        "NO_CONFIG"     { $siteResult.status = "SKIPPED"; $signals.skip_sites += $site.name; Write-Output "  => NO_CONFIG" }
                        "BODY_NULL"     { $siteResult.status = "PAGE_ERROR"; $signals.fail_sites += $site.name; Write-Output "  => PAGE_ERROR (body null)" }
                        "REDIRECTING"   { $siteResult.status = "PAGE_ERROR"; $signals.fail_sites += $site.name; Write-Output "  => REDIRECTING" }
                        "SERVER_ERROR"  { $siteResult.status = "PAGE_ERROR"; $signals.fail_sites += $site.name; Write-Output "  => PAGE_ERROR (server/network error)" }
                        "EVAL_FAIL"     { $siteResult.status = "PAGE_ERROR"; $signals.fail_sites += $site.name; Write-Output "  => PAGE_ERROR (evaluate failed)" }
                        default         { $siteResult.status = "NO_DETECT"; $signals.fail_sites += $site.name; Write-Output "  => $wbResult (webbridge)" }
                    }
                    # 失败重试：CF_BLOCKED / SLIDER_FAIL / PAGE_ERROR / NO_DETECT / TIMEOUT 最多重试 2 次
                    $retryable = @("CF_BLOCKED", "SLIDER_FAIL", "PAGE_ERROR", "NO_DETECT", "TIMEOUT")
                    if ($siteResult.status -in $retryable) {
                        for ($retry = 1; $retry -le 2; $retry++) {
                            Write-Output "  [RETRY $retry/2] $($site.name) - waiting 10s..."
                            Start-Sleep -Seconds 10
                            $wbResult2 = Invoke-WebSignIn -SiteName $site.name -Strategy $site.strategy -SaveDebugSnapshot $SaveDebugSnapshot -DebugDir $DebugDir -NoFocus:$true
                            $siteResult.signal = $wbResult2
                            if ($wbResult2 -eq "SIGN_OK" -or $wbResult2 -eq "VISITED" -or $wbResult2 -eq "ALREADY_SIGNED") {
                                if ($wbResult2 -eq "VISITED") {
                                    $siteResult.status = "VISITED"
                                } elseif ($wbResult2 -eq "ALREADY_SIGNED") {
                                    $siteResult.status = "ALREADY_DONE"
                                } else {
                                    $siteResult.status = "SUCCESS"
                                }
                                $signals.fail_sites = @($signals.fail_sites | Where-Object { $_ -ne $site.name })
                                $signals.ok_sites += $site.name
                                Write-Output "  => $wbResult2 (webbridge retry $retry)"
                                break
                            }
                            Write-Output "  [RETRY $retry/2] $($site.name) => $wbResult2"
                        }
                    }
                    # ⚠️  禁止自动添加 manual：失败站点仅记入需人工审核列表，不改策略
                    if ($siteResult.status -eq "CF_BLOCKED" -or $siteResult.status -eq "SLIDER_FAIL") {
                        $tracking.needs_manual_review += "$($site.name)($($siteResult.status))"
                        Write-Output "  [REVIEW] 需人工审核: $($site.name) - $($siteResult.status)（不会自动改为 manual）"
                    }
                }
            }
        }
    } catch {
        $siteResult.status = "ERROR"; $siteResult.signal = $_.Exception.Message
        $signals.fail_sites += $site.name; Write-Output "  => ERROR"
    }

    Track-Baseline $site.name $siteResult.status

    $siteResult.elapsed = "$([math]::Round(((Get-Date)-$start).TotalSeconds,1))s"
    $results += $siteResult
    # v4.12.17: 增量落盘 —— 后台任务跨 turn 可能被回收，逐站写 log 保证可调试
    $partialSummary = @{
        timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        total         = $total
        success       = $signals.ok_sites.Count
        failed        = $signals.fail_sites.Count
        skipped       = $signals.skip_sites.Count
        iterations    = $script:iterationLog.Count
        baseline_known= $baseline.sites.Count
        new_successes = $tracking.new_sites
        regressions   = $tracking.regressions
        needs_manual_review = $tracking.needs_manual_review
        ok_sites      = $signals.ok_sites
        fail_sites    = $signals.fail_sites
        skip_sites    = $signals.skip_sites
        iteration_log = $script:iterationLog
        results       = $results
        partial       = $true
    }
    $partialSummary | ConvertTo-Json -Depth 4 | Out-File $ResultFile -Encoding UTF8
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
    needs_manual_review = $tracking.needs_manual_review
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
if ($tracking.needs_manual_review.Count -gt 0) { Write-Output "REVIEW: $($tracking.needs_manual_review -join ', ') (需人工确认，不会自动改manual)" }
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

    # 构建 siteInfoMap: name -> @{ url; display_name }，用于展示名 + 可点击链接
    $siteInfoMap = @{}
    foreach ($s in $config.sites) {
        $dn = if ($s.display_name) { $s.display_name } else { $s.name }
        $siteInfoMap[$s.name] = @{ url = $s.url; display_name = $dn }
    }
    # 取展示名（display_name 缺失时回退到 name）
    function Get-Dn([string]$siteName) {
        $info = $siteInfoMap[$siteName]
        if ($info -and $info.display_name) { return $info.display_name }
        return $siteName
    }
    # 格式化为飞书 lark_md 可点击链接 [display_name](url)
    function Format-SiteLink([string]$siteName) {
        $info = $siteInfoMap[$siteName]
        if ($info -and $info.url) {
            $dn = if ($info.display_name) { $info.display_name } else { $siteName }
            return "[$dn]($($info.url))"
        }
        return $siteName
    }

    # 成功列表仅用 display_name（不加链接，避免 30+ 站点卡片过长）
    $okJoined = ($signals.ok_sites | Sort-Object | ForEach-Object { Get-Dn $_ }) -join ", "
    # manual 跳过加链接（用户需点击打开手动签到）
    $skipJoined = if ($signals.skip_sites.Count -gt 0) {
        ($signals.skip_sites | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
    } else { "(none)" }

    # ===== Classify failures by reason =====
    $capSites = @(); $deadSites = @(); $nodetectSites = @(); $otherSites = @()
    foreach ($entry in $results) {
        if ($entry.status -ne "SUCCESS" -and $entry.status -ne "ALREADY_DONE" -and $entry.status -ne "SKIPPED" -and $entry.status -ne "VISITED") {
            switch ($entry.status) {
                "CF_BLOCKED"  { $capSites += $entry.name }
                "NO_DETECT"   { $nodetectSites += $entry.name }
                default       { $otherSites += $entry.name }
            }
        }
    }

    # ===== Baseline delta =====
    $baselineMd = ""
    if ($tracking.new_sites.Count -gt 0) {
        $newJoined = ($tracking.new_sites | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
        $baselineMd += "$e_new 新基线: **+$($tracking.new_sites.Count)** ($newJoined)`n"
    }
    if ($tracking.regressions.Count -gt 0) {
        $regJoined = ($tracking.regressions | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
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
            $capJoined = ($capSites | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
            $failMd += "`n$e_cf CF拦截 ($($capSites.Count)): $capJoined"
        }
        if ($deadSites.Count -gt 0) {
            $deadJoined = ($deadSites | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
            $failMd += "`n❓ 无响应 ($($deadSites.Count)): $deadJoined"
        }
        if ($nodetectSites.Count -gt 0) {
            $ndJoined = ($nodetectSites | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
            $failMd += "`n🔍 未识别 ($($nodetectSites.Count)): $ndJoined"
        }
        if ($otherSites.Count -gt 0) {
            $otherJoined = ($otherSites | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
            $failMd += "`n❌ 其他 ($($otherSites.Count)): $otherJoined"
        }
        $cardElements += @{
            tag = "div"
            text = @{ tag = "lark_md"; content = $failMd }
        }
    }

    # --- Needs manual review section (仅通知，不自动改策略) ---
    if ($tracking.needs_manual_review.Count -gt 0) {
        $cardElements += @{ tag = "hr" }
        $reviewJoined = ($tracking.needs_manual_review | Sort-Object | ForEach-Object {
            if ($_ -match '^(.+?)\((.+)\)$') {
                $siteName = $matches[1]; $status = $matches[2]
                "$(Format-SiteLink $siteName)($status)"
            } else { Get-Dn $_ }
        }) -join ", "
        $reviewMd = "**$e_alarm 需人工审核 ($($tracking.needs_manual_review.Count))**`n$reviewJoined`n⚠️  系统不会自动改为 manual，请人工确认后手动修改"
        $cardElements += @{
            tag = "div"
            text = @{ tag = "lark_md"; content = $reviewMd }
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
        $loginExpJoined = ($signals.login_expired | Sort-Object | ForEach-Object { Format-SiteLink $_ }) -join ", "
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
            if ($capSites.Count -gt 0) { $text += "`n🚫 CF拦截 ($($capSites.Count)): $(($capSites | Sort-Object | ForEach-Object { Get-Dn $_ }) -join ', ')" }
            if ($deadSites.Count -gt 0) { $text += "`n❓ 无响应 ($($deadSites.Count)): $(($deadSites | Sort-Object | ForEach-Object { Get-Dn $_ }) -join ', ')" }
            if ($nodetectSites.Count -gt 0) { $text += "`n🔍 未识别 ($($nodetectSites.Count)): $(($nodetectSites | Sort-Object | ForEach-Object { Get-Dn $_ }) -join ', ')" }
            if ($otherSites.Count -gt 0) { $text += "`n❌ 其他 ($($otherSites.Count)): $(($otherSites | Sort-Object | ForEach-Object { Get-Dn $_ }) -join ', ')" }
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
param(
    [Parameter(Mandatory=$true)]
    [string]$SiteName,
    [string]$ConfigFile = ""
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrEmpty($ConfigFile)) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ConfigFile = Join-Path $scriptDir "sites.json"
}
if (-not (Test-Path $ConfigFile)) { Write-Output "[ERROR] Config not found: $ConfigFile"; exit 1 }
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$site = $config.sites | Where-Object { $_.name -eq $SiteName } | Select-Object -First 1

if (-not $site) { Write-Output "[ERROR] Site not found: $SiteName"; exit 1 }

$session = "pt_diag"
Write-Output "=== Single Site Test ==="
Write-Output "Site: $($site.name)"
Write-Output "URL: $($site.url)"
Write-Output "Strategy: $($site.strategy)"
Write-Output ""

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$signalJS = '
(function(){
    var t = document.body.innerText || "";
    if(t.indexOf("签到成功")>-1||t.indexOf("簽到成功")>-1)return "SIGN_OK";
    if(t.indexOf("签到已得")>-1||t.indexOf("簽到已得")>-1||t.indexOf("签到得")>-1||t.indexOf("簽到得")>-1)return "SIGN_OK";
    if(t.indexOf("已签到")>-1||t.indexOf("已簽到")>-1)return "SIGN_OK";
    if(t.indexOf("这是您的第")>-1||t.indexOf("這是您的第")>-1)return "SIGN_OK";
    if(t.indexOf("签到获得")>-1||t.indexOf("簽到獲得")>-1)return "SIGN_OK";
    if(t.indexOf("Already checked")>-1)return "SIGN_OK";
    if(t.indexOf("cf-turnstile")>-1||t.indexOf("challenges.cloudflare")>-1||t.indexOf("安全驗證")>-1||t.indexOf("安全验证")>-1)return "CF_CHALLENGE";
    if(t.indexOf("请稍候")>-1)return "WAITING";
    if(t.indexOf("滑动")>-1||t.indexOf("拖动滑块")>-1)return "SLIDER";
    if(t.indexOf("请登录")>-1||t.indexOf("必須登录")>-1)return "LOGIN_REQUIRED";
    if(t.indexOf("欢迎回来")>-1||t.indexOf("歡迎回來")>-1)return "LOGGED_IN";
    return "UNKNOWN";
})()'

$diagJS = '
(function(){
    var t = document.body.innerText || "";
    var r = [];
    if(t.indexOf("签到")>-1) r.push("HAS_签到");
    if(t.indexOf("check")>-1||t.indexOf("Check")>-1) r.push("HAS_check");
    if(t.indexOf("token")>-1) r.push("HAS_token");
    if(t.indexOf("连续")>-1||t.indexOf("連續")>-1) r.push("HAS_连续");
    r.push("LEN:"+t.length);
    var first = t.substring(0,200).replace(/[\r\n]+/g,"\\n");
    r.push("FIRST200:"+first);
    return r.join("|");
})()'

$dumpJS = '
(function(){
    var t = document.body.innerText || "";
    return t.substring(0,800).replace(/[\r\n]+/g,"\\n");
})()'

switch ($site.strategy) {
    "web-read" {
        $WebArticlesDir = Join-Path $scriptDir "web-articles"
        $before = @(Get-ChildItem $WebArticlesDir -Directory -EA SilentlyContinue | % Name)
        opencli web read --url $site.url 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $after = @(Get-ChildItem $WebArticlesDir -Directory -EA SilentlyContinue | % Name)
        $newDir = $after | Where-Object { $_ -notin $before } | Select-Object -First 1
        if ($newDir) {
            $md = Get-ChildItem "$WebArticlesDir\$newDir\*.md" -EA SilentlyContinue | Select-Object -First 1
            if ($md) {
                Write-Output "Article: $($md.FullName) ($([math]::Round($md.Length/1024,1))KB)"
                $c = Get-Content $md.FullName -Raw -EA SilentlyContinue
                Write-Output "--- Content Preview (first 500 chars) ---"
                Write-Output $c.Substring(0, [Math]::Min(500, $c.Length))
            }
        } else {
            Write-Output "No new article generated"
        }
    }
    "browser-open" {
        opencli browser $session open $site.url 2>&1 | Out-Null
        Start-Sleep -Seconds 6
        $out = opencli browser $session eval $signalJS 2>&1 | Out-String
        Write-Output "--- Browser Eval Output (Signal) ---"
        Write-Output $out
        Write-Output ""
        Write-Output "--- Diagnostics ---"
        $diag = opencli browser $session eval $diagJS 2>&1 | Out-String
        Write-Output $diag
        Write-Output ""
        Write-Output "--- Page Content Dump ---"
        $dump = opencli browser $session eval $dumpJS 2>&1 | Out-String
        Write-Output $dump
        try { opencli browser $session close 2>&1 | Out-Null } catch {}
    }
    "browser-eval" {
        opencli browser $session open $site.url 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        opencli browser $session eval $site.eval 2>&1 | Out-Null
        Start-Sleep -Seconds 8
        $out = opencli browser $session eval $signalJS 2>&1 | Out-String
        Write-Output "--- Browser Eval Output (Signal) ---"
        Write-Output $out
        Write-Output ""
        Write-Output "--- Diagnostics ---"
        $diag = opencli browser $session eval $diagJS 2>&1 | Out-String
        Write-Output $diag
        try { opencli browser $session close 2>&1 | Out-Null } catch {}
    }
    "manual" {
        Write-Output "Manual site: $($site.reason)"
    }
}
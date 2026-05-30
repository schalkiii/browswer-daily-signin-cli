# kimi-webbridge.ps1 — 签到脚本 kimi WebBridge 集成模块
# 通过本地 daemon 操控用户真实浏览器完成签到
# URL 可透过 config.json → webbridge.baseUrl 自定义
# 用法: . .\kimi-webbridge.ps1; $r = Invoke-WebBridgeCommand "navigate" @{url="https://..."; newTab=$true} "session-name"

$WebBridgeBase = "http://127.0.0.1:10086/command"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ConfigPath = Join-Path $ScriptDir "config.json"
if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.webbridge -and $cfg.webbridge.baseUrl) { $WebBridgeBase = $cfg.webbridge.baseUrl }
    } catch {}
}

function Invoke-WebBridgeCommand {
    param(
        [string]$Action,
        [hashtable]$CmdArgs = @{},
        [string]$Session = "default",
        [int]$TimeoutSec = 30
    )
    $body = @{
        action  = $Action
        args    = $CmdArgs
        session = $Session
    }
    $json = $body | ConvertTo-Json -Compress -Depth 4
    try {
        $resp = Invoke-RestMethod -Uri $WebBridgeBase -Method Post -ContentType "application/json" -Body $json -TimeoutSec $TimeoutSec
        if ($resp.ok) { return $resp.data }
        else { Write-Error "[WebBridge] $Action FAIL: $($resp.error)"; return $null }
    } catch {
        Write-Error "[WebBridge] $Action ERROR: $_"
        return $null
    }
}

function Test-WebBridgeSignIn {
    param(
        [string]$SiteName,
        [string]$Url,
        [string]$DetectEval,
        [string]$ClickEval,
        [int]$WaitMs = 5000,
        [int]$PostClickWaitMs = 3000
    )
    $session = "signin-$($SiteName.ToLower() -replace '\s','-')"

    Write-Output "  [WebBridge] $SiteName : navigate -> $Url"
    $nav = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec 30
    if (-not $nav -or -not $nav.success) {
        Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session $session -TimeoutSec 5
        return "NAV_FAIL"
    }

    Write-Output "  [WebBridge] $SiteName : waiting ${WaitMs}ms for page load"
    Start-Sleep -Milliseconds $WaitMs

    Write-Output "  [WebBridge] $SiteName : evaluate detect"
    $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
    if (-not $detect) {
        Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session $session -TimeoutSec 5
        return "EVAL_FAIL"
    }

    if ($detect -is [string]) { $signal = $detect }
    elseif ($detect.value) { $signal = "$($detect.value)" }
    else { $signal = "$detect" }
    Write-Output "  [WebBridge] $SiteName : signal=$signal"

    if ($signal -match "SIGN_OK|ALREADY_SIGNED|LOGIN_REQUIRED|CF_CHALLENGE|SLIDER|CAPTCHA") {
        if ($signal -match "SIGN_OK|ALREADY_SIGNED") {
            Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session $session -TimeoutSec 5
            return "SIGN_OK"
        }
        Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session $session -TimeoutSec 5
        return $signal
    }

    if ($ClickEval) {
        Write-Output "  [WebBridge] $SiteName : evaluate click"
        $clicked = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $ClickEval } -Session $session -TimeoutSec 15
        Write-Output "  [WebBridge] $SiteName : click result=$clicked"

        Write-Output "  [WebBridge] $SiteName : waiting ${PostClickWaitMs}ms post-click"
        Start-Sleep -Milliseconds $PostClickWaitMs

        Write-Output "  [WebBridge] $SiteName : evaluate re-check"
        $recheck = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
        $recheckSig = if ($recheck -is [string]) { $recheck } elseif ($recheck.value) { "$($recheck.value)" } else { "$recheck" }
        if ($recheckSig -match "SIGN_OK|ALREADY_SIGNED") {
            Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session $session -TimeoutSec 5
            return "SIGN_OK"
        }
        $signal = $recheckSig
    }

    Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session $session -TimeoutSec 5
    return $signal
}
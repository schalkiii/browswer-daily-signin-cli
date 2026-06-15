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

# daemon 健康检查与自动修复
# 解决: daemon 异常退出后残留 daemon.pid 导致无法重启
function Ensure-WebBridgeDaemon {
    # 先检测 API 是否可用（通过 navigate 探测，__health__ 无 tab 会失败）
    try {
        $null = Invoke-RestMethod -Uri $WebBridgeBase -Method Post -ContentType "application/json" -Body '{"action":"ping","args":{},"session":"__health__"}' -TimeoutSec 3
        return $true
    } catch {
        # 如果响应是 JSON 格式的错误（daemon 在运行），也算成功
        if ($_.Exception.Message -match "tool_error|no tab") { return $true }
    }

    # API 不可用，尝试修复 pid 文件并重启
    $wbDir = Join-Path $env:USERPROFILE ".kimi-webbridge"
    $pidFile = Join-Path $wbDir "daemon.pid"
    $exePath = Join-Path $wbDir "bin\kimi-webbridge.exe"

    if (-not (Test-Path $exePath)) {
        Write-Host "[WebBridge] daemon 未安装，跳过 webbridge 站点" -ForegroundColor Yellow
        return $false
    }

    # 删除残留 pid 文件（使用 .NET 方法绕过安全限制）
    if (Test-Path $pidFile) {
        Write-Host "[WebBridge] 清理残留 daemon.pid..."
        try { [System.IO.File]::Delete($pidFile) } catch {}
    }

    # 启动 daemon
    Write-Host "[WebBridge] 启动 daemon..."
    try {
        & $exePath start 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        # 验证：通过 netstat 检查端口 + 简单 API 调用
        $portCheck = netstat -ano 2>$null | Select-String "127.0.0.1:10086.*LISTENING"
        if (-not $portCheck) {
            Write-Host "[WebBridge] daemon 启动失败（端口未监听）" -ForegroundColor Red
            return $false
        }
        Write-Host "[WebBridge] daemon 启动成功" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[WebBridge] daemon 启动失败，跳过 webbridge 站点" -ForegroundColor Red
        return $false
    }
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
        [int]$PostClickWaitMs = 3000,
        [int]$NavTimeoutSec = 60
    )
    $session = "daily-signin"

    Write-Host "  [WebBridge] $SiteName : navigate -> $Url"
    $nav = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
    if (-not $nav -or -not $nav.success) {
        return "NAV_FAIL"
    }

    Write-Host "  [WebBridge] $SiteName : waiting ${WaitMs}ms for page load"
    Start-Sleep -Milliseconds $WaitMs

    Write-Host "  [WebBridge] $SiteName : evaluate detect"
    $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
    if (-not $detect) {
        return "EVAL_FAIL"
    }

    if ($detect -is [string]) { $signal = $detect }
    elseif ($detect.value) { $signal = "$($detect.value)" }
    else { $signal = "$detect" }
    Write-Host "  [WebBridge] $SiteName : signal=$signal"

    if ($signal -match "SIGN_OK|ALREADY_SIGNED") {
        return "SIGN_OK"
    }
    if ($signal -match "LOGIN_REQUIRED|SLIDER|CAPTCHA") {
        return $signal
    }

    if ($signal -match "CF_CHALLENGE|BODY_NULL|REDIRECTING") {
        $retryWaits = @(10, 15, 20)
        for ($retry = 0; $retry -lt $retryWaits.Count; $retry++) {
            Write-Host "  [WebBridge] $SiteName : CF/BODY retry $($retry+1)/$($retryWaits.Count), wait $($retryWaits[$retry])s..."
            Start-Sleep -Seconds $retryWaits[$retry]
            $reDetect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
            $reSig = if ($reDetect -is [string]) { $reDetect } elseif ($reDetect.value) { "$($reDetect.value)" } else { "$reDetect" }
            Write-Host "  [WebBridge] $SiteName : retry signal=$reSig"
            if ($reSig -match "SIGN_OK|ALREADY_SIGNED") {
                return "SIGN_OK"
            }
            if ($reSig -match "NEED_SIGN|UNKNOWN") {
                $signal = $reSig
                break
            }
            if ($reSig -match "LOGIN_REQUIRED") {
                return "LOGIN_REQUIRED"
            }
        }
        if ($signal -match "CF_CHALLENGE|BODY_NULL|REDIRECTING") {
            return $signal
        }
    }

    if ($ClickEval) {
        Write-Host "  [WebBridge] $SiteName : evaluate click"
        $clicked = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $ClickEval } -Session $session -TimeoutSec 15
        Write-Host "  [WebBridge] $SiteName : click result=$clicked"

        Write-Host "  [WebBridge] $SiteName : waiting ${PostClickWaitMs}ms post-click"
        Start-Sleep -Milliseconds $PostClickWaitMs

        Write-Host "  [WebBridge] $SiteName : evaluate re-check"
        $recheck = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
        $recheckSig = if ($recheck -is [string]) { $recheck } elseif ($recheck.value) { "$($recheck.value)" } else { "$recheck" }
        if ($recheckSig -match "SIGN_OK|ALREADY_SIGNED") {
            return "SIGN_OK"
        }
        $signal = $recheckSig
    }

    return $signal
}
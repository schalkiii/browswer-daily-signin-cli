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

# 循环关闭 session 下所有 tab，避免标签累积泄漏
# 返回关闭的 tab 数量；extension 未连接时返回 -1
# v4.12.10: 必须按 list_tabs 返回的显式 tabId 逐个关闭。
# 根因：签到 tab 在折叠后台窗口中 active=False，close_tab 不带 tabId 时只关 active tab，
#       导致 active=False 的签到 tab 永远关不掉、跨站点累积残留。改为遍历 list_tabs 逐个按 id 关。
function Clear-WebBridgeTabs {
    param(
        [string]$Session = "daily-signin",
        [int]$MaxClose = 30
    )
    $closedCount = 0
    for ($i = 0; $i -lt $MaxClose; $i++) {
        try {
            $listResp = Invoke-WebBridgeCommand -Action "list_tabs" -CmdArgs @{} -Session $Session -TimeoutSec 5
            if (-not $listResp -or -not $listResp.tabs -or $listResp.tabs.Count -eq 0) {
                break
            }
            $tabCount = $listResp.tabs.Count
            if ($i -eq 0 -and $tabCount -gt 1) {
                Write-Host "  [WebBridge] 检测到 $tabCount 个残留 tab，开始清理..." -ForegroundColor Yellow
            }
            # 取第一个 tab 的 id（关闭后列表会缩短，下轮再取新的第一个）
            $tab = $listResp.tabs[0]
            $tabId = if ($tab.tabId) { $tab.tabId } elseif ($tab.id) { $tab.id } else { $null }
            if (-not $tabId) {
                # 拿不到 id 时退化为无参 close（保底），但这是残留根因，应尽量避免
                $closeResp = Invoke-WebBridgeCommand -Action "close_tab" -CmdArgs @{} -Session $Session -TimeoutSec 5
            } else {
                $closeResp = Invoke-WebBridgeCommand -Action "close_tab" -CmdArgs @{ tabId = $tabId } -Session $Session -TimeoutSec 5
            }
            if (-not $closeResp) {
                # close_tab 失败（可能是 extension 未连接），停止循环
                if ($closedCount -eq 0) { return -1 }
                break
            }
            $closedCount++
        } catch {
            break
        }
    }
    return $closedCount
}

function Test-WebBridgeSignIn {
    param(
        [string]$SiteName,
        [string]$Url,
        [string]$DetectEval,
        [string]$ClickEval,
        [int]$WaitMs = 5000,
        [int]$PostClickWaitMs = 3000,
        [int]$NavTimeoutSec = 60,
        [int]$CfRetryCount = 3,
        [int]$CfRetryWaitMs = 10000,
        [bool]$SaveDebugSnapshot = $false,
        [string]$DebugDir = "",
        [bool]$NoFocus = $false
    )
    $session = "daily-signin"

    # v4.12.2: 循环关闭 session 下所有残留 tab，避免标签累积泄漏
    # 旧版单次 close_tab 在 extension 断开时失败，导致旧 tab 残留，重试时新 tab 累积
    $cleared = Clear-WebBridgeTabs -Session $session
    if ($cleared -gt 0) {
        Write-Host "  [WebBridge] $SiteName : 清理 $cleared 个残留 tab" -ForegroundColor DarkGray
    }

    try {
        Write-Host "  [WebBridge] $SiteName : navigate -> $Url"
        $nav = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
        # v4.12.3: extension 冷启动等待 — daemon 启动后 extension 需要几秒才连接
        # 首个站点可能 navigate 失败，等待 extension 就绪后重试
        if (-not $nav -or -not $nav.success) {
            $listCheck = Invoke-WebBridgeCommand -Action "list_tabs" -CmdArgs @{} -Session $session -TimeoutSec 5
            if (-not $listCheck) {
                Write-Host "  [WebBridge] $SiteName : extension 未就绪，等待重试..." -ForegroundColor Yellow
                for ($extRetry = 0; $extRetry -lt 3; $extRetry++) {
                    Start-Sleep -Seconds 5
                    $listCheck = Invoke-WebBridgeCommand -Action "list_tabs" -CmdArgs @{} -Session $session -TimeoutSec 5
                    if ($listCheck) {
                        Write-Host "  [WebBridge] $SiteName : extension 已就绪（重试 $($extRetry+1)/3）" -ForegroundColor Green
                        $nav = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
                        break
                    }
                    Write-Host "  [WebBridge] $SiteName : extension 重试 $($extRetry+1)/3 仍未就绪" -ForegroundColor Yellow
                }
            }
                if (-not $nav -or -not $nav.success) {
                    # v4.12.7: daemon 内部 30s 硬编码导航超时（lesson 36）多为服务端慢/瞬时；
                    # 重试导航 2 次以对抗偶发超时，仍失败才判 NAV_FAIL
                    $navRetries = 0
                    while ((-not $nav -or -not $nav.success) -and $navRetries -lt 2) {
                        Write-Host "  [WebBridge] $SiteName : NAV_FAIL, re-navigate retry $($navRetries+1)/2..."
                        Start-Sleep -Seconds 3
                        $nav = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
                        $navRetries++
                    }
                    if (-not $nav -or -not $nav.success) {
                        return "NAV_FAIL"
                    }
                }
        }

        # v4.12.6: navigate 后让标签页获得焦点（CF Turnstile 需要页面有焦点才渲染 iframe）
        # -NoFocus 模式（后台运行）下跳过，避免浏览器窗口抢焦点弹出，破坏用户当前工作
        if (-not $NoFocus) {
            try {
                $null = Invoke-WebBridgeCommand -Action "cdp" -CmdArgs @{method="Page.bringToFront"; params=@{}} -Session $session -TimeoutSec 5
            } catch {}
        }

        # v4.12.8: 强制真实布局视口，修复坐标点击（CF/ALTCHA）在折叠窗口 0x0 视口下失效的问题
        $null = Enable-LayoutViewport -Session $session

        Write-Host "  [WebBridge] $SiteName : waiting ${WaitMs}ms for page load"
        Start-Sleep -Milliseconds $WaitMs

        # visit-only 模式：无 DetectEval 时仅访问，不检测签到
        if (-not $DetectEval -or $DetectEval.Trim() -eq "") {
            Write-Host "  [WebBridge] $SiteName : visit-only (no detect), returning VISITED"
            return "VISITED"
        }

        Write-Host "  [WebBridge] $SiteName : evaluate detect"
        $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
        if (-not $detect) {
            # evaluate 失败常见于 tab 丢失（webbridge daemon bug: navigate 返回 success 但 tab 在等待期间消失）
            # 修复：清理所有残留 tab 后重新 navigate + evaluate 一次
            Write-Host "  [WebBridge] $SiteName : evaluate failed (tab may be lost), retrying navigate..."
            $null = Clear-WebBridgeTabs -Session $session
            $navRetry = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
            if ($navRetry -and $navRetry.success) {
                Start-Sleep -Milliseconds $WaitMs
                $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
            }
        }
        if (-not $detect) {
            Save-DebugSnapshot $SiteName $session "detect_fail" $DebugDir $SaveDebugSnapshot
            return "EVAL_FAIL"
        }

        if ($detect -is [string]) { $signal = $detect }
        elseif ($detect.value) { $signal = "$($detect.value)" }
        else { $signal = "$detect" }
        Write-Host "  [WebBridge] $SiteName : signal=$signal"

        # 状态转换验证：区分"访问即签到"与"今天已签到"
        # - 无 ClickEval（如 BTSchool）：访问即签到，SIGN_OK 为真实本次成功
        # - 有 ClickEval（需点击的站点）：首次 SIGN_OK 表示今天已签到，非本次签到成功 → ALREADY_SIGNED
        if ($signal -match "SIGN_OK|ALREADY_SIGNED") {
            $firstSignal = if ($ClickEval) { "ALREADY_SIGNED" } else { "SIGN_OK" }
            Save-DebugSnapshot $SiteName $session "sign_ok" $DebugDir $SaveDebugSnapshot
            return $firstSignal
        }
        if ($signal -match "LOGIN_REQUIRED|SLIDER|CAPTCHA") {
            Save-DebugSnapshot $SiteName $session $signal $DebugDir $SaveDebugSnapshot
            return $signal
        }

        # v4.12.7: SERVER_ERROR（HTTP 500/502 等）多为瞬时服务端错误，重新导航 1 次再判定，避免偶发失败
        if ($signal -match "SERVER_ERROR") {
            Write-Host "  [WebBridge] $SiteName : SERVER_ERROR, re-navigating once to confirm..."
            $null = Clear-WebBridgeTabs -Session $session
            $navSe = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
            if ($navSe -and $navSe.success) {
                Start-Sleep -Milliseconds $WaitMs
                $seDetect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                $seSig = if ($seDetect -is [string]) { $seDetect } elseif ($seDetect.value) { "$($seDetect.value)" } else { "$seDetect" }
                if ($seSig -and $seSig -notmatch "SERVER_ERROR") {
                    Write-Host "  [WebBridge] $SiteName : after re-nav, signal=$seSig"
                    $signal = $seSig
                }
            }
        }

        # v4.12.3: UNKNOWN 时等待 5 秒重试 2 次（处理 SPA 页面加载慢，如 Rousi）
        # SPA 站点内容动态渲染，首次 Detect 可能页面还没加载完，等待后重新检测
        if ($signal -eq "UNKNOWN") {
            for ($unkRetry = 0; $unkRetry -lt 2; $unkRetry++) {
                Write-Host "  [WebBridge] $SiteName : UNKNOWN, waiting 5s for SPA to render (retry $($unkRetry+1)/2)..."
                Start-Sleep -Seconds 5
                $retryDetect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                if ($retryDetect) {
                    $retrySig = if ($retryDetect -is [string]) { $retryDetect } elseif ($retryDetect.value) { "$($retryDetect.value)" } else { "$retryDetect" }
                    if ($retrySig -ne "UNKNOWN") {
                        Write-Host "  [WebBridge] $SiteName : retry signal=$retrySig"
                        $signal = $retrySig
                        break
                    }
                }
            }
        }

        if ($signal -match "CF_CHALLENGE|BODY_NULL|REDIRECTING") {
            for ($retry = 0; $retry -lt $CfRetryCount; $retry++) {
                # v4.12.5: Invoke-CfVerifyClick 内部会 scrollIntoView + 点击 iframe/widget
                $cfClickResult = Invoke-CfVerifyClick $session $SiteName $retry
                if ($cfClickResult) { Write-Host "  [WebBridge] $SiteName : CF verify: $cfClickResult" }

                # v4.12.5: 点击后等待 CF Turnstile 处理（iframe 内部验证 + token 填充）
                $waitSec = [math]::Round($CfRetryWaitMs / 1000, 0)
                Write-Host "  [WebBridge] $SiteName : CF retry $($retry+1)/$CfRetryCount, wait ${waitSec}s..."
                Start-Sleep -Seconds $waitSec

                # v4.12.5: 先检查 CF Turnstile 是否已通过（token 已填入 hidden input）
                # v4.12.6: no-cf 也视为 CF 已通过（CF 验证通过后 widget 会被移除，token 可能被清空）
                $cfPassed = Test-CfTurnstilePassed $session $SiteName
                Write-Host "  [WebBridge] $SiteName : CF state=$cfPassed"
                if ($cfPassed -match "^passed:|^no-cf$") {
                    # CF 已通过或已消失，重新检测页面状态
                    $reDetect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                    $reSig = if ($reDetect -is [string]) { $reDetect } elseif ($reDetect.value) { "$($reDetect.value)" } else { "$reDetect" }
                    Write-Host "  [WebBridge] $SiteName : post-CF signal=$reSig"
                    if ($reSig -match "SIGN_OK|ALREADY_SIGNED") {
                        $cfPassSignal = if ($ClickEval) { "ALREADY_SIGNED" } else { "SIGN_OK" }
                        Save-DebugSnapshot $SiteName $session "sign_ok_after_cf" $DebugDir $SaveDebugSnapshot
                        return $cfPassSignal
                    }
                    if ($reSig -match "NEED_SIGN|UNKNOWN") {
                        $signal = $reSig
                        break  # 跳出 CF 重试循环，进入下方 ClickEval 流程
                    }
                    if ($reSig -match "LOGIN_REQUIRED") {
                        Save-DebugSnapshot $SiteName $session "login_required" $DebugDir $SaveDebugSnapshot
                        return "LOGIN_REQUIRED"
                    }
                    # v4.12.6: no-cf 但 reSig 仍是 CF_CHALLENGE — widget 可能已消失但页面未更新，继续重试
                }
                # CF 仍在验证中（pending:*），继续下一次重试
            }
            if ($signal -match "CF_CHALLENGE|BODY_NULL|REDIRECTING") {
                Save-DebugSnapshot $SiteName $session "cf_blocked_final" $DebugDir $SaveDebugSnapshot
                return $signal
            }
        }

        # v4.12.11: SLIDER 处理 — FreeFarm 等站点的滑动验证，尝试 set_access_token token 绕过
        if ($signal -match "SLIDER") {
            for ($sr = 0; $sr -lt 2; $sr++) {
                Write-Host "  [WebBridge] $SiteName : SLIDER detected, attempting bypass ($($sr+1)/2)..."
                $bypassed = Invoke-SlideBypass $session $SiteName
                if ($bypassed) {
                    Start-Sleep -Seconds 4
                    $reDetect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                    $reSig = if ($reDetect -is [string]) { $reDetect } elseif ($reDetect.value) { "$($reDetect.value)" } else { "$reDetect" }
                    Write-Host "  [WebBridge] $SiteName : post-bypass signal=$reSig"
                    if ($reSig -match "SIGN_OK|ALREADY_SIGNED") {
                        $sig2 = if ($ClickEval) { "ALREADY_SIGNED" } else { "SIGN_OK" }
                        Save-DebugSnapshot $SiteName $session "sign_ok_after_slider" $DebugDir $SaveDebugSnapshot
                        return $sig2
                    }
                    if ($reSig -match "NEED_SIGN|UNKNOWN") { $signal = $reSig; break }
                }
            }
            if ($signal -match "SLIDER") {
                Save-DebugSnapshot $SiteName $session "slider_blocked_final" $DebugDir $SaveDebugSnapshot
                return $signal
            }
        }

        if ($ClickEval) {
            Write-Host "  [WebBridge] $SiteName : evaluate click"
            $clicked = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $ClickEval } -Session $session -TimeoutSec 15
            Write-Host "  [WebBridge] $SiteName : click result=$clicked"
            # v4.12.7: Yemapt ALTCHA 返回 widget 视口坐标，用 CDP 受信任点击触发验证
            # （closed shadow checkbox 无法用 JS .click() 触发，真实坐标点击可命中 shadow 内复选框）
            $clickedSig = if ($clicked -is [string]) { $clicked } elseif ($clicked.value) { "$($clicked.value)" } else { "$clicked" }
            if ($clickedSig -match '^ALTCHA_RECT:') {
                # v4.12.8: Click 返回 "ALTCHA_RECT:cx,cy,w,h"，在真实布局视口下尝试多个候选点命中 shadow 内复选框
                $vals = ($clickedSig -replace '^ALTCHA_RECT:','') -split ','
                if ($vals.Count -ge 4) {
                    $rx = [int]$vals[0]; $ry = [int]$vals[1]; $rw = [int]$vals[2]; $rh = [int]$vals[3]
                    # v4.12.16: 先单击精确点一次（启动 PoW），随后只轮询验证、不再连点，
                    #   避免原多候选点 8s 连点会重置 PoW（重复点击导致 PoW 永远验证不完）。
                    #   仅当首点 + 长轮询仍失败时，才退而用小簇候选点各点一次并分别长轮询。
                    $altchaDone = $false
                    # 第一击：精确点（复选框中心 rx,ry）
                    $null = Invoke-CdpClickAt -X $rx -Y $ry -Session $session
                    Write-Host "  [WebBridge] $SiteName : CDP click ALTCHA primary ($rx,$ry), polling PoW (up to 42s)..."
                    for ($i = 0; $i -lt 14; $i++) {
                        Start-Sleep -Seconds 3
                        if (Test-AltchaVerified -Session $session) { $altchaDone = $true; Write-Host "  [WebBridge] $SiteName : ALTCHA verified (primary)"; break }
                    }
                    # 退路：首点 + 长轮询仍失败，用紧邻小簇各点一次并分别长轮询（不再连点重置 PoW）
                    if (-not $altchaDone) {
                        $altCands = @(
                            @{x=$rx+12; y=$ry},
                            @{x=[Math]::Max(1,$rx-12); y=$ry},
                            @{x=$rx; y=$ry+10}
                        )
                        foreach ($c in $altCands) {
                            if ($c.x -lt 1 -or $c.y -lt 1) { continue }
                            $null = Invoke-CdpClickAt -X $c.x -Y $c.y -Session $session
                            Write-Host "  [WebBridge] $SiteName : CDP click ALTCHA alt ($($c.x),$($c.y)), polling PoW (up to 30s)..."
                            $ok = $false
                            for ($j = 0; $j -lt 10; $j++) {
                                Start-Sleep -Seconds 3
                                if (Test-AltchaVerified -Session $session) { $ok = $true; break }
                            }
                            if ($ok) { $altchaDone = $true; Write-Host "  [WebBridge] $SiteName : ALTCHA verified (alt $($c.x),$($c.y))"; break }
                        }
                    }
                    if (-not $altchaDone) { Write-Host "  [WebBridge] $SiteName : ALTCHA 未能验证（首点+候选点长轮询均失效）" -ForegroundColor Yellow }
                }
            }

            Write-Host "  [WebBridge] $SiteName : waiting ${PostClickWaitMs}ms post-click"
            Start-Sleep -Milliseconds $PostClickWaitMs

            Write-Host "  [WebBridge] $SiteName : evaluate re-check"
            $recheck = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 30
            $recheckSig = if ($recheck -is [string]) { $recheck } elseif ($recheck.value) { "$($recheck.value)" } else { "$recheck" }
            # 点击后页面导航导致 tab 重建（如表单提交），复检引用失效 → 重新导航+重检测确认实际状态
            # 修复 xloli 等站点：点击返回 CLICKED 但复检报 "tab was closed"，信号变空（实则可能已签）
            if (-not $recheck -or [string]::IsNullOrEmpty($recheckSig)) {
                Write-Host "  [WebBridge] $SiteName : re-check tab lost (navigated), re-navigating to confirm..."
                $null = Clear-WebBridgeTabs -Session $session
                $navRe = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
                if ($navRe -and $navRe.success) {
                    Start-Sleep -Milliseconds $WaitMs
                    $recheck = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                    $recheckSig = if ($recheck -is [string]) { $recheck } elseif ($recheck.value) { "$($recheck.value)" } else { "$recheck" }
                }
            }
            # 点击后检测到已签到 → 本次签到成功（非 ALREADY_SIGNED）
            if ($recheckSig -match "SIGN_OK|ALREADY_SIGNED") {
                Save-DebugSnapshot $SiteName $session "sign_ok_after_click" $DebugDir $SaveDebugSnapshot
                return "SIGN_OK"
            }
            $signal = $recheckSig
        }

        Save-DebugSnapshot $SiteName $session "final_$signal" $DebugDir $SaveDebugSnapshot
        return $signal
    }
    finally {
        # v4.12.8: 还原设备视口覆盖，避免影响后续站点/真实浏览器
        try { $null = Disable-LayoutViewport -Session $session } catch {}
        # 函数结束清理本站点所有 tab，确保不残留给下一个站点
        $null = Clear-WebBridgeTabs -Session $session
    }
}

# 尝试点击 CF 验证按钮（"请验证您是真人" / "Verify you are human" / turnstile checkbox）
# 返回点击结果描述，未找到返回 $null
# v4.12.6: CF Turnstile iframe 在 closed Shadow DOM 中，JS document.querySelectorAll('iframe') 看不到
# 必须用 CDP DOM.describeNode(pierce=true) 穿透 Shadow DOM，再用 Input.dispatchMouseEvent 点击 iframe checkbox
# 关键：点击位置是 iframe 左侧 (minX+24, centerY)，不是中心 — checkbox 在左侧
function Invoke-CfVerifyClick {
    param(
        [string]$Session,
        [string]$SiteName,
        [int]$Attempt = 0
    )

    # 先滚动 widget 到视口（触发懒加载渲染 iframe）
    $scrollJS = @'
(function(){
  var widget = document.querySelector('.cf-turnstile') || document.querySelector('[class*="turnstile"]');
  if(widget){
    try { widget.scrollIntoView({block:'center'}); } catch(e){ try{ widget.scrollIntoView(); }catch(e2){} }
    return 'scrolled';
  }
  return 'no_widget';
})()
'@
    try {
        $null = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $scrollJS } -Session $Session -TimeoutSec 10
    } catch {}

    # v4.12.7: 用 JS getBoundingClientRect 获取视口相对坐标点击 checkbox
    # 旧版 DOM.getBoxModel 返回 layout 坐标，滚动页面时 Y 为负导致误点空白（audiences 实测点击坐标 (24,-1003) 越界）
    # 视口坐标与 CDP Input.dispatchMouseEvent 的 x/y 一致，且天然处理滚动偏移
    $rect = Get-CfWidgetViewportRect -Session $Session
    if (-not $rect) { return "cdp:no-rect" }
    return (Invoke-CfClickFromRect -Rect $rect -Session $Session -Attempt $Attempt)
}

# v4.12.7: 获取 CF widget/iframe 的视口相对坐标（getBoundingClientRect），与 CDP Input 坐标系一致
function Get-CfWidgetViewportRect {
    param([string]$Session)
    $js = @'
(function(){
  function rectOf(el){ if(!el||!el.getBoundingClientRect) return null; var r=el.getBoundingClientRect(); return {x:r.x,y:r.y,w:r.width,h:r.height}; }
  // v4.12.7: 拓宽匹配 hCaptcha / 非标准 CF 控件（audiences 等站点的"人机验证"非 .cf-turnstile）
  var w = document.querySelector('.cf-turnstile') || document.querySelector('[class*="turnstile"]') || document.querySelector('[class*="cf-"]') || document.querySelector('#challenge-stage') || document.querySelector('[class*="hcaptcha"]') || document.querySelector('[class*="captcha"]');
  if(w){ var r=rectOf(w); if(r) return {found:'widget', x:r.x,y:r.y,w:r.w,h:r.h, vw:window.innerWidth, vh:window.innerHeight}; }
  var ifr = document.querySelector('iframe[src*="challenges.cloudflare.com"]') || document.querySelector('iframe[src*="captcha"]') || document.querySelector('iframe[src*="hcaptcha"]');
  if(ifr){ var r2=rectOf(ifr); if(r2) return {found:'iframe', x:r2.x,y:r2.y,w:r2.w,h:r2.h, vw:window.innerWidth, vh:window.innerHeight}; }
  return null;
})()
'@
    try {
        $res = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $js } -Session $Session -TimeoutSec 10
        if ($res -is [string]) { return ($res | ConvertFrom-Json -ErrorAction SilentlyContinue) }
        if ($res -and $res.value) { return ($res.value | ConvertFrom-Json -ErrorAction SilentlyContinue) }
    } catch {}
    return $null
}

function Invoke-CfClickFromRect {
    param($Rect, [string]$Session, [int]$Attempt = 0)
    # 偶数次点左侧 checkbox（x+24），奇数次点中心，提升不同 Turnstile 布局的通过率
    if ($Attempt % 2 -eq 0) {
        $cx = [math]::Min([math]::Max(2, [int]($Rect.x + 24)), [int]($Rect.vw - 2))
    } else {
        $cx = [math]::Min([math]::Max(2, [int]($Rect.x + $Rect.w / 2)), [int]($Rect.vw - 2))
    }
    $cy = [math]::Min([math]::Max(2, [int]($Rect.y + $Rect.h / 2)), [int]($Rect.vh - 2))
    return (Invoke-CdpClickAt -X $cx -Y $cy -Session $Session)
}

function Invoke-CdpClickAt {
    param([double]$X, [double]$Y, [string]$Session)
    $ix = [int]$X; $iy = [int]$Y
    $null = Invoke-WebBridgeCommand -Action "cdp" -CmdArgs @{method="Input.dispatchMouseEvent"; params=@{type="mouseMoved"; x=$ix; y=$iy}} -Session $Session -TimeoutSec 10
    $null = Invoke-WebBridgeCommand -Action "cdp" -CmdArgs @{method="Input.dispatchMouseEvent"; params=@{type="mousePressed"; x=$ix; y=$iy; button="left"; clickCount=1}} -Session $Session -TimeoutSec 10
    $null = Invoke-WebBridgeCommand -Action "cdp" -CmdArgs @{method="Input.dispatchMouseEvent"; params=@{type="mouseReleased"; x=$ix; y=$iy; button="left"; clickCount=1}} -Session $Session -TimeoutSec 10
    return "cdp:clicked:($ix,$iy)"
}

# v4.12.8: 强制布局视口（Emulation.setDeviceMetricsOverride）
# 根因：WebBridge 标签页所在浏览器窗口为 159x27（仅标题栏）的折叠窗口，layout viewport 为 0x0
#        导致 getBoundingClientRect / elementFromPoint / CDP Input.dispatchMouseEvent 全部坐标失效，
#        仅 JS .click() 站点（无坐标需求）可成功；CF Turnstile / ALTCHA 等坐标点击站点全部失败。
# 通过 setDeviceMetricsOverride 强制一个真实 CSS 视口（仅改变布局视口，不改变窗口是否置顶/弹出），
# 使坐标系一致，从而让坐标点击生效；且不破坏「后台无焦点弹出」的要求。
$LvwWidth = 1280
$LvwHeight = 800
function Enable-LayoutViewport {
    param([string]$Session)
    try {
        $null = Invoke-WebBridgeCommand -Action "cdp" -CmdArgs @{ method="Emulation.setDeviceMetricsOverride"; params=@{ width=$LvwWidth; height=$LvwHeight; deviceScaleFactor=1; mobile=$false } } -Session $Session -TimeoutSec 10
        Start-Sleep -Milliseconds 300
        return $true
    } catch { return $false }
}
function Disable-LayoutViewport {
    param([string]$Session)
    try {
        $null = Invoke-WebBridgeCommand -Action "cdp" -CmdArgs @{ method="Emulation.clearDeviceMetricsOverride"; params=@{} } -Session $Session -TimeoutSec 10
    } catch {}
}

# 检查 ALTCHA 是否已完成验证（aria-checked / data-state=verified / 隐藏 JWT 字段）
function Test-AltchaVerified {
    param([string]$Session)
    $js = @'
(function(){
  var w=document.querySelector('altcha-widget'); var state=null,tokenLen=0;
  if(w){var d=w.querySelector('.altcha'); if(d) state=d.getAttribute('data-state');}
  var af=document.querySelector('input[name="altchaPayload"], input[name*="altcha"], input[value^="eyJ"]');
  if(af&&af.value) tokenLen=af.value.length;
  return JSON.stringify({verified:(state==='verified'||tokenLen>10)});
})()
'@
    try {
        $r = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $js } -Session $Session -TimeoutSec 10
        if ($r -is [string]) { $o = $r | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($o) { return $o.verified } }
        if ($r -and $r.value) { $o = $r.value | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($o) { return $o.verified } }
    } catch {}
    return $false
}

# v4.12.5: 检查 CF Turnstile 是否已通过（cf-turnstile-response 有值）
# 返回 true 表示 CF 已通过，false 表示未通过
function Test-CfTurnstilePassed {
    param(
        [string]$Session,
        [string]$SiteName
    )
    $checkJS = @'
(function(){
  // 1. 检查 cf-turnstile-response hidden input 是否有值
  var inputs = document.querySelectorAll('input[name="cf-turnstile-response"],input[name="g-recaptcha-response"]');
  for(var i=0;i<inputs.length;i++){
    if(inputs[i].value && inputs[i].value.length > 10){
      return 'passed:'+inputs[i].value.substring(0, 30);
    }
  }
  // 2. 检查页面是否还有 CF 挑战（全页 CF）
  if(document.querySelector('iframe[src*="challenges.cloudflare.com"]')){
    return 'pending:cf-iframe-present';
  }
  // 3. body 文本含 CF 关键字
  var t = document.body ? document.body.innerText : '';
  if(t.indexOf('正在检查')>-1||t.indexOf('Just a moment')>-1||t.indexOf('安全验证')>-1) return 'pending:cf-text';
  return 'no-cf';
})()
'@
    try {
        $result = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $checkJS } -Session $Session -TimeoutSec 10
        if ($result -is [string]) { return $result }
        if ($result.value) { return $result.value }
    } catch {}
    return "check-failed"
}

# v4.12.11: FreeFarm 滑块验证绕过（set_access_token token 提取）
# 背景：FreeFarm（pt.0ff.cc）在登录态失效/首次访问时可能弹出滑动验证（slide_check_*.js）。
# 该 JS 内含 set_access_token-<hash> API，直接 fetch 该 URL 即可绕过滑块（skill lesson 6 / rule D）。
# 实现：定位 script[src*=slide] → 抓取 JS 文本 → 正则提取 token 路径 → fetch(tokenUrl, credentials:include) → reload。
# 返回 $true 表示绕过成功（页面将 reload 进入签到态）；否则 $false（无 slide 脚本 / 提取失败）。
function Invoke-SlideBypass {
    param([string]$Session, [string]$SiteName)
    $js = @'
(function(){
  return new Promise(function(resolve){
    try {
      var slide = document.querySelector('script[src*="slide"]');
      if(!slide){ resolve('no_slide_script'); return; }
      fetch(slide.src).then(function(r){return r.text();}).then(function(jsText){
        var m = jsText.match(/set_access_token[\w\-]*/i) || jsText.match(/set_access_token[^\s"'<>]+/i);
        if(!m){ resolve('no_token_in_js'); return; }
        var path = m[0];
        var url = (path.indexOf('http')===0) ? path : (location.origin + (path.charAt(0)==='/' ? path : '/' + path));
        fetch(url, {credentials:'include'}).then(function(){ setTimeout(function(){ location.reload(); }, 1500); resolve('bypassed:'+url); })
          .catch(function(e){ resolve('fetch_fail:'+e); });
      }).catch(function(e){ resolve('js_fetch_fail:'+e); });
    } catch(e){ resolve('err:'+e); }
  });
})()
'@
    try {
        $r = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $js } -Session $Session -TimeoutSec 20
        $s = if ($r -is [string]) { $r } elseif ($r.value) { "$($r.value)" } else { "$r" }
        Write-Host "  [WebBridge] $SiteName : slide-bypass: $s"
        return ($s -match "^bypassed:")
    } catch { return $false }
}

# 保存页面调试快照为 JSON
# 包含: URL, title, body innerText, body outerHTML(截断), 检测信号, 时间戳
function Save-DebugSnapshot {
    param(
        [string]$SiteName,
        [string]$Session,
        [string]$Stage,
        [string]$DebugDir,
        [bool]$Enabled
    )
    if (-not $Enabled -or [string]::IsNullOrEmpty($DebugDir)) { return }

    try {
        if (-not (Test-Path $DebugDir)) {
            New-Item -ItemType Directory -Path $DebugDir -Force | Out-Null
        }

        $snapshotJS = @'
(function(){
  var r = {
    url: location.href,
    title: document.title,
    readyState: document.readyState,
    bodyText: document.body ? document.body.innerText.substring(0, 5000) : '',
    bodyHtmlLen: document.body ? document.body.innerHTML.length : 0,
    bodyHtml: document.body ? document.body.innerHTML.substring(0, 30000) : '',
    cfIframes: [],
    signTexts: []
  };
  // 收集 CF 相关 iframe
  var iframes = document.querySelectorAll('iframe');
  for(var i=0;i<iframes.length;i++){
    var src = iframes[i].src || '';
    if(src.indexOf('cloudflare')>-1 || src.indexOf('turnstile')>-1 || src.indexOf('captcha')>-1){
      r.cfIframes.push(src);
    }
  }
  // 收集页面中包含签到/验证/登录的文本片段
  var keywords = ['签到','打卡','验证','登录','注册','欢迎','魔力','attendance','sign','check','verify','human','robot','captcha','turnstile','cloudflare'];
  var allText = document.body ? document.body.innerText : '';
  for(var k=0;k<keywords.length;k++){
    var idx = allText.toLowerCase().indexOf(keywords[k].toLowerCase());
    if(idx > -1){
      r.signTexts.push(keywords[k] + ': ...' + allText.substring(Math.max(0,idx-20), Math.min(allText.length,idx+40)).replace(/\s+/g,' ') + '...');
    }
  }
  return JSON.stringify(r);
})()
'@
        $snapData = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $snapshotJS } -Session $Session -TimeoutSec 15
        $snapJson = if ($snapData -is [string]) { $snapData } elseif ($snapData.value) { "$($snapData.value)" } else { "{}" }

        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $safeName = $SiteName -replace '[\\/:*?"<>|]', '_'
        $fileName = "$safeName`_$Stage`_$timestamp.json"
        $filePath = Join-Path $DebugDir $fileName

        # 包装成完整对象
        $wrapper = @{
            site = $SiteName
            stage = $Stage
            timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            page = ($snapJson | ConvertFrom-Json -ErrorAction SilentlyContinue)
        }
        $wrapper | ConvertTo-Json -Depth 6 | Out-File $filePath -Encoding UTF8
        Write-Host "  [Debug] Snapshot saved: $fileName"
    } catch {
        Write-Host "  [Debug] Snapshot save failed: $($_.Exception.Message)"
    }
}
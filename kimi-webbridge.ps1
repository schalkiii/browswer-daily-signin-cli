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

# v4.13.6: 连接状态三态探测。
# ⚠️ 不能用 'ping'——当前扩展版本不支持该动作（返回 "Unknown tool: ping"），且 ping 仅证明 daemon
#   HTTP 存活、无法证明扩展已连接。改用 'list_tabs'（最轻量的扩展路径动作）：
#   ok             = daemon + extension 均正常（list_tabs 成功）
#   extension_down = daemon 有响应但扩展断开/报错
#   daemon_down    = HTTP 层失败（端口未监听/进程死亡）
function Test-WebBridgeConnection {
    param([int]$TimeoutSec = 5)
    try {
        $resp = Invoke-RestMethod -Uri $WebBridgeBase -Method Post -ContentType "application/json" -Body '{"action":"list_tabs","args":{},"session":"__health__"}' -TimeoutSec $TimeoutSec
        if ($resp.ok) { return "ok" }
        return "extension_down"
    } catch {
        # 502/超时/拒绝连接 → daemon 层不可用；但 5xx 带 JSON body 的情况多为扩展断开（daemon 在代理转发）
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 502) { return "extension_down" }
        return "daemon_down"
    }
}

# v4.13.6: daemon 重启（自愈核心）。stop→清 pid→start→轮询端口与扩展重连。
# 扩展与 daemon 之间会自动重连：daemon 重启后扩展一般在数秒~30s 内恢复连接，故重启后轮询等待。
# 安全约束：不使用 iex；exe 缺失时提示手动安装（自动下载 install.ps1 涉及远程代码，只提示不执行）。
function Restart-WebBridgeDaemon {
    param([int]$ExtensionWaitSec = 30)
    $wbDir = Join-Path $env:USERPROFILE ".kimi-webbridge"
    $pidFile = Join-Path $wbDir "daemon.pid"
    $exePath = Join-Path $wbDir "bin\kimi-webbridge.exe"

    if (-not (Test-Path $exePath)) {
        Write-Host "[WebBridge] daemon 未安装（缺 $exePath）。请手动安装: irm https://cdn.kimi.com/webbridge/install.ps1 下载后审查执行" -ForegroundColor Yellow
        return $false
    }

    Write-Host "[WebBridge] 重启 daemon..." -ForegroundColor Yellow
    try { & $exePath stop 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2
    # 兜底：stop 无效时按进程名清理
    try { Get-Process -Name "kimi-webbridge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    # 清残留 pid 文件（.NET 方法绕过安全限制）
    if (Test-Path $pidFile) { try { [System.IO.File]::Delete($pidFile) } catch {} }

    try {
        & $exePath start 2>&1 | Out-Null
    } catch {
        Write-Host "[WebBridge] daemon 启动命令失败: $_" -ForegroundColor Red
        return $false
    }
    Start-Sleep -Seconds 3
    $portCheck = netstat -ano 2>$null | Select-String "127.0.0.1:10086.*LISTENING"
    if (-not $portCheck) {
        Write-Host "[WebBridge] daemon 重启失败（端口未监听）" -ForegroundColor Red
        return $false
    }
    # 端口已监听，等待扩展重连（轮询 list_tabs）
    $deadline = (Get-Date).AddSeconds($ExtensionWaitSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-WebBridgeConnection) -eq "ok") {
            Write-Host "[WebBridge] daemon 重启成功，扩展已重连" -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 3
    }
    Write-Host "[WebBridge] daemon 已重启，但扩展 ${ExtensionWaitSec}s 内未重连（请检查浏览器是否在运行/扩展是否启用）" -ForegroundColor Yellow
    return $false
}

# daemon 健康检查与自动修复（批处理/单站入口调用）
# v4.13.6: 探测改用 Test-WebBridgeConnection（list_tabs 真连通判据，弃用扩展不支持的 ping）；
#   daemon_down / extension_down 均尝试 Restart-WebBridgeDaemon 自愈一次。
function Ensure-WebBridgeDaemon {
    $state = Test-WebBridgeConnection
    if ($state -eq "ok") { return $true }
    Write-Host "[WebBridge] 连接异常（$state），尝试自愈重启..." -ForegroundColor Yellow
    return (Restart-WebBridgeDaemon)
}

# v4.13.6: 运行中自愈——每站点开工前快速探测，断连则整个会话内只自动重启一次（防止反复重启风暴）。
$script:WbSelfHealTried = $false
function Ensure-WebBridgeHealthy {
    $state = Test-WebBridgeConnection -TimeoutSec 4
    if ($state -eq "ok") { return $true }
    if ($script:WbSelfHealTried) {
        Write-Host "  [WebBridge] 连接仍异常（$state），本次运行已自愈过，不再重启" -ForegroundColor Yellow
        return $false
    }
    $script:WbSelfHealTried = $true
    Write-Host "  [WebBridge] 站点开工前检测到连接异常（$state），触发自愈重启..." -ForegroundColor Yellow
    return (Restart-WebBridgeDaemon)
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

# v4.12.25: 统一从 daemon 返回值提取信号字符串。
# 消除 Test-WebBridgeSignIn 中 ~10 处复制粘贴的 "if ($x -is [string])...elseif ($x.value)" 样板，
# 降低后续出现"漏一行 .value 分支"类不一致 bug 的概率。
function Get-ResultSignal {
    param($Result)
    if ($null -eq $Result) { return $null }
    if ($Result -is [string]) { return $Result }
        if ($Result.value) { return "$($Result.value)" }
    return "$Result"
}

# 查询会话当前存活的 tab 列表（list_tabs 轻量探测）。
# 返回 daemon 的 tabs 响应对象；extension 未连接 / 探测失败时返回 $null。
# 统一此处可消除各函数里散落的 "Invoke-WebBridgeCommand -Action list_tabs" 样板。
function Get-WebBridgeTabs {
    param([string]$Session = "daily-signin", [int]$TimeoutSec = 5)
    try {
        return (Invoke-WebBridgeCommand -Action "list_tabs" -CmdArgs @{} -Session $Session -TimeoutSec $TimeoutSec)
    } catch { return $null }
}

# 判定会话内是否仍有存活 tab（用于"tab 是否已建立/存活"判定）。
function Test-HasActiveTab {
    param([string]$Session = "daily-signin", [int]$TimeoutSec = 5)
    $resp = Get-WebBridgeTabs -Session $Session -TimeoutSec $TimeoutSec
    return ($null -ne $resp -and $resp.tabs -and $resp.tabs.Count -ge 1)
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
            $listResp = Get-WebBridgeTabs -Session $Session -TimeoutSec 5
            if ($null -eq $listResp) {
                # extension 未连接 / 无法列出 tab → 返回 -1 让调用方区分"0 残留"与"探测失败"
                return -1
            }
            if (-not $listResp.tabs -or $listResp.tabs.Count -eq 0) {
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

# v4.12.19: daemon 级整会话强关（不依赖 per-tab extension 状态）
# 用于: (a) per-tab 关闭失效（extension 断开）时的兜底清理；(b) 批处理/续跑块收尾与块间清扫。
# 与 Clear-WebBridgeTabs 区别: 此处直接让 daemon 关闭 session 下全部 tab，即使 extension 断开也能生效。
# 下一站点 navigate 会重建 tab（signin-batch.ps1 末尾 close_session 后重跑即用此机制）。
function Close-WebBridgeSession {
    param([string]$Session = "daily-signin")
    try {
        $response = Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session $Session -TimeoutSec 8
        return ($null -ne $response)
    } catch { return $false }
}

# v4.12.25: 「关后校验 + 重试」——把 v4.12.24 的"整会话强关"从静默假设变成可观测。
# 根因风险：v4.12.24 假设 close_session 能关掉折叠 159x27 后台窗口里的 tab，
#   但该场景从未被实证；而 list_tabs/close_tab 对这类 tab 已证不可靠。若 close_session 同样漏关，
#   v4.12.24 会静默累积（正是用户历史现象）。
# 本函数：close_session -> list_tabs 校验 -> 仍非空则再 close_session 一次 + 退路 Clear-WebBridgeTabs(逐 id 关)
#   -> 再次 list_tabs 校验。无论 daemon 是否漏关，泄漏都被限制在"下一站开工前"一瞬，且 $leaked 会让调用方在日志看见。
function Close-SiteTabs-Verified {
    param([string]$Session = "daily-signin", [int]$VerifyTimeoutSec = 5)
    $leaked = 0
    # 第一关：daemon 级整会话强关（不依赖 extension，extension 断开也生效）
    try { $null = Close-WebBridgeSession -Session $Session } catch {}
    # 第二关：逐 id 关（best-effort，extension 连上时 close_tab 通常可用；即便第一关已清空也无害）
    #   v4.13.3: 提为常驻第二关（非仅漏关时才跑）——close_session 对"卡在加载中/折叠后台窗口"的 tab
    #   可能漏关而 list_tabs 又因 extension 抖动返回空(假阴性)，导致退路永不触发、tab 静默累积（用户 07-26 复现）。
    try { $null = Clear-WebBridgeTabs -Session $Session } catch {}
    # 校验
    try {
        $chk = Get-WebBridgeTabs -Session $Session -TimeoutSec $VerifyTimeoutSec
        if ($chk -and $chk.tabs -and $chk.tabs.Count -gt 0) {
            $leaked = $chk.tabs.Count
            # 第三关：再强关 + 再逐 id 关（应对偶发漏关）
            try { $null = Close-WebBridgeSession -Session $Session } catch {}
            try { $null = Clear-WebBridgeTabs -Session $Session } catch {}
            # 末次校验
            try {
                $chk2 = Get-WebBridgeTabs -Session $Session -TimeoutSec $VerifyTimeoutSec
                if ($chk2 -and $chk2.tabs) { $leaked = $chk2.tabs.Count }
            } catch { $leaked = -1 }
        }
    } catch { $leaked = -1 }
    if ($leaked -gt 0) {
        Write-Host "  [WebBridge] ⚠️ close_session 后仍有 $leaked 个 tab 残留（折叠窗口/extension 抖动？），请检查 daemon" -ForegroundColor Yellow
    }
    return ($leaked -eq 0)
}

# 结构性单 tab —— 根治重复开 tab / tab 泄漏的核心约束：
#   • 不再依赖 list_tabs 探测 + close_tab 按 id 关（折叠后台窗口中 active=False 的 tab 难命中，曾导致累积泄漏）；
#   • 改为 Close-WebBridgeSession（daemon 级强关，即使 extension 抖动/断开也生效）整会话清空，再开唯一一个。
#   任意时刻本会话 ≤ 1 个 tab；所有重试路径（NAV_FAIL / extension 就绪 / evaluate 丢 tab / CF / SLIDER / 点击后）
#   都走本函数 → 每次必先进场清场再开新，满足"即便重试也先关旧 tab 再开新"。
function Open-SiteTab {
    param(
        [string]$Url,
        [string]$Session = "daily-signin",
        [int]$NavTimeoutSec = 120,
        [bool]$ForceLayoutViewport = $false,
        # v4.13.12: visit-only 站点（无 DetectEval）只需"打开页面"即达成目的，
        #   不关心 DOMContentLoaded 是否完成。对 kufirc 这类慢站（30s 内 DOM 不就绪、tab 一直转圈），
        #   把 domcontentloaded 当硬门槛会触发反复清场重开 → 窗口里一堆 tab 在转圈。
        #   开启后：navigate 命令已提交、list_tabs 确认 tab 已建立（即便仍在加载）即判成功，
        #   不再进入外层 re-navigate 重试（避免重复开 tab）。
        [switch]$VisitOnly
    )
    # 结构性清场：整会话 daemon 级强关 + 关后校验（Close-SiteTabs-Verified）。
    # 不依赖 extension / list_tabs 状态，若 daemon 漏关会在日志告警（不再静默累积）。
    # ⚠️ 不变量：所有站点必须共用同一 $Session（"daily-signin"）——本函数靠 close_session 清掉"上一站点"的 tab；
    #    若各站用独立 session，close_session 只清自己 → 上一站 tab 永不关 → 泄漏重现（signin-batch.ps1 曾有的 $session="pt$idx" 死变量即此陷阱）。
    try { $null = Close-SiteTabs-Verified -Session $Session } catch {}

    # 打开目标站点：navigate（waitUntil=domcontentloaded）。同一会话内优先复用已有 tab，
    # 不携带 newTab，避免"页面还在加载就又 newTab"导致重复 tab 累积（musopia 抖动时曾一次开 6+ 个）。
    #
    # 关于曾经的 "seed tab" 方案（data: 种子页 → evaluate location.href 跳转）为何被移除：
    #   该方案基于"daemon navigate 会死等 load、超时即销毁 tab"的判断，但 HTTP 层实测结论相反——
    #   navigate + newTab 打开真实站点约 9s 返回 success，daemon 并不会无限等 load。
    #   而 seed 方案自身有三处硬伤，正是现场三个症状的来源：
    #     1) 地址栏/页面停留在 data:text/html,...seed —— 后续 evaluate 跳转失败时无从恢复，用户直接看到种子页；
    #     2) seed 失败兜底会把 http://127.0.0.1:10086（daemon 自身端口）开进浏览器，页面显示 daemon 响应；
    #     3) 对**已存在的 tab** 做 navigate 需 daemon 走另一条慢路径，实测 20.43s，
    #        恰好超过此处写死的 20s 超时 → 每站刷 "HttpClient.Timeout of 20 seconds elapsing" 报错。
    #   去掉中转后，跳转与读 DOM 天然同属同一个 tab，v4.13.8 想解决的
    #   "cdp 与 evaluate 命中不同 tab" 问题也不复存在。
    #
    # 重复 tab / "has no tab" 风暴根治（v4.13.10 → v4.13.11）：
    #   根因是 navigate 默认死等 `load` 事件——CF 盾 / 慢子资源 / 长连接 / 折叠后台窗口的 `load` 在 30s 内
    #   不触发 → 扩展回 extension_error 且**连 tab 一并销毁**。实测关键：daemon navigate **支持 waitUntil 参数**，
    #   传 `domcontentloaded` 即只等 DOMContentLoaded（CF 盾站 DOM 几秒内就绪），zhihu 由"30.6s 超时销毁 tab"
    #   变为 11.5s 返回 ok=True 且 tab 存活、evaluate 拿到真实 DOM（bodyLen=1169），不再超时、不再 "has no tab"。
    #   v4.13.11 进一步修正：v4.13.10 的内层"兜底再 navigate newTab 一次"在网络抖动站（musopia）
    #   会叠加出 6+ tab——因为首个超时 tab 还没被 daemon 销毁就又 newTab。本版改为：
    #     • 进入时 Close-SiteTabs-Verified 清场 → 开工前 0 tab；
    #     • 仅一次 navigate，且**不带 newTab**（复用当前 tab），只有 list_tabs 确认无任何 tab 才 newTab；
    #     • 失败即返回，交上层 re-navigate 统一重试——重试前 Close-SiteTabs-Verified 已清场，不会累积；
    #     • 删除内层"兜底再 newTab"分支，从根消除"加载未完又开新 tab"。
    #   不使用 about:blank / data: 作中转跳板：实测 about:blank 同样 20s+ 不返回（扩展等不到 load）。
    $navOk = $false
    $navErr = ""

    # 决定 newTab：仅当会话内确实没有任何 tab 时才 newTab（复用优先，避免重复 tab）
    $needNewTab = $true
    if (Test-HasActiveTab -Session $Session) { $needNewTab = $false }

    try {
        $navArgs = @{ url = $Url; waitUntil = "domcontentloaded" }
        if ($needNewTab) { $navArgs.newTab = $true }
        $nav = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs $navArgs -Session $Session -TimeoutSec $NavTimeoutSec
        $navOk = ($null -ne $nav -and $nav.success)
    } catch {
        $navOk = $false
        $navErr = "$_"
    }
    if (-not $navOk) {
        # v4.13.12: visit-only 慢站特例——navigate 命令已发出、tab 已建立（页面仍在转圈也视为"已打开"），
        #   即达"访问"目的。不再清场重试，避免反复开 tab。仅当 tab 确实未建立才判失败。
        if ($VisitOnly) {
            if (Test-HasActiveTab -Session $Session) {
                Write-Host "  [WebBridge] Open-SiteTab: visit-only 慢站，tab 已建立（仍在加载中）即判访问成功" -ForegroundColor Green
                return @{ success = $true; method = "navigate-visitOnly"; url = $Url }
            }
            Write-Host "  [WebBridge] Open-SiteTab: visit-only 但 tab 未建立 -> 失败" -ForegroundColor Red
            return @{ success = $false; error = "navigate_failed" }
        }
        # domcontentloaded 失败（extension 未连 / daemon 异常 / 极端慢站 / 网络抖动）：
        # 清场后直接返回失败，交上层 re-navigate 重试——不再此处二次 newTab（防重复 tab 累积）。
        try { $null = Close-SiteTabs-Verified -Session $Session } catch {}
        if ($navErr) {
            Write-Host "  [WebBridge] Open-SiteTab: navigate 失败（domcontentloaded）- $navErr" -ForegroundColor Red
        } else {
            Write-Host "  [WebBridge] Open-SiteTab: navigate 未成功（domcontentloaded）" -ForegroundColor Red
        }
        return @{ success = $false; error = "navigate_failed" }
    }

    # 确认 tab 仍存活；否则视为失败触发上层重试（返回前清场，避免遗留）
    if (-not (Test-HasActiveTab -Session $Session)) {
        try { $null = Close-SiteTabs-Verified -Session $Session } catch {}
        Write-Host "  [WebBridge] Open-SiteTab: 导航后 tab 丢失" -ForegroundColor Red
        return @{ success = $false; error = "tab_lost_after_nav" }
    }

    # v4.13.6: 默认自然分辨率（用户 07-26 要求：不需坐标系一致的站点一律用浏览器窗口原生分辨率）。
    #   仅当站点显式声明 ForceLayoutViewport=$true（CF Turnstile/ALTCHA/SLIDER 等坐标点击站）才在导航后
    #   立即启用 1280x800 覆盖——这类站的坐标必须在 rect 计算前就固定视口，否则 getBoundingClientRect
    #   与 Input.dispatchMouseEvent 坐标系不一致。其余站点若中途意外遇到 CF 挑战，由
    #   Invoke-CfVerifyClick 顶部的「懒启用」兜底（先启用视口再算 rect，坐标系仍一致）。
    if ($ForceLayoutViewport) {
        $null = Enable-LayoutViewport -Session $Session
    }

    # 合成成功对象，使调用方走正常 Detect / Wait 流程（就绪判定交给 Wait-PageReady 轮询，不再依赖 load 事件）
    return @{ success = $true; method = "navigate-newTab"; url = $Url }
}

function Test-WebBridgeSignIn {
    param(
        [string]$SiteName,
        [string]$Url,
        [string]$DetectEval,
        [string]$ClickEval,
        [int]$WaitMs = 5000,
        [int]$PostClickWaitMs = 3000,
        # v4.13.13: 导航超时上限由 60s 提升到 120s（2 分钟）。
        #   PS 侧 -TimeoutSec 是给 daemon 的请求超时，须足够大才能覆盖慢站（CF 盾 / 长 DOM 构建 / 折叠后台窗口）。
        #   注意：PS 侧超时只决定"PS 何时把请求判失败"，真正硬约束在扩展内部 30s load 超时——
        #   但 domcontentloaded 模式下门槛是 DOMContentLoaded（慢站通常数秒内就绪），故 120s 足以包容绝大多数慢站而不被 PS 抢先砍断。
        [int]$NavTimeoutSec = 120,
        [int]$CfRetryCount = 3,
        [int]$CfRetryWaitMs = 10000,
        [bool]$SaveDebugSnapshot = $false,
        [string]$DebugDir = "",
        [bool]$NoFocus = $false,
        # v4.13.6: 全局默认动态轮询 45s（用户 07-26 要求：所有站点长延迟+动态轮询，就绪即继续）。
        #   页面就绪（body 文本足够长且无盾关键词）通常 2~6s 即返回，不会拖慢正常站点；
        #   过盾/慢站最多等 45s。站点可用 $cfg.LoadWaitSec 覆盖（HDKYL=60）；显式 0 退回固定 WaitMs。
        [int]$LoadWaitSec = 45,
        [string]$ReadyEval = "",
        [bool]$ForceLayoutViewport = $false
    )
    $session = "daily-signin"
    # visit-only 路由：优先以调用方显式传入的 -VisitOnly 开关为准（由 Invoke-WebSignIn 按 sites.json 的
    #   strategy=='visit-only' 推导）；DetectEval 为空作为兜底推断，兼容未传 strategy 的直调用法。
    $isVisitOnly = $VisitOnly -or (-not $DetectEval -or $DetectEval.Trim() -eq "")

    # v4.13.6: 站点开工前连接自检——daemon/extension 断连时自动重启自愈（每次运行至多一次）
    if (-not (Ensure-WebBridgeHealthy)) {
        Write-Host "  [WebBridge] $SiteName : daemon/extension 不可用且自愈失败 -> NAV_FAIL" -ForegroundColor Red
        return "NAV_FAIL"
    }

    # v4.12.24: 入口不再预清残留 tab —— Open-SiteTab 每次都会整会话强关(Close-WebBridgeSession)，
    #   结构保证本会话 ≤ 1 个 tab，无需此处 list_tabs 探测(抖动会误报，曾是漏 tab 根因之一)。

    try {
        Write-Host "  [WebBridge] $SiteName : navigate -> $Url"
        $nav = Open-SiteTab -Url $Url -Session $session -NavTimeoutSec $NavTimeoutSec -ForceLayoutViewport $ForceLayoutViewport -VisitOnly:$isVisitOnly
        # v4.12.3: extension 冷启动等待 — daemon 启动后 extension 需要几秒才连接
        # 首个站点可能 navigate 失败，等待 extension 就绪后重试
        if (-not $nav -or -not $nav.success) {
            $listCheck = Get-WebBridgeTabs -Session $session -TimeoutSec 5
            if (-not $listCheck) {
                Write-Host "  [WebBridge] $SiteName : extension 未就绪，等待重试..." -ForegroundColor Yellow
                for ($extRetry = 0; $extRetry -lt 3; $extRetry++) {
                    Start-Sleep -Seconds 5
                    $listCheck = Get-WebBridgeTabs -Session $session -TimeoutSec 5
                    if ($listCheck) {
                        Write-Host "  [WebBridge] $SiteName : extension 已就绪（重试 $($extRetry+1)/3）" -ForegroundColor Green
                        $nav = Open-SiteTab -Url $Url -Session $session -NavTimeoutSec $NavTimeoutSec -ForceLayoutViewport $ForceLayoutViewport -VisitOnly:$isVisitOnly
                        break
                    }
                    Write-Host "  [WebBridge] $SiteName : extension 重试 $($extRetry+1)/3 仍未就绪" -ForegroundColor Yellow
                }
            }
                if (-not $nav -or -not $nav.success) {
                    # v4.12.7: daemon 内部 30s 硬编码导航超时（lesson 36）多为服务端慢/瞬时；
                    # 重试导航 2 次以对抗偶发超时，仍失败才判 NAV_FAIL。
                    # v4.13.11: 重试前先清场（Open-SiteTab 进入虽也清，但此处显式清能保证
                    #   daemon 已完成上一轮超时 tab 的销毁，避免"上一个还卡在加载就又开新 tab"），
                    #   且间隔拉长到 12s 给 daemon 销毁超时 tab 的时间；不再内层二次 newTab。
                    $navRetries = 0
                    while ((-not $nav -or -not $nav.success) -and $navRetries -lt 2) {
                        Write-Host "  [WebBridge] $SiteName : NAV_FAIL, re-navigate retry $($navRetries+1)/2..."
                        Start-Sleep -Seconds 12
                        try { $null = Close-SiteTabs-Verified -Session $session } catch {}
                        $nav = Open-SiteTab -Url $Url -Session $session -NavTimeoutSec $NavTimeoutSec -ForceLayoutViewport $ForceLayoutViewport -VisitOnly:$isVisitOnly
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

        # v4.12.25: 布局视口覆盖已收进 Open-SiteTab（每次 navigate 成功后立即启用），
        #   此处不再重复启用，避免函数内重开 tab(272/306/475) 后视口丢失导致 CF/ALTCHA 坐标点击失效。

        # v4.13.12: visit-only 站点（无 DetectEval）只需"打开页面"即达成目的，无需等待 DOM 就绪——
        #   慢站 Wait-PageReady 会干等 LoadWaitSec（默认 45s），纯属浪费；且此时 tab 可能仍在加载、evaluate
        #   易失败，对 visit-only 无检测意义。故 visit-only 跳过 Wait-PostNavigate，直接返回 VISITED。
        if (-not $isVisitOnly) {
            Wait-PostNavigate -Session $session -SiteName $SiteName -WaitMs $WaitMs -LoadWaitSec $LoadWaitSec -ReadyEval $ReadyEval
        }

        # visit-only 模式：无 DetectEval 时仅访问，不检测签到
        if (-not $DetectEval -or $DetectEval.Trim() -eq "") {
            Write-Host "  [WebBridge] $SiteName : visit-only (no detect), returning VISITED"
            return "VISITED"
        }

        # v4.12.18: 全局 chrome-error 预检（对所有站点生效）。
        # 站点专属 detect 不会识别 chrome-error:// 页（如 V2EX 的 ERR_CONNECTION_CLOSED
        # 会被误判成 UNKNOWN；NexusPHP 站虽有判断但非 NexusPHP 站缺此逻辑）。
        # 这里先判连接错误，直接归 SERVER_ERROR（属网络/代理/站点侧，非代码缺陷）。
        $chromeErrJs = @'
(function(){
  try {
    if(location.protocol==='chrome-error:') return 'SERVER_ERROR';
    var t = (document.body && document.body.innerText) || '';
    if(t.indexOf('ERR_CONNECTION_CLOSED')>-1 || t.indexOf('ERR_CONNECTION_RESET')>-1 ||
       t.indexOf('ERR_PROXY_CONNECTION_FAILED')>-1 || t.indexOf('ERR_TIMED_OUT')>-1 ||
       t.indexOf('无法访问此页面')>-1 || t.indexOf('无法显示此页')>-1 ||
       t.indexOf('找不到该页')>-1) return 'SERVER_ERROR';
  } catch(e){}
  return 'OK';
})()
'@
        $errCheck = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $chromeErrJs } -Session $session -TimeoutSec 10
        $errSig = Get-ResultSignal $errCheck
        if ($errSig -eq "SERVER_ERROR") {
            Write-Host "  [WebBridge] $SiteName : chrome-error detected (connection closed) -> SERVER_ERROR"
            Save-DebugSnapshot $SiteName $session "server_error" $DebugDir $SaveDebugSnapshot
            return "SERVER_ERROR"
        }

        Write-Host "  [WebBridge] $SiteName : evaluate detect"
        $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
        if (-not $detect) {
            # evaluate 失败常见于 tab 丢失（webbridge daemon bug: navigate 返回 success 但 tab 在等待期间消失）
            # 修复：清理所有残留 tab 后重新 navigate + evaluate 一次
            Write-Host "  [WebBridge] $SiteName : evaluate failed (tab may be lost), retrying navigate..."
            $navRetry = Open-SiteTab -Url $Url -Session $session -NavTimeoutSec $NavTimeoutSec -ForceLayoutViewport $ForceLayoutViewport
            if ($navRetry -and $navRetry.success) {
                Wait-PostNavigate -Session $session -SiteName $SiteName -WaitMs $WaitMs -LoadWaitSec $LoadWaitSec -ReadyEval $ReadyEval
                $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
            }
        }
        if (-not $detect) {
            Save-DebugSnapshot $SiteName $session "detect_fail" $DebugDir $SaveDebugSnapshot
            return "EVAL_FAIL"
        }

        $signal = Get-ResultSignal $detect
        Write-Host "  [WebBridge] $SiteName : signal=$signal"

        # 状态转换验证：区分"访问即签到"与"今天已签到"
        # - 无 ClickEval（如 BTSchool）：访问即签到，SIGN_OK 为真实本次成功
        # - 有 ClickEval（需点击的站点）：首次 SIGN_OK 表示今天已签到，非本次签到成功 → ALREADY_SIGNED
        if ($signal -match "SIGN_OK|ALREADY_SIGNED") {
            $firstSignal = if ($ClickEval) { "ALREADY_SIGNED" } else { "SIGN_OK" }
            Save-DebugSnapshot $SiteName $session "sign_ok" $DebugDir $SaveDebugSnapshot
            return $firstSignal
        }
        if ($signal -match "LOGIN_REQUIRED") {
            Save-DebugSnapshot $SiteName $session $signal $DebugDir $SaveDebugSnapshot
            return $signal
        }
        # v4.12.18: SLIDER 不再在此提前 return —— 否则下方 Invoke-SlideBypass 滑块绕过
        # 逻辑（第 338 行起）成为死代码。SLIDER 必须落到该绕过块才能真正尝试绕过。

        # v4.12.7: SERVER_ERROR（HTTP 500/502 等）多为瞬时服务端错误，重新导航 1 次再判定，避免偶发失败
        if ($signal -match "SERVER_ERROR") {
            Write-Host "  [WebBridge] $SiteName : SERVER_ERROR, re-navigating once to confirm..."
            $navSe = Open-SiteTab -Url $Url -Session $session -NavTimeoutSec $NavTimeoutSec -ForceLayoutViewport $ForceLayoutViewport
            if ($navSe -and $navSe.success) {
                Wait-PostNavigate -Session $session -SiteName $SiteName -WaitMs $WaitMs -LoadWaitSec $LoadWaitSec -ReadyEval $ReadyEval
                $seDetect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                $seSig = Get-ResultSignal $seDetect
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
                    $retrySig = Get-ResultSignal $retryDetect
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
                # v4.12.17: 每次重试先重跑完整 Detect —— 修复 xloli 类误判：
                # BODY_NULL/CF_CHALLENGE 实为页面渲染滞后或 CF 后台已通过，真实已签到
                # （"得到魔力加成"等短语）被卡在 CF 重试而漏判成功。
                $reDetect0 = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                $reSig0 = Get-ResultSignal $reDetect0
                if ($reSig0 -and $reSig0 -notmatch "CF_CHALLENGE|BODY_NULL|REDIRECTING") {
                    Write-Host "  [WebBridge] $SiteName : retry detect signal=$reSig0"
                    if ($reSig0 -match "SIGN_OK|ALREADY_SIGNED") {
                        $cfPassSignal = if ($ClickEval) { "ALREADY_SIGNED" } else { "SIGN_OK" }
                        Save-DebugSnapshot $SiteName $session "sign_ok_after_cf" $DebugDir $SaveDebugSnapshot
                        return $cfPassSignal
                    }
                    if ($reSig0 -match "NEED_SIGN|UNKNOWN") { $signal = $reSig0; break }
                    if ($reSig0 -match "LOGIN_REQUIRED") { Save-DebugSnapshot $SiteName $session "login_required" $DebugDir $SaveDebugSnapshot; return "LOGIN_REQUIRED" }
                }
                # 仍判定 CF/BODY_NULL → 走原有 CF 点击流程
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
                    $reSig = Get-ResultSignal $reDetect
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
                    $reSig = Get-ResultSignal $reDetect
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
            # v4.13.0: 统一用 Get-ResultSignal 提取信号，消除散落的 $clicked.value 分支样板
            $clickedSig = Get-ResultSignal $clicked
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
            $recheckSig = Get-ResultSignal $recheck
            # 点击后页面导航导致 tab 重建（如表单提交），复检引用失效 → 重新导航+重检测确认实际状态
            # 修复 xloli 等站点：点击返回 CLICKED 但复检报 "tab was closed"，信号变空（实则可能已签）
            if (-not $recheck -or [string]::IsNullOrEmpty($recheckSig)) {
                Write-Host "  [WebBridge] $SiteName : re-check tab lost (navigated), re-navigating to confirm..."
                $navRe = Open-SiteTab -Url $Url -Session $session -NavTimeoutSec $NavTimeoutSec -ForceLayoutViewport $ForceLayoutViewport
                if ($navRe -and $navRe.success) {
                    Wait-PostNavigate -Session $session -SiteName $SiteName -WaitMs $WaitMs -LoadWaitSec $LoadWaitSec -ReadyEval $ReadyEval
                    $recheck = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                    $recheckSig = Get-ResultSignal $recheck
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
        # v4.12.24: 结构性清场 —— 整会话 daemon 级强关，彻底杜绝 tab 残留给下一站点。
        #   不依赖 list_tabs / close_tab（二者在折叠后台 window + extension 抖动下不可靠，正是漏 tab 根因）。
        #   下一站点 Open-SiteTab 会 Close-WebBridgeSession + navigate 重建，不影响后续签到。
        try { $null = Close-WebBridgeSession -Session $session } catch {}
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

    # v4.13.6: 懒启用布局视口——默认自然分辨率下，折叠后台窗口 layout viewport 为 0x0，
    #   坐标点击必失效。在 scroll/rect 计算【之前】启用 1280x800，保证 getBoundingClientRect
    #   与 Input.dispatchMouseEvent 坐标系一致。ForceLayoutViewport 站点重复启用无害（幂等）。
    $null = Enable-LayoutViewport -Session $Session

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
        $raw = Get-ResultSignal (Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $js } -Session $Session -TimeoutSec 10)
        if ($raw) { return ($raw | ConvertFrom-Json -ErrorAction SilentlyContinue) }
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

# v4.13.5: 动态等待页面就绪（替代固定 WaitMs）。
# 用于需过网站盾/WAF 的站点：盾求解前 body 多为空或含盾关键词，固定延迟太短会误判 UNKNOWN/SERVER_ERROR；
#   本函数轮询直到"真实内容就绪"（body 文本足够长且不含盾关键词）或超时，就绪即继续（不空等满延迟）。
# ReadyEval 为空用默认就绪判定；提供则用其返回值（期望 JSON {ready:true} 或布尔 true/1）。
function Wait-PageReady {
    param(
        [string]$Session,
        [int]$MaxWaitSec = 60,
        [int]$PollMs = 2000,
        [int]$MinBodyLen = 50,
        [string]$ReadyEval = ""
    )
    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    while ((Get-Date) -lt $deadline) {
        $ready = $false
        try {
            if ($ReadyEval) {
                $response = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $ReadyEval } -Session $Session -TimeoutSec 10
                $sig = Get-ResultSignal $response
                if ($sig -eq 'true' -or $sig -eq '1') { $ready = $true }
                else { try { $o = $sig | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($o -and ($o.ready -eq $true -or $o.ready -eq 1)) { $ready = $true } } catch {} }
            } else {
                $js = @"
(function(){
  var b = document.body; if(!b) return 0;
  var t = (b.innerText||'').trim();
  if (t.length < $MinBodyLen) return 0;
  var shield = ['正在检查','安全验证','雷池','Checking your browser','Just a moment','DDoS','Attention Required','verify you are human','确认您是真人'];
  for (var i=0;i<shield.length;i++){ if(t.indexOf(shield[i])>-1) return 0; }
  return 1;
})()
"@
                $response = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $js } -Session $Session -TimeoutSec 10
                $sig = Get-ResultSignal $response
                if ($sig -eq '1') { $ready = $true }
            }
        } catch {}
        if ($ready) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

# v4.13.5: 导航后等待统一入口——开了 LoadWaitSec 的站点走动态轮询，否则沿用固定 WaitMs（行为不变）。
function Wait-PostNavigate {
    param(
        [string]$Session,
        [string]$SiteName,
        [int]$WaitMs,
        [int]$LoadWaitSec = 0,
        [string]$ReadyEval = ""
    )
    if ($LoadWaitSec -and $LoadWaitSec -gt 0) {
        Write-Host "  [WebBridge] $SiteName : dynamic wait for page ready (max ${LoadWaitSec}s)..."
        $ready = Wait-PageReady -Session $Session -MaxWaitSec $LoadWaitSec -PollMs 2000 -MinBodyLen 50 -ReadyEval $ReadyEval
        Write-Host "  [WebBridge] $SiteName : page ready=$ready (proceeding)"
    } else {
        Write-Host "  [WebBridge] $SiteName : waiting ${WaitMs}ms for page load"
        Start-Sleep -Milliseconds $WaitMs
    }
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
        $raw = Get-ResultSignal (Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $js } -Session $Session -TimeoutSec 10)
        if ($raw) {
            $o = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($o) { return $o.verified }
        }
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
        $raw = Get-ResultSignal (Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $checkJS } -Session $Session -TimeoutSec 10)
        if ($raw) { return $raw }
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
        $response = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $js } -Session $Session -TimeoutSec 20
        $s = Get-ResultSignal $response
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
        $snapJson = Get-ResultSignal $snapData
        if ([string]::IsNullOrEmpty($snapJson)) { $snapJson = "{}" }

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
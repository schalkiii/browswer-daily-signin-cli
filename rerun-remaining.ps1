# rerun-remaining.ps1 — 续跑型失败站点取证脚本（临时调试用）
# 设计：逐站即时落盘到 rerun-cumulative.json；已记录的站点跳过（可续跑，不重复）；
# 前台运行，进程被回收也不丢已完成结果。
param(
    [string[]]$Sites,
    [switch]$NoFocus,
    [switch]$SaveDebugSnapshot,
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$scriptDir = $PSScriptRoot
. "$scriptDir\signin-web.ps1"

# v4.12.19: 块开始前强关上一轮残留 tab。
# 上一轮若被硬杀（10min 上限 SIGKILL），per-site finally 未执行会残留大量 tab；
# 这里整会话强关，保证每块从干净状态开始。
try {
    $null = Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session "daily-signin" -TimeoutSec 8
    Write-Output "[cleanup] 已关闭上一轮残留 tab"
} catch {}

$cumFile = Join-Path $scriptDir "rerun-cumulative.json"
$debugDir = Join-Path $scriptDir "debug-snapshots"

# 读取已有累计结果
$cum = @()
if (Test-Path $cumFile) {
    try { $cum = Get-Content $cumFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cum = @() }
    if ($cum -and $cum.GetType().Name -ne "Object[]") { $cum = @($cum) }
}

function Save-Cum {
    param($Data)
    $Data | ConvertTo-Json -Depth 3 | Set-Content -Path $cumFile -Encoding UTF8
}

$targets = $Sites
if (-not $targets -or $targets.Count -eq 0) {
    # v4.12.20: 默认跑 sites.json 中全部「非 manual 且尚未完成」的站点。
    # 不再硬编码调试子集，也不再需要外部手动分区 —— 脚本自己算出剩余站点，
    # 配合增量落盘，反复执行同一条命令即可持续推进直到全部完成。
    try {
        $siteRaw = Get-Content (Join-Path $scriptDir "sites.json") -Raw -Encoding UTF8
        $siteRaw = $siteRaw -replace '^\uFEFF',''
        $siteObj = $siteRaw | ConvertFrom-Json
        $targets = @()
        foreach ($s in $siteObj.sites) {
            # 仅排除 manual 策略站点；已签到的由下方主循环按 $done 自动跳过
            if ($s.strategy -eq "manual") { continue }
            $targets += $s.name
        }
    } catch {
        Write-Output "[warn] 无法读取 sites.json，回退到空列表"
        $targets = @()
    }
}

$done = @{}
foreach ($e in $cum) { $done[$e.name] = $true }

foreach ($site in $targets) {
    if (-not $Force -and $done.ContainsKey($site)) {
        Write-Output "=== [$site] SKIP (already: $($cum.Where({$_.name -eq $site})[0].signal)) ==="
        continue
    }
    Write-Output "=== [$site] start $(Get-Date -Format 'HH:mm:ss') ==="
    $signResult = $null
    try {
        $signResult = Invoke-WebSignIn -SiteName $site -SaveDebugSnapshot:$SaveDebugSnapshot -DebugDir $debugDir -NoFocus:$true
    } catch {
        $signResult = "EXCEPTION:$($_.Exception.Message)"
    }
    Write-Output "=== [$site] result=$signResult ==="
    # 更新或追加
    $existing = $cum | Where-Object { $_.name -eq $site } | Select-Object -First 1
    if ($existing) {
        $existing.signal = $signResult
        $existing.time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } else {
        $cum += [PSCustomObject]@{
            name = $site
            signal = $r
            time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
    }
    Save-Cum $cum
}

Write-Output ""
# v4.12.19: 块结束后整会话强关所有 tab，确保不残留给浏览器/下一轮
try {
    $null = Invoke-WebBridgeCommand -Action "close_session" -CmdArgs @{} -Session "daily-signin" -TimeoutSec 8
    Write-Output "[cleanup] 本轮结束，已关闭所有 tab"
} catch {}
Write-Output ""
Write-Output "=== CUMULATIVE SUMMARY ==="
foreach ($e in $cum) { Write-Output "$($e.name): $($e.signal)  ($($e.time))" }
Write-Output "Wrote: $cumFile"

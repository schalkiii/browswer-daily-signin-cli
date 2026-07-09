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
    $targets = @("xloli","Yemapt","ptlao","audiences","invites","Moment","PigGo","DepthStudio")
}

$done = @{}
foreach ($e in $cum) { $done[$e.name] = $true }

foreach ($site in $targets) {
    if (-not $Force -and $done.ContainsKey($site)) {
        Write-Output "=== [$site] SKIP (already: $($cum.Where({$_.name -eq $site})[0].signal)) ==="
        continue
    }
    Write-Output "=== [$site] start $(Get-Date -Format 'HH:mm:ss') ==="
    $r = $null
    try {
        $r = Invoke-WebSignIn -SiteName $site -SaveDebugSnapshot:$SaveDebugSnapshot -DebugDir $debugDir -NoFocus:$NoFocus
    } catch {
        $r = "EXCEPTION:$($_.Exception.Message)"
    }
    Write-Output "=== [$site] result=$r ==="
    # 更新或追加
    $existing = $cum | Where-Object { $_.name -eq $site } | Select-Object -First 1
    if ($existing) {
        $existing.signal = $r
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
Write-Output "=== CUMULATIVE SUMMARY ==="
foreach ($e in $cum) { Write-Output "$($e.name): $($e.signal)  ($($e.time))" }
Write-Output "Wrote: $cumFile"

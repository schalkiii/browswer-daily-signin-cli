param(
    [Parameter(Mandatory=$true)]
    [string]$SiteName,
    [string]$ConfigFile = "",
    [switch]$SaveDebugSnapshot
)

$ErrorActionPreference = "Continue"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = Join-Path $scriptDir "sites.json"
}
if (-not (Test-Path $ConfigFile)) { Write-Output "[ERROR] Config not found: $ConfigFile"; exit 1 }
$config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$site = $config.sites | Where-Object { $_.name -eq $SiteName } | Select-Object -First 1

if (-not $site) { Write-Output "[ERROR] Site not found: $SiteName"; exit 1 }

Write-Output "=== Single Site Test (webbridge) ==="
Write-Output "Site: $($site.name)"
Write-Output "URL: $($site.url)"
Write-Output "Strategy: $($site.strategy)"
Write-Output ""

# v4.10: 统一走 kimi webbridge 后端
. "$scriptDir\signin-web.ps1"

if ($site.strategy -eq "manual") {
    Write-Output "Manual site, skip."
    if ($site.reason) { Write-Output "Reason: $($site.reason)" }
    exit 0
}

if (-not (Ensure-WebBridgeDaemon)) {
    Write-Output "[ERROR] webbridge daemon not available"
    exit 1
}

$debugDir = Join-Path $scriptDir "debug-snapshots"
$result = Invoke-WebSignIn -SiteName $SiteName -SaveDebugSnapshot:$SaveDebugSnapshot -DebugDir $debugDir

Write-Output ""
Write-Output "=== Result ==="
Write-Output "Signal: $result"

# 诊断：读取最近的 debug snapshot（如果存在）
if ($SaveDebugSnapshot -and (Test-Path $debugDir)) {
    $latestSnap = Get-ChildItem $debugDir -Filter "$SiteName-*.html" -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestSnap) {
        Write-Output ""
        Write-Output "--- Debug Snapshot ---"
        Write-Output "File: $($latestSnap.FullName) ($([math]::Round($latestSnap.Length/1024,1))KB)"
    }
}

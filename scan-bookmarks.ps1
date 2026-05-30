$ErrorActionPreference = "Stop"
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 尝试从 config.json 读取路径
$cfg = $null
$cfgPath = Join-Path $scriptDir "config.json"
if (Test-Path $cfgPath) {
    try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}

$bookmarkFile = if ($cfg -and $cfg.browser) {
    Join-Path $cfg.browser.userDataPath (Join-Path $cfg.browser.profilePath "Bookmarks")
} else {
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks"
}
$bookmarkPattern = if ($cfg -and $cfg.browser -and $cfg.browser.bookmarkFolder) {
    [regex]::Escape($cfg.browser.bookmarkFolder)
} else {
    '签到|Sign|signin|checkin'
}

if (-not (Test-Path $bookmarkFile)) {
    Write-Error "Bookmarks not found: $bookmarkFile"
    Write-Output "请在 config.json → browser 中配置正确的 userDataPath 和 profilePath"
    exit 1
}

Write-Output "Bookmarks: $bookmarkFile"
Write-Output "Pattern: $bookmarkPattern"
Write-Output ""

$b = Get-Content $bookmarkFile -Raw -Encoding UTF8 | ConvertFrom-Json

function Walk-All($node, $path) {
    if ($node.type -eq 'folder') {
        $curPath = $path + '/' + $node.name
        if ($node.name -match $bookmarkPattern) {
            Write-Host ('FOLDER: ' + $curPath)
            foreach ($c in $node.children) {
                if ($c.type -eq 'url') {
                    Write-Host ('  - ' + $c.url)
                }
            }
        }
        foreach ($c in $node.children) { Walk-All $c $curPath }
    }
}

Walk-All $b.roots.bookmark_bar '/bookmark_bar'

Write-Output ""
Write-Output "=== 总计 ==="
$allUrls = @()
function Collect-Urls($node) {
    if ($node.type -eq 'folder') {
        if ($node.name -match $bookmarkPattern) {
            foreach ($c in $node.children) {
                if ($c.type -eq 'url') { $allUrls += $c.url }
            }
        }
        foreach ($c in $node.children) { Collect-Urls $c }
    }
}
Collect-Urls $b.roots.bookmark_bar
Write-Output "匹配到 $($allUrls.Count) 个书签 URL"
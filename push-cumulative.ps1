# push-cumulative.ps1 — 从 rerun-cumulative.json 读取续跑结果并推送飞书卡片
# 设计：签到引擎(rerun-remaining.ps1 / signin-web.ps1)不含推送逻辑，
#   续跑流程分块前台跑完后，用本脚本一次性把累计结果推到飞书。
#   解耦自 signin-batch.ps1 的 Send-FeishuSummary（避免整批重跑 + 末尾才落盘的崩溃风险）。
param(
    [string]$CumFile = "",
    [string]$Webhook = "",
    [string]$ConfigFile = "",
    [string]$SitesFile = "",
    [switch]$DryRun
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrEmpty($CumFile))    { $CumFile    = Join-Path $scriptDir "rerun-cumulative.json" }
if ([string]::IsNullOrEmpty($ConfigFile)) { $ConfigFile = Join-Path $scriptDir "config.json" }
if ([string]::IsNullOrEmpty($SitesFile))  { $SitesFile  = Join-Path $scriptDir "sites.json" }

# ===== 加载配置（飞书 webhook） =====
if (-not (Test-Path $ConfigFile)) { Write-Error "config.json 不存在: $ConfigFile"; exit 1 }
$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$feishuWebhook = $Webhook
if ([string]::IsNullOrEmpty($feishuWebhook) -and $cfg.feishu) { $feishuWebhook = $cfg.feishu.webhook }
$feishuEnabled = $true
if ($cfg.feishu -and $null -ne $cfg.feishu.enabled) { $feishuEnabled = [bool]$cfg.feishu.enabled }
if (-not $feishuEnabled) { Write-Output "feishu.enabled=false，跳过推送"; exit 0 }
if ([string]::IsNullOrEmpty($feishuWebhook)) { Write-Output "未配置 feishu.webhook，跳过推送"; exit 0 }

# ===== 加载累计结果 =====
if (-not (Test-Path $CumFile)) { Write-Error "累计结果文件不存在: $CumFile"; exit 1 }
$cum = Get-Content $CumFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $cum -or $cum.Count -eq 0) { Write-Output "累计结果为空，无内容可推"; exit 0 }

# ===== 加载站点展示名映射 =====
$siteInfoMap = @{}
if (Test-Path $SitesFile) {
    $sitesDoc = Get-Content $SitesFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($sitesDoc.sites) {
        foreach ($s in $sitesDoc.sites) {
            $dn = if ($s.display_name) { $s.display_name } else { $s.name }
            $siteInfoMap[$s.name] = @{ url = $s.url; display_name = $dn }
        }
    }
}
function Get-Dn([string]$n) {
    $info = $siteInfoMap[$n]
    if ($info -and $info.display_name) { return $info.display_name }
    return $n
}
function Format-SiteLink([string]$n) {
    $info = $siteInfoMap[$n]
    if ($info -and $info.url) {
        $dn = if ($info.display_name) { $info.display_name } else { $n }
        return "[$dn]($($info.url))"
    }
    return $n
}

# ===== Emoji（用 codepoint 避免文件编码问题） =====
$e_ok    = [char]0x2705
$e_warn  = "$([char]0x26A0)$([char]0xFE0F)"
$e_green = "$([System.Char]::ConvertFromUtf32(0x1F7E2))"
$e_red   = "$([System.Char]::ConvertFromUtf32(0x1F534))"
$e_cf    = "$([System.Char]::ConvertFromUtf32(0x1F6AB))"
$e_q     = [char]0x2753
$e_cross = [char]0x274C
$e_date  = "$([System.Char]::ConvertFromUtf32(0x1F4C5))"
$e_stats = "$([System.Char]::ConvertFromUtf32(0x1F4CA))"

# ===== 分类 =====
$successSignals = @("SIGN_OK", "ALREADY_SIGNED", "VISITED")
$success = @(); $failures = @()
foreach ($r in $cum) {
    if ($successSignals -contains $r.signal) { $success += $r }
    else { $failures += $r }
}
$total = $cum.Count
$successCount = $success.Count
$failCount = $failures.Count

# 失败原因归类
$reasonMap = @{
    "CF_CHALLENGE" = @{ label = "CF/WAF 拦截"; icon = $e_cf }
    "NEED_SIGN"    = @{ label = "需验证码/人工"; icon = $e_q }
    "BODY_NULL"    = @{ label = "页面空/OAuth"; icon = $e_q }
    "SERVER_ERROR" = @{ label = "源站错误"; icon = $e_cross }
}
$grouped = @{}
foreach ($r in $failures) {
    $rm = $reasonMap[$r.signal]
    $label = if ($rm) { $rm.label } else { $r.signal }
    if (-not $grouped.ContainsKey($label)) { $grouped[$label] = @() }
    $grouped[$label] += $r.name
}

# 运行日期（取最新一条的时间）
$runDate = (($cum | Sort-Object { $_.time } | Select-Object -Last 1).time -split ' ')[0]

# ===== 拼装 markdown =====
$statsMd = "$e_stats **每日签到报告 $runDate**`n总计: $total | $e_green 成功: $successCount | $e_red 失败: $failCount"

$okJoined = (($success | Sort-Object { $_.name } | ForEach-Object { Get-Dn $_.name }) -join ", ")
$successMd = "$e_green **签到成功 ($successCount)**`n$okJoined"

$failMd = "$e_red **签到失败 ($failCount)**`n"
foreach ($label in ($grouped.Keys | Sort-Object)) {
    $names = ($grouped[$label] | Sort-Object | ForEach-Object { Get-Dn $_ }) -join ", "
    $failMd += "- $($reasonMap.Values | Where-Object { $_.label -eq $label } | Select-Object -First 1 | ForEach-Object { $_.icon })$label ($($grouped[$label].Count)): $names`n"
}

$footerMd = "$e_date 数据来源 rerun-cumulative.json · 续跑流程推送"

# ===== 构建卡片 =====
$passIcon = if ($failCount -eq 0) { $e_ok } else { $e_warn }
$cardElements = @(
    @{ tag = "div"; text = @{ tag = "lark_md"; content = $statsMd } }
)
if ($successCount -gt 0) {
    $cardElements += @{ tag = "div"; text = @{ tag = "lark_md"; content = $successMd } }
}
if ($failCount -gt 0) {
    $cardElements += @{ tag = "div"; text = @{ tag = "lark_md"; content = $failMd } }
}
$cardElements += @{ tag = "hr" }
$cardElements += @{ tag = "div"; text = @{ tag = "lark_md"; content = $footerMd } }

$cardJson = @{
    msg_type = "interactive"
    card = @{
        config = @{ wide_screen_mode = $true }
        header = @{
            title = @{ tag = "plain_text"; content = "$passIcon PT 签到报告" }
            template = if ($failCount -eq 0) { "green" } else { "red" }
        }
        elements = $cardElements
    }
} | ConvertTo-Json -Depth 6 -Compress

if ($DryRun) {
    Write-Output "=== DRY RUN: card JSON ==="
    Write-Output $cardJson
    exit 0
}

# ===== 推送（UTF-8 无 BOM 临时文件，规避 GBK 编码导致中文变 ?） =====
$tmpFile = Join-Path $env:TEMP "ptsign_feishu_$([System.Guid]::NewGuid().ToString('N')).json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
    [System.IO.File]::WriteAllText($tmpFile, $cardJson, $utf8NoBom)
    $result = Invoke-RestMethod -Uri $feishuWebhook -Method Post -ContentType "application/json; charset=utf-8" -InFile $tmpFile -TimeoutSec 10
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    if (($result.StatusCode -eq 0) -or ($result.code -eq 0)) {
        Write-Output "Feishu webhook (card): OK"
    } else {
        Write-Output "Feishu webhook (card): FAIL - $($result | ConvertTo-Json -Compress)"
    }
} catch {
    Write-Output "Feishu webhook (card): ERROR - $($_.Exception.Message)"
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
}

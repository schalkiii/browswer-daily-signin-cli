<#
.SYNOPSIS
  注册/更新 Windows 计划任务：每日 02:00 用 PowerShell 7 运行 signin-batch.ps1。

.DESCRIPTION
  用 ScheduledTask cmdlet 创建任务 DailySigninBatch：
    - 触发器：每日 02:00
    - 操作：本机 pwsh.exe（PowerShell 7） -File signin-batch.ps1
    - 运行身份：当前交互登录用户（InteractiveToken）——脚本需开浏览器，必须用户已登录
    - 设置：错过开机也补跑（StartWhenAvailable）、插电/电池都运行
  任务已存在时 -Force 覆盖更新。

.NOTES
  ⚠️ pwsh 路径依赖本机已安装的 PowerShell 7/Preview 位置。若升级 pwsh 后路径变化，
     重新运行本脚本即可（会自动解析当前 pwsh 路径）。
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'DailySigninBatch',
    [string]$RunTime = '02:00',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# 解析当前 pwsh 完整路径（兼容 Store 安装路径带版本号的情况）
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
if (-not (Test-Path $pwsh)) { throw "找不到 pwsh.exe：请先安装 PowerShell 7" }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$batchScript = Join-Path $scriptDir 'signin-batch.ps1'
if (-not (Test-Path $batchScript)) { throw "找不到 signin-batch.ps1：$batchScript" }

$currentUser = "$env:USERDOMAIN\$env:USERNAME"

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[setup-daily-task] 已删除任务 '$TaskName'" -ForegroundColor Yellow
    return
}

# 校验 pwsh 确为 v7+
$pwshVer = & $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.Major'
if ([int]$pwshVer -lt 7) { throw "pwsh 版本过低（v$pwshVer），需要 PowerShell 7+" }

$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$batchScript`""
$trigger = New-ScheduledTaskTrigger -Daily -At $RunTime
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Select-Object TaskName, State

Write-Host "[setup-daily-task] 已注册：" -ForegroundColor Green
Write-Host "  任务名 : $TaskName" -ForegroundColor Cyan
Write-Host "  触发   : 每日 $RunTime" -ForegroundColor Cyan
Write-Host "  运行者 : $currentUser (需登录)" -ForegroundColor Cyan
Write-Host "  pwsh   : $pwsh" -ForegroundColor Cyan
Write-Host "  脚本   : $batchScript" -ForegroundColor Cyan

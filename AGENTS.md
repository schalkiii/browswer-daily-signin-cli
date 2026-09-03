# AGENTS.md

PT 每日签到 CLI — 通过本地 kimi WebBridge daemon 操控已登录浏览器扩展，完成多站点每日签到。

## 一句话定位
浏览器每日签到自动化（Edge/Chrome 扩展 + 本地 daemon）：覆盖 NexusPHP attendance、CF Turnstile、ALTCHA、SPA 控制台、人工站点。

## 怎么跑起来
- 前置：本地已启动 kimi WebBridge daemon（默认 `http://127.0.0.1:10086/command`）；浏览器已登录各 PT 站。
- 日常全量：`pwsh -File .\signin-batch.ps1`（后台不弹窗，结束推飞书）。
- 单站调试：`pwsh -File .\signin-single.ps1 -SiteName <名>`。
- 每日定时：`pwsh -File .\setup-daily-task.ps1` 注册 02:00 计划任务（需当前用户已登录）。

## 技术栈与目录
- PowerShell 7（`pwsh`，**禁止** `powershell` 5.1）。核心：`kimi-webbridge.ps1`（导航/关 tab/CF·ALTCHA·SLIDER/重试自愈）、`signin-web.ps1`（各站点 `$WebSignInConfigs` 检测与点击 JS）、`signin-batch.ps1`（编排/飞书/基线）。
- 站点列表与策略：`sites.json`（`webbridge` / `visit-only` / `manual` / `web-read` 向后兼容）。
- 配置：`config.example.json` → 复制为 `config.json`（含私密 webhook，已被 `.gitignore` 排除）。

## 约定与边界（下次 Agent 不看到会犯错的点）
- 核心不变量：所有站点共用 daemon 会话 `daily-signin`，任意时刻 ≤ 1 个 tab（`Close-SiteTabs-Verified` 强关）。
- 导航统一 `navigate + waitUntil=domcontentloaded`，单次直达，不在扩展 30s `load` 超时上赌命。
- 检测/点击全在浏览器内 JS（UTF-8 原生处理中文），返回 ASCII 信号给 PowerShell。
- 后台默认 `-NoFocus`；CF Turnstile 与「弹窗需聚焦才渲染」的站点（如 pting 日历弹窗）声明 `BringToFront=$true` 瞬时借焦点。
- 失败站点只进 `needs_manual_review`，**禁止**自动改 `manual`。
- 运行时产物（`config.json` / `signin-log.json` / `debug-snapshots/` 等）已被 `.gitignore` 排除，勿提交。

## 权威文档（详细机制看这些，本文件只作入口）
- `pt-signin-skill-cn.md` / `pt-signin-skill.md`：设计概览、策略矩阵、执行链路、各验证机制方法论。
- `README.md`：入口脚本用法、策略矩阵、定时任务。
- `CHANGELOG.md`：版本叙事。

## 当前状态与下一步
- 已知成功站点基线见 `baseline.json`（回归参考，失败即真 bug）。
- 新站接入：`scan-bookmarks.ps1` 生成 `sites.json` 条目 → 在 `signin-web.ps1` 补 `$WebSignInConfigs` → `signin-single.ps1` 现场核验。

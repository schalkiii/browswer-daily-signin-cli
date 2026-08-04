# PT 每日签到 CLI

通过本地 **kimi WebBridge** daemon 操控真实浏览器（Edge/Chrome 扩展）完成多站点签到。
所有导航/关 tab 逻辑集中在 `kimi-webbridge.ps1`，站点配置在 `signin-web.ps1` 的 `$WebSignInConfigs`，
站点列表与策略在 `sites.json`。

## 入口脚本（何时用哪个）

| 脚本 | 用途 | 前台/后台 | 备注 |
|------|------|-----------|------|
| `signin-batch.ps1` | **日常全量签到** | 后台（不弹前台） | 逐站增量写 `signin-log.json`；失败站点重试 2 次；结束推飞书 |
| `signin-single.ps1 -SiteName <名>` | **单站调试** | 后台 | 改了某站 Detect/Click 后单独验证用 |
| `rerun-remaining.ps1 [-Force]` | **失败续跑** | 后台 | 默认跑 `sites.json` 中「非 manual 且尚未完成」的站；增量写 `rerun-cumulative.json`；`-Force` 重跑全部；后台被回收也不丢已完成结果 |
| `push-cumulative.ps1 [-DryRun]` | **续跑补推飞书** | — | 读 `rerun-cumulative.json` 按成功/失败拼卡片推送；`-DryRun` 仅打印 |

日常流程：先 `signin-batch.ps1`（或分块 `rerun-remaining.ps1`），全部跑完后若走了续跑路径，再 `push-cumulative.ps1` 补推一次。

## sites.json 策略矩阵（strategy）

| strategy | 行为 | 结果信号 | 是否签到 |
|----------|------|----------|----------|
| `webbridge` | 打开网页 → 检测签到状态 → 必要时点击/绕过验证 | `SIGN_OK` / `ALREADY_SIGNED` / `NEED_SIGN` / `CF_CHALLENGE` / `SLIDER` / … | ✅ 自动 |
| `visit-only` | 仅打开网页，**不检测不点击**（如 AsianDVDClub / Kufirc / asiandvd） | `VISITED` | ❌ 仅访问 |
| `manual` | 跳过，由用户人工处理（如 TJUPT / 42w / zxiaoruan） | `SKIPPED`（记入 `skip_sites`，飞书给可点击链接） | ❌ 人工 |

> 改某站为「仅打开不签到」：把 `strategy` 改成 `visit-only` 即可（无需改 `$WebSignInConfigs`，visit-only 靠 `DetectEval` 为空自动判定）。
> **禁止自动添加 `manual`**：失败站点只进 `needs_manual_review` 列表通知用户，绝不自动改策略（见 `signin-batch.ps1` 注释）。

## 标签页去重（重要不变量）

`Open-SiteTab` 每次导航前先 **整会话 daemon 级强关 + 关后 `list_tabs` 校验**（`Close-SiteTabs-Verified`），再开唯一一个 tab。由此：

- 任意时刻本会话 **≤ 1 个 tab**，且**即便重试也先关旧 tab 再开新的**。
- **所有站点必须共用同一会话 `"daily-signin"`**——`close_session` 靠清掉「上一站点」的 tab 工作；若各站用独立 session，`close_session` 只清自己 → 上一站 tab 永不关 → 泄漏重现。
- 若 daemon 仍漏关，`Close-SiteTabs-Verified` 会打印 `⚠️ close_session 后仍有 N 个 tab 残留` 告警（不再静默累积）。

## 导航实现：navigate + waitUntil=domcontentloaded，单次直达

`Open-SiteTab` 用一次 `navigate`（`newTab=true` + `waitUntil=domcontentloaded`）直达目标站，随后：

1. 仅当本次 navigate 仍失败才重试最多 **2 次**（兼容服务端慢/瞬时抖动），每次动手前 `Close-SiteTabs-Verified` 清场，保证任意时刻本会话 ≤ 1 tab；
2. 页面就绪完全交给 `Wait-PageReady` 每 2s 轮询 DOM（body 文本足够长且无盾关键词即就绪）。

**为什么 `waitUntil=domcontentloaded`**：扩展内部对每次 navigate 有独立的 **30s `load` 事件超时**，超时回 `extension_error` 且**连 tab 一并销毁**。CF 盾 / 慢子资源 / 长连接 / 折叠后台窗口的 `load` 在 30s 内不触发 → 每轮都 `newTab` + 失败时不清场会累积出大量 tab，且 tab 被销毁后 `evaluate` 刷 `session has no tab`。改用 `domcontentloaded`（只等 DOMContentLoaded，CF 盾站 DOM 通常数秒内就绪）后，慢站不再超时、也不再 `has no tab`。

**`visit-only` 慢站特例**：`visit-only` 站点（无 `DetectEval`）只需「打开页面」即达成目的，但 DOMContentLoaded 可能长时间不触发（tab 一直转圈）。此时 `Open-SiteTab` 的 `-VisitOnly` 开关生效：`navigate` 即便 `domcontentloaded` 超时，只要命令已提交、`list_tabs` 确认 tab 已建立（仍在加载也行）即判成功，**不再进入外层重试**（避免反复清场重开 tab）；同时跳过 `Wait-PostNavigate`（无需等 DOM 就绪）。非 visit-only 站点逻辑不变，仍要求 `domcontentloaded` 成功。

**导航超时上限**：`NavTimeoutSec` 默认 **120s**（2 分钟），是 PS 侧给 daemon 的请求超时，须足够大才能覆盖慢站而不被 PS 自己先砍断。站点可用 `$cfg.NavTimeoutSec` 单独覆盖。

## 后台运行（不弹前台）

所有入口脚本默认 `-NoFocus:$true`，`Invoke-WebSignIn` 的 `NoFocus` 默认也是 `$true`。
daemon 的 `navigate newTab=true` 本身不抬窗口；唯一会抢焦点的是 `Page.bringToFront`（CF Turnstile 需要焦点才渲染 iframe），已由 `-NoFocus` 跳过。
代价：CF Turnstile 站（OurBits / audiences）可能因无焦点不渲染验证 iframe——与「不弹前台」的用户诉求相比优先级更低。

## 调试

- `signin-single.ps1 -SiteName <名> -SaveDebugSnapshot`：把各阶段页面快照存到 `debug-snapshots/<Site>_<stage>_<时间戳>.json（含 body 文本/HTML、CF iframe、关键词片段），用于诊断 `CF_CHALLENGE` / `SLIDER` / `BODY_NULL` 等失败。
- 命令行参数：`signin-batch.ps1 -SaveDebugSnapshot`（全量存快照）、`-FeishuWebhook <url>` / `-FeishuChatId <id>`（覆盖 config.json 的飞书配置）。

## 定时任务（每日自动签到）

`setup-daily-task.ps1` 一键注册 Windows 计划任务 **`DailySigninBatch`**：

| 项目 | 配置 |
|------|------|
| 触发器 | 每日 `02:00` |
| 操作 | 本机 `pwsh.exe`（**PowerShell 7**）`-File signin-batch.ps1` |
| 运行身份 | 当前交互登录用户（`InteractiveToken`）——脚本需开浏览器，必须用户已登录 |
| 设置 | 错过开机也补跑（`StartWhenAvailable`）、插电/电池都运行 |

用法：

```powershell
# 注册 / 更新（任务已存在则覆盖）
pwsh -File .\setup-daily-task.ps1

# 卸载
pwsh -File .\setup-daily-task.ps1 -Uninstall
```

脚本通过 `Get-Command pwsh` **动态解析当前 pwsh 路径**，因此升级 PowerShell 7 后只需重跑一次即可（无需手动改路径）。验证：

```powershell
schtasks /Query /TN "DailySigninBatch"
```

> ⚠️ **必须用户登录**：kimi-webbridge 依赖已登录用户浏览器里的扩展，`InteractiveToken` 任务只在你的账户登录时运行。若需锁屏/未登录也跑，需改用服务账户 + 无头浏览器方案，当前不支持。
> ⚠️ 若任务某天突然不执行，先检查 pwsh 是否被升级导致路径失效——重跑 `setup-daily-task.ps1` 即可恢复。

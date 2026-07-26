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

`Open-SiteTab` 每次导航前先 **整会话 daemon 级强关 + 关后 `list_tabs` 校验 + 重试 + 逐 id 退路**
（`Close-SiteTabs-Verified`，v4.12.25），再开唯一一个 tab。由此：

- 任意时刻本会话 **≤ 1 个 tab**，且**即便重试也先关旧 tab 再开新的**。
- **所有站点必须共用同一会话 `"daily-signin"`**——`close_session` 靠清掉「上一站点」的 tab 工作；若各站用独立 session，`close_session` 只清自己 → 上一站 tab 永不关 → 泄漏重现。
- 若 daemon 仍漏关，`Close-SiteTabs-Verified` 会打印 `⚠️ close_session 后仍有 N 个 tab 残留` 告警（不再静默累积）。

## 导航实现（v4.13.7 根治 30s 超时 + tab 堆积）

⚠️ **禁止直接用 daemon 的 `navigate` 跳真目标。** 实测 daemon `navigate` **完全忽略 `waitUntil`、永远死等 `load` 事件**；多数 PT 站（CF 挑战 / 慢子资源 / 长连接 / 折叠后台窗口）的 `load` 在 30s 内不触发 → 超时且 **daemon 直接销毁 tab** → 重试 `newTab` 无限开 tab（用户 07-26 实跑复现）。`about:blank` 传任意 `waitUntil` 取值全 30s 超时即铁证；baidu 偶成功只是其 `load` 碰巧快。

`Open-SiteTab` 现用两条 daemon 调用绕开该陷阱：

1. `navigate` 到本地 `data:text/html` **seed**（秒回、零网络/代理依赖）先建一个「活」tab；
2. `cdp Page.navigate` 跳到真目标——**非阻塞、不等 `load`、不销毁 tab**；
3. 页面就绪完全交给 `Wait-PageReady` 每 2s 轮询 DOM（body 文本足够长且无盾关键词即就绪）。

WAF 站（如 HDKYL 雷池）会让 daemon 的 `cdp` 包装一直等「导航提交」而卡住，但导航实际已发起、tab 存活；故 `cdp Page.navigate` 用**短超时 12s + 容错**（超时即视为已发起、转交轮询），导航后仅校验 `list_tabs` 确认 tab 仍在。

## 后台运行（不弹前台）

所有入口脚本默认 `-NoFocus:$true`，`Invoke-WebSignIn` 的 `NoFocus` 默认也是 `$true`。
daemon 的 `navigate newTab=true` 本身不抬窗口；唯一会抢焦点的是 `Page.bringToFront`（CF Turnstile 需要焦点才渲染 iframe），已由 `-NoFocus` 跳过。
代价：CF Turnstile 站（OurBits / audiences）可能因无焦点不渲染验证 iframe——与「不弹前台」的用户诉求相比优先级更低。

## 调试

- `signin-single.ps1 -SiteName <名> -SaveDebugSnapshot`：把各阶段页面快照存到 `debug-snapshots/<Site>_<stage>_<时间戳>.json`（含 body 文本/HTML、CF iframe、关键词片段），用于诊断 `CF_CHALLENGE` / `SLIDER` / `BODY_NULL` 等失败。
- 命令行参数：`signin-batch.ps1 -SaveDebugSnapshot`（全量存快照）、`-FeishuWebhook <url>` / `-FeishuChatId <id>`（覆盖 config.json 的飞书配置）。

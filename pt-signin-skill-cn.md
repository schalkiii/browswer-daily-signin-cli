---
name: pt-signin
description: |
  使用 kimi webbridge（单一后端）自动化 PT（私人种子站）及论坛签到。
  涵盖 NexusPHP attendance.php 站点、Cloudflare Turnstile 绕过、点击签到页面、
  SPA 控制台站点和人工站点。当用户要求 PT 站点签到、论坛签到、
  或自动化私人种子站每日签到时使用此技能。
updated: 2026-09-03
---

# PT 站点签到自动化

## 快速开始

```powershell
cd d:\workspace\browswer-daily-signin-cli

# 全量批处理：所有 webbridge 站点 + 人工站点
.\signin-batch.ps1

# 单站点调试
.\signin-single.ps1 -Site <站点名>
```

## 设计概览

系统通过本地 **kimi WebBridge daemon** 操控用户已登录浏览器中的扩展，完成多站点签到。
所有导航、关 tab、CF 绕过、点击、重试逻辑集中在 `kimi-webbridge.ps1`；
各站点特有的检测 JS（`DetectEval`）、点击 JS（`ClickEval`）、等待参数集中在 `signin-web.ps1` 的 `$WebSignInConfigs`；
批处理编排（逐个站点调用、结果汇总、飞书推送、基线跟踪）在 `signin-batch.ps1`。

**核心约束——单一会话单 tab**：所有站点共用一个 daemon 会话 `daily-signin`，任意时刻该会话内至多一个 tab。
这是防 tab 泄漏与防"has no tab"风暴的关键不变量（详见「导航与 tab 生命周期」）。

---

## 站点分类与策略

`sites.json` 中每个站点声明 `strategy`，决定批处理如何对待它：

| `strategy` 值    | 行为                                                         | 返回信号（成功）        | 自动？ |
| ---------------- | ------------------------------------------------------------ | ----------------------- | ------ |
| `webbridge`      | 打开网页 → 检测签到状态 → 必要时点击/绕过验证                | `SIGN_OK` / `ALREADY_SIGNED` | ✅ 自动 |
| `visit-only`     | 仅打开网页，**不检测不点击**（保活类站点，如 Kufirc / AsianDVDClub） | `VISITED`                | ❌ 仅访问 |
| `web-read`       | 已废弃的旧值，等价 `webbridge`；配置中已统一改为 `webbridge`，仅保留向后兼容解析 | `SIGN_OK` / `ALREADY_SIGNED` | ✅ 自动 |
| `manual`         | 不自动处理，跳过并记入飞书「需人工」列表（验证码/政策原因站） | —（SKIPPED）             | ❌ 人工 |

> 将某站改为「仅打开不签到」：把 `strategy` 改成 `visit-only` 即可（无需改 `$WebSignInConfigs`；visit-only 依据 `DetectEval` 为空自动判定）。

**核心规则：尝试书签文件夹中的全部站点，而非仅尝试曾经成功过的。**
以基线（`baseline.json`）为参考，判断哪些站点*理应*成功——基线站点失败 = 真实 bug；不在基线中的站点是探索机会。

### sites.json 字段定义

| 字段           | 必填 | 说明                                                                   |
| -------------- | ---- | ---------------------------------------------------------------------- |
| `name`         | 是   | 站点主键（5 处依赖：WebSignInConfigs / baseline / fail_sites / single / 快照） |
| `url`          | 是   | 签到页面 URL                                                           |
| `strategy`     | 是   | `webbridge` / `visit-only` / `web-read` / `manual`                     |
| `display_name` | 否   | 展示名（飞书推送/日志），缺失时回退到 `name`。Sync-Bookmarks 自动提取  |
| `note`         | 否   | 同步状态/变更说明                                                      |

### $WebSignInConfigs 字段定义（signin-web.ps1）

`$WebSignInConfigs[<name>]` 提供站点级执行参数，供 `Test-WebBridgeSignIn` 消费：

| 字段                | 说明                                                                       |
| ------------------- | -------------------------------------------------------------------------- |
| `Url`               | 签到页 URL（与 sites.json 的 `url` 对应）                                  |
| `Detect`            | 检测签到状态的 JS（`DetectEval`）。为空 ⇒ 该站按 visit-only 处理            |
| `Click`             | 点击签到按钮的 JS（`ClickEval`）。为空 ⇒ 仅检测不点击                       |
| `WaitMs`            | navigate 后首轮固定等待毫秒数                                              |
| `PostClickMs`       | 点击后的固定等待毫秒数                                                     |
| `LoadWaitSec`       | 动态轮询页面就绪的最长秒数（默认 45，见全局参数）                          |
| `ReadyEval`         | 自定义页面就绪判定 JS（替代默认 body 文本长度 + 盾关键词判定）              |
| `ForceLayoutViewport` | 坐标点击站（CF Turnstile / SLIDER）声明 `$true`，启用布局视口。ALTCHA（Yemapt）已改为直接 JS 点击复选框（无 shadow DOM），`ForceLayoutViewport` 仅其 CDP 兜底保留。 |
| `NavTimeoutSec`     | 该站导航超时秒数（默认 120）                                               |
| `BringToFront`     | 部分站点弹窗需标签页聚焦才渲染（如 pting 日历弹窗）。声明 `$true`，框架调用 `Page.bringToFront` 瞬时抢焦点（CF Turnstile 同理）。 |
| `CfRetryCount` / `CfRetryWaitMs` | CF 绕过重试次数 / 间隔                                                  |

---

## 模块划分

| 文件                    | 职责                                                                     |
| ----------------------- | ------------------------------------------------------------------------ |
| `kimi-webbridge.ps1`    | WebBridge API 封装：导航、`list_tabs` 探测助手、tab 清场、CF/ALTCHA/SLIDER 处理、检测与点击执行、重试编排 |
| `signin-web.ps1`       | 站点配置 `$WebSignInConfigs`、共享点击 JS、配置一致性校验、单站执行入口 `Invoke-WebSignIn` |
| `signin-batch.ps1`     | 批处理编排：逐站调用、结果分类、失败重试、飞书推送、基线跟踪、人工审核列表 |
| `signin-single.ps1`    | 单站点调试工具（硬编码 `-NoFocus:$true` 后台执行）                        |
| `scan-bookmarks.ps1`   | 书签扫描 → 生成/更新 `sites.json`                                         |
| `push-cumulative.ps1`  | 累积失败汇总推送                                                         |
| `rerun-remaining.ps1`  | 对累积失败站点重跑                                                       |
| `convert-log.py` / `gen-report.py` | 日志转换与报告生成                                     |

### 核心执行链路

```
signin-batch.ps1（编排）
  └─ Invoke-WebSignIn -SiteName <name>          # signin-web.ps1
       └─ Test-WebBridgeSignIn @params          # kimi-webbridge.ps1
            ├─ Ensure-WebBridgeHealthy          # daemon/扩展 连接自检 + 自愈
            ├─ Open-SiteTab                     # 清场 → navigate(domcontentloaded) → 复用/新建单 tab
            ├─ Wait-PostNavigate                # 动态轮询页面就绪（visit-only 跳过）
            ├─ Detect（evaluate DetectEval）    # 读签到状态信号
            └─ Click（evaluate ClickEval）      # 必要时点击 → 重检
```

---

## 导航与 tab 生命周期（关键不变量）

**单一会话 `daily-signin` + 单 tab** 是整个系统防泄漏的根本约束。

- `Open-SiteTab` 每次导航前先调用 `Close-SiteTabs-Verified`：整会话 daemon 级强关（`close_session`）+ 关后 `list_tabs` 校验，若仍有残留 tab 会打印 `⚠️ close_session 后仍有 N 个 tab 残留` 告警（不再静默累积）。
- 强关优于按 id `close_tab`：`close_tab` 在折叠后台窗口中（`window.active=False`）的 tab 难命中，曾是 tab 累积泄漏根因；daemon 级 `close_session` 即使扩展抖动/断开也生效。
- 进入即清场保证了"即便重试也先关旧 tab 再开新"，任意时刻本会话 ≤ 1 个 tab。
- **所有站点必须共用同一会话名**：若某站改用独立 session，`close_session` 只清自己，上一站 tab 永不关 → 泄漏重现。

### 导航方式

`Open-SiteTab` 用一次 `navigate`（`newTab=true` + `waitUntil=domcontentloaded`）直达目标站，随后进入检测/点击流程。

**为什么 `waitUntil=domcontentloaded`**：扩展内部对每次 navigate 有独立的 **30s `load` 事件超时**，超时回 `extension_error` 且**连 tab 一并销毁**。CF 盾 / 慢子资源 / 长连接 / 折叠后台窗口的 `load` 在 30s 内不触发 → 每轮都 `newTab` + 失败时不清场会累积出大量 tab，且 tab 被销毁后还去 `evaluate` 刷 `session has no tab`。改用 `domcontentloaded`（只等 DOMContentLoaded，CF 盾站 DOM 通常数秒内就绪）后，慢站不再超时、也不再 `has no tab`。

### visit-only 慢站特例

`visit-only` 站点（无 `DetectEval`）只需「打开页面」即达成目的，但 DOMContentLoaded 可能长时间不触发（tab 一直转圈）。此时 `Open-SiteTab` 的 `-VisitOnly` 开关生效：`navigate` 即便 `domcontentloaded` 超时，只要命令已提交、`list_tabs` 确认 tab 已建立（仍在加载也行）即判成功，**不再进入外层重试**（避免反复清场重开 tab）；同时跳过 `Wait-PostNavigate`（无需等 DOM 就绪）。非 visit-only 站点逻辑不变，仍要求 `domcontentloaded` 成功。

### 连接自愈与重试

- **连接自检**：`Test-WebBridgeSignIn` 开工前调用 `Ensure-WebBridgeHealthy`，daemon/扩展断连时自动重启自愈（每次运行至多一次）。
- **extension 冷启动**：首个站点可能 navigate 失败，`list_tabs` 探测到扩展未就绪时，每 5s 重试最多 3 次。
- **导航超时重试**：`domcontentloaded` 失败（服务端慢/瞬时）时，间隔 12s 清场后重导航，最多 2 次；仍失败判 `NAV_FAIL`。
- **批处理失败重试**：`CF_BLOCKED` / `SLIDER_FAIL` / `PAGE_ERROR` / `NO_DETECT` / `TIMEOUT` 五类状态，批处理层再各重试 2 次（间隔 10s）。

---

## 检测策略：浏览器原生 JS 信号

核心思路：JS 在浏览器内运行 → UTF-8 原生处理中文 → 返回 ASCII 信号给 PowerShell，避免 PowerShell 侧字符编码问题。

`$WebSignInConfigs` 中每站的 `Detect` 是一段 IIFE，返回字符串信号：

- `SIGN_OK`：已签到（匹配「签到成功 / 签到已得 / 已签到 / 这是您的第 / 每日登录奖励已领取 / Already checked / 打卡成功 / 获得奖励 …」等）
- `NEED_SIGN`：未签到、需点击
- `ALREADY_SIGNED`：今日已签到（状态页直接显示，非本次点击所致）
- `SIGN_FAIL`：点击后仍未成功
- `CF_CHALLENGE`：页面含 Cloudflare 质询（`cf-turnstile` / `challenges.cloudflare`）
- `SLIDER`：出现滑块验证
- `SERVER_ERROR`：chrome-error 页 / 连接错误（网络/代理/站点侧，非代码缺陷）
- `LOGIN_REQUIRED`：未登录

PowerShell 侧按信号映射到 `SUCCESS` / `ALREADY_DONE` / `NO_DETECT` / `CF_BLOCKED` / `SLIDER_FAIL` / `PAGE_ERROR` / `NO_LOGIN` 等结果状态（`signin-batch.ps1` 的 `switch -Wildcard`）。

---

## 验证绕过机制

### Cloudflare Turnstile

部分 NexusPHP 站（`NexusPHPCfSignInClick` 类）签到前需先过 CF Turnstile：

1. `Wait-PostNavigate` 轮询，检测到 `cf-turnstile` 未过时进入 CF 处理；
2. 通过 `Page.bringToFront` 给 tab 焦点（CF iframe 需焦点才渲染），必要时临时关闭 `-NoFocus`；
3. `Get-CfWidgetViewportRect` 读取 widget 视口坐标，配合 `ForceLayoutViewport` 启用布局视口后点击；
4. 轮询 `Test-CfTurnstilePassed`（`cf-turnstile` 消失且页面就绪）确认通过；
5. 通过后提交 attendance 表单（`ClickEval` 点击签到），最多按 `CfRetryCount` 重试。

### ALTCHA / SLIDER

- **ALTCHA**（如 Yemapt）：`ClickEval` 先解 ALTCHA 再点击签到。主路径直接对 `input[type=checkbox]` 执行 JS `.click()`（该 widget **无 shadow DOM**）；仅当复选框取不到时才退回 CDP 坐标点击兜底。校验复用 `Test-AltchaVerified`。
- **SLIDER**：坐标点击滑块，`ForceLayoutViewport=$true`，失败归 `SLIDER_FAIL` 进入批处理重试。

### 头像 / 下拉菜单类两步签到（pting / fcloudpan）

部分站点把签到藏在**头像下拉菜单**或「点触发器才弹出的弹窗」里，需两步：先点触发器展开，再点里面的真正签到控件。

- **需焦点才渲染**：Base UI / Radix 类下拉在后台 `-NoFocus` 下不渲染（实测 JS `.click()` 后菜单为空）。解决：站点声明 `BringToFront=$true`，由框架在 Detect/Click 前调 `Page.bringToFront`。
- **合成事件要完整**：这类触发器对裸 `click` 不敏感，须补发 `pointerdown → mousedown → pointerup → mouseup → click` 完整指针序列（`clientX/clientY` 取元素 rect 中心）。
- **⚠️ 触发器是 toggle，别盲目补点**：已展开时再点一次会把菜单**关掉**。等待面板时必须先判 `aria-expanded`——已展开则只等不点；否则「面板渲染慢于等待」时补点第二下恰成「开→关」，表现为**间歇性** `UNKNOWN`（fcloudpan 曾前 3 次成功、第 4 次失败）。
- **判定依据**：优先读面板内的真实状态（按钮 `disabled`、「今日已签到」等），而非「点过就算成功」的标志位。

> 焦点与 `-NoFocus`：`navigate newTab=true` 本身不抬窗口；抢焦点的是 `Page.bringToFront`，除 CF 站外，部分站点弹窗需聚焦才渲染（如 pting 日历弹窗）也需要。后台批处理默认 `-NoFocus:$true` 全局不抢焦点；仅当站点声明 `BringToFront=$true` 时瞬时借焦点。

---

## JSON BOM 容错

PowerShell 的 `ConvertFrom-Json` 遇 UTF-8 BOM（`\uFEFF`）会解析失败。每次解析 JSON 前剥离 BOM：

```powershell
$configRaw = Get-Content $ConfigFile -Raw -Encoding UTF8
$configRaw = $configRaw -replace '^\uFEFF', ''
$config = $configRaw | ConvertFrom-Json
```

此规则适用于 `sites.json`、`iterations.json` 等所有 JSON 读取点。

---

## 目录与文件清理规范

每次批处理运行前，工作目录中**仅应存在以下文件**：

| 文件                    | 用途                                                 | 保留？ |
| ----------------------- | ---------------------------------------------------- | ------ |
| `signin-batch.ps1`      | 主批处理脚本                                         | 是     |
| `signin-single.ps1`     | 单站点调试工具                                       | 是     |
| `signin-web.ps1`        | 站点签到固化模块（webbridge 各站点配置）             | 是     |
| `kimi-webbridge.ps1`    | WebBridge API 封装（HTTP 操控 kimi 浏览器）          | 是     |
| `scan-bookmarks.ps1`    | 书签扫描器                                           | 是     |
| `config.example.json`   | 配置模板（脱敏版，供复制为 config.json）             | 是     |
| `config.json`           | 本地配置（含私密 webhook，.gitignore 排除）          | 本地   |
| `sites.json`            | 站点配置                                             | 是     |
| `baseline.json`         | 已知成功站点                                         | 是     |
| `iterations.json`       | 自迭代日志（运行时，.gitignore 排除）                | 运行时 |
| `signin-log.json`       | 每次运行结果日志（运行时，.gitignore 排除）          | 运行时 |
| `sync-log.json`         | 书签同步日志（运行时，.gitignore 排除）              | 运行时 |
| `CHANGELOG.md`          | 版本变更日志                                         | 是     |
| `README.md`             | 项目说明                                             | 是     |
| `.gitignore`            | Git 忽略规则                                         | 是     |
| `pt-signin-skill.md`    | 技能文档（英文）                                     | 是     |
| `pt-signin-skill-cn.md` | 技能文档（中文）                                     | 是     |

所有调试/临时脚本（`debug-*.ps1`、`_tmp_*.ps1`、`fix-encoding.ps1`、`test-browser.ps1`、`check-syntax.ps1`）必须在稳定化后删除。批处理脚本在每次运行开始时自动清理 `web-articles/`。`debug-snapshots/` 与 `debug-shots/` 为运行时快照目录（.gitignore 排除），应定期清理旧快照。

---

## 关键设计决策摘要

- **单一后端**：所有自动签到统一走 kimi WebBridge，无多后端分支。
- **单一会话单 tab**：防泄漏与防 `has no tab` 风暴的根本不变量。
- **`domcontentloaded` 导航**：规避扩展 30s `load` 硬超时导致的 tab 销毁与重试雪崩。
- **visit-only 慢站不重试**：tab 已建立即判成功，避免反复清场重开。
- **后台优先**：`-NoFocus:$true` 全局不抢焦点，CF 处理瞬时借焦点。
- **禁止自动改 manual**：失败站点仅记入「需人工审核」列表，由用户确认后手动改 `sites.json`。
- **配置一致性前置校验**：运行前 `Test-SigninConfigConsistency` 检查「非 manual 站点缺 `$WebSignInConfigs`」等不一致，避免静默跳过。

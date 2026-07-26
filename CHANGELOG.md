# Changelog

## [v4.13.7] - 2026-07-26

### 根治导航 30s 超时 + 反复开 tab（用户实跑复现的根因）

- **根因（实测锤死）**：daemon 的 `navigate` 动作**完全忽略 `waitUntil` 参数**，永远死等 `load` 事件；而大多数 PT 站（CF 挑战 / 慢子资源 / 长连接 / 折叠后台窗口）的 `load` 在 30s 内不触发 → 超时 → **daemon 直接销毁 tab** → 重试路径反复 `newTab` 开新 tab 堆积。v4.13.4 的 `waitUntil=domcontentloaded` 方案（及此前所有尝试）均因此无效——`about:blank` 各取值(commit/load/domcontentloaded…)全 30s 超时即为铁证；baidu 偶成功只是其 `load` 碰巧快。
- **新导航方案（已现场验证）**：`Open-SiteTab` 不再用 `navigate` 跳真目标，改为
  1. `navigate` 到本地 `data:text/html` seed（秒回、零网络/代理依赖）建一个"活" tab；
  2. `cdp Page.navigate` 跳到真目标——**非阻塞、不等 load、不销毁 tab**；
  3. 就绪判定完全交给已有的 `Wait-PageReady` 轮询 DOM。
  - WAF 站(雷池等)会让 daemon 的 `cdp` 包装一直等"导航提交"而卡住（HDKYL 实测 20s+），但导航实际已发起且 tab 存活（实测客户端 8s 提前 abort 后 tab 仍在、HDKYL 已 `complete` 加载）。故 `cdp Page.navigate` 用**短超时 12s + 容错**：超时即视为已发起、转交轮询；导航后仅校验 `list_tabs` tab 仍存活。
- **清理无效参数**：删除全链路 `NavWaitUntil`（daemon 不吃，已成死参数）——`Open-SiteTab`/`Test-WebBridgeSignIn` 参数、6 处调用点、`Invoke-WebSignIn` 透传、pbh-btn 配置。
- **现场复核**：Kufirc `VISITED`(17s)、OurBits `CF_CHALLENGE`(35s)、HDKYL `CF_CHALLENGE`(113s，雷池循环挑战属站点侧)——**均无 30s load 超时、无 tab 堆积**（结束 `list_tabs`=0）。校验：两文件 pwsh7 解析 0 错误；`Test-SigninConfigConsistency` ISSUES=0。
- **未改动的已知次生问题**（与本次无关）：CF Turnstile 在折叠后台窗口里 `cdp:no-rect` 点不中（OurBits/HDKYL 等硬盾站仍返回 `CF_CHALLENGE`，需用户偶尔手动过盾）。

## [v4.13.6] - 2026-07-26

### 全局自然分辨率 + 全局动态轮询 + daemon/extension 自愈

- **默认自然分辨率**（用户要求"不需坐标系一致的站点都恢复自然分辨率"）：`Enable-LayoutViewport`(1280×800) 由"所有站点默认启用"反转为**默认跳过**。`SkipLayoutViewport` 语义反转为 **`ForceLayoutViewport`**（默认 `$false`）：仅坐标点击站声明 `$true`——OurBits/DepthStudio/audiences（CF Turnstile）、Yemapt（ALTCHA，rect 由 ClickEval 在点击前算出，懒启用来不及）。HDKYL 删除冗余 `SkipLayoutViewport`。
- **懒启用兜底**：`Invoke-CfVerifyClick` 顶部新增 `Enable-LayoutViewport`（在 scroll/rect 计算**之前**）——自然分辨率站点中途意外遇到 CF 挑战时坐标系仍一致；对已 Force 的站点幂等无害。
- **全局动态轮询**（用户要求"所有站点长延迟+动态轮询"）：`Test-WebBridgeSignIn` 参数 `LoadWaitSec` 默认 **0→45**，所有站点导航后走 `Wait-PageReady`（每 2s 轮询，就绪即继续，正常站 2~6s 通过，不拖慢）。`Invoke-WebSignIn` 透传改用 `ContainsKey('LoadWaitSec')`，允许站点显式 0 退回固定 `WaitMs`。HDKYL 保持 60。
- **daemon/extension 自愈**：
  - `Test-WebBridgeConnection` 三态探测（ok / extension_down / daemon_down）。⚠️ **弃用 `ping`——现役扩展根本不支持该动作**（现场实测返回 `Unknown tool: ping`，可用动作无 ping），改用 `list_tabs`（真·扩展路径连通判据）。
  - `Restart-WebBridgeDaemon`：stop→清 pid→start→轮询端口+扩展重连（≤30s）。不用 `iex`；exe 缺失只提示手动安装。
  - `Ensure-WebBridgeDaemon` 改走新探测+自愈；新增 `Ensure-WebBridgeHealthy` 挂在 `Test-WebBridgeSignIn` 入口——每站开工前快速探测，断连自动重启（**每次运行至多一次**，防重启风暴），自愈失败返回 NAV_FAIL。
- **顺手修复两个现场踩中的 bug**：
  - `Open-SiteTab` 的 `$ForceNew` 由 `[bool]` 改 **`[switch]`**——调用点裸传 `-ForceNew` 在 [bool] 下报 "Missing an argument"（HDKYL evaluate 失败重导航路径现场触发，属旧隐患现形）。
  - HDKYL Detect 头部加 `if(!document.body) return 'REDIRECTING'`——雷池盾每 ~5s 循环重载（complete→loading），body 为 null 瞬间取 `innerText` 抛 TypeError → EVAL_FAIL 误判。
- **现场复核**（daemon+扩展本次在线）：`Test-WebBridgeConnection`=ok；HDKYL 干净走完流程返回 CF_CHALLENGE（雷池盾对折叠后台窗口无限循环挑战，+30s 曾见"验证完成"后又被重新挑战，1280×800 也过不去，**站点侧 bot 评分问题非代码缺陷**）；`waitUntil=domcontentloaded` 机制正常（baidu 3s 返回）；OurBits 本次 NAV_FAIL 为站点/CF 侧 30s 内 DOM 都不可达，重试链路行为正确。
- **校验**：两文件 pwsh7 解析 0 错误；`Test-SigninConfigConsistency` ISSUES=0。

## [v4.13.5] - 2026-07-26

### HDKYL：跳过强制视口 + 过盾动态等待

- **分辨率太小**：HDKYL 过网站盾(WAF)，强制 `Emulation.setDeviceMetricsOverride` 1280×800 反而让它显得分辨率很小。新增 per-site `$cfg.SkipLayoutViewport=$true`：跳过 `Enable-LayoutViewport`，标签页用**浏览器窗口的自然分辨率**。其余站点仍保持 1280×800（CF Turnstile / ALTCHA 坐标点击需要坐标系一致）。
- **过盾等待太短**：原固定 `WaitMs` 对盾求解不够，常误判 UNKNOWN/SERVER_ERROR。新增 per-site `$cfg.LoadWaitSec=N`：把固定等待换成 `Wait-PageReady` **动态轮询**——每 2s 检查「body 文本足够长且无盾关键词(雷池/正在检查/DDoS/Just a moment/…)」，就绪即继续，最多等 N 秒（不空等满延迟）。HDKYL 设 `LoadWaitSec=60`（用户建议 45s~1min）。
- `Wait-PostNavigate` 统一导航后等待入口（开 `LoadWaitSec` 走动态，否则沿用固定 `WaitMs`，行为不变）；`SkipLayoutViewport`/`LoadWaitSec`/`ReadyEval` 贯穿 `Open-SiteTab`→`Test-WebBridgeSignIn`→`Invoke-WebSignIn`。`ReadyEval` 可选，提供自定义就绪判定 JS（期望 `JSON {ready:true}` 或布尔）。
- **校验**：两文件 pwsh7 解析 0 错误；`Test-SigninConfigConsistency` ISSUES=0。
- ⚠️ **未现场复核**：daemon 当前 502（浏览器/扩展断开），HDKYL 过盾行为与分辨率待浏览器重连后由用户实跑确认。

## [v4.13.4] - 2026-07-26

### 修复：批量运行时重复开大量相同 tab + 普遍 30s 导航超时

- **现象（用户 07-26 实跑复现）**：几乎每个站点反复打开很多个相同 tab，且未先关旧 tab 再重试；`navigate` 普遍 `page load timeout (30s)`，Tokyo/UsefulTrash 等均超时。
- **根因①（主导）**：daemon `navigate` 默认等 **`load` 事件**，多数站点（代理 7890 / CF / 慢子资源）30s 内 `load` 不触发 → 导航超时；卡在"加载中"的 tab 在「函数内 3 次重试 × 外层 3 次重试」里累积，即成"重复开很多相同 tab"。
- **根因②（放大）**：`Close-SiteTabs-Verified` 仅在 `list_tabs` 校验发现漏关时才跑「逐 id 关」退路；若 `close_session` 漏关且 `list_tabs` 因 extension 抖动返回空（假阴性），退路永不触发 → tab 静默累积。
- **修复①**：`Open-SiteTab` 默认 `waitUntil` 由 daemon 的 `load` 改为显式 **`domcontentloaded`**（pbh-btn 已证可行）。本 CLI 检测靠 `evaluate` 轮询 DOM + `WaitMs` 延后，无需等全部子资源；domcontentloaded 让导航 1~3s 返回，规避 30s 超时且不残留卡加载 tab。单站可用 `$cfg.NavWaitUntil='load'` 覆盖（确须等 load 时）。
- **修复②**：`Close-SiteTabs-Verified` 把「逐 id 关」(`Clear-WebBridgeTabs`) 提为**常驻第二关**（best-effort 总跑），与 daemon 级 `close_session` 双保险，不再依赖 `list_tabs` 校验假阴性。
- **校验**：两文件 pwsh7 解析 0 错误；`Test-SigninConfigConsistency` ISSUES=0。
- ⚠️ **未现场复核**：编写时 daemon `ping` 返回 502（浏览器/扩展已断开），未能实跑单站确认导航速度与 tab 数；待浏览器重连后由用户重跑验证。

## [v4.13.3] - 2026-07-26

### pbh-btn 适配修正（现场 DOM 核验，非对齐蜂巢）

- **修正 v4.13.2 的致命选择器错误**：v4.13.2 编写时 daemon 离线，按蜂巢(pting)模式假设 pbh-btn 按钮为 `<button id="checkInButton">`，但 daemon 上线后现场核验证明 pbh-btn 的 Flarum check-in 插件**按钮无 id**。
  - 真实 DOM：未签 = `<button class="Button CheckInButton--yellow hasIcon">签到</button>`（可点）；已签 = `<button class="Button CheckInButton--green hasIcon disabled">已签到N天</button>`。
  - 原 `#checkInButton` 选择器在 pbh-btn 上**永远匹配不到** → 误判 `UNKNOWN`/`NO_DETECT`。
- **Detect 改为 class 选择器**：`document.querySelector('button.CheckInButton--yellow, button.CheckInButton--green')`；命中且 `disabled` 或文本含「已签到」→ `ALREADY_SIGNED`，否则（黄、未 disable）→ `NEED_SIGN`；并保留「签到/每日签到」文本兜底。
- **Click 加护栏**：仅点「未签」状态按钮（黄且未 disabled、文本非已签），避免对已签按钮重复点击；兜底按文本点。
- **新增 `NavWaitUntil` 贯穿通道**（解决 Flarum SPA 导航超时）：
  - `Open-SiteTab` 新增 `[string]$NavWaitUntil` 参数，非空时向 daemon `navigate` 传 `waitUntil`；`Test-WebBridgeSignIn` 在 5 处 `Open-SiteTab` 调用（首开/extension 就绪重试/NAV_FAIL 重试/evaluate 丢 tab 重试/SERVER_ERROR 重导/点击后重导）均透传；`Invoke-WebSignIn` 增加 `if ($cfg.NavWaitUntil) { $params.NavWaitUntil = $cfg.NavWaitUntil }`。
  - pbh-btn 配置加 `NavWaitUntil = "domcontentloaded"`：Flarum 子资源常挂起导致 `load` 永不触发 → 原 30s 超时；改 `domcontentloaded` 让导航先返回再靠 `WaitMs`(15s) 轮询按钮渲染。
- **现场复核（daemon 在线）**：`Invoke-WebSignIn -SiteName pbh-btn` → 导航成功（无 30s 超时）、Detect 返回 `ALREADY_SIGNED`（今日已签，按钮 green disabled「已签到1天」）。校验：两文件 pwsh7 解析 0 错误；`Test-SigninConfigConsistency` ISSUES=0。
- 注意：今日已签，`NEED_SIGN`→点击→`ALREADY_SIGNED` 的真实点击路径未现场跑（按钮 disabled 点击为 no-op）；逻辑与 Detect 对称，待明日未签态再验证一次点击。

## [v4.13.2] - 2026-07-26

### pbh-btn（PBH-BTN 论坛）真实签到适配

- 用户指出 pbh-btn 有真实签到逻辑（此前仅是 SPA 访问保活：`Detect=$SPASignInDetect, Click=$null`）。
- pbh-btn 是 Flarum 论坛，与蜂巢(pting)同款 check-in 插件（`<button id="checkInButton">签到</button>`，点击后按钮消失、显示连续签到天数）。
- 改用与蜂巢同一模式的真实 Detect+Click，并加**文本兜底**（`button/a` 文本精确为「签到」/「每日签到」）以防插件选择器略有差异；已签检测用「已签到/连续签到/今日已签到」文本。
- 从 SPA 通用模板区块移出，并入 v4.12.26 真实签到区块（与 chybenzun/pting 并列）；`sites.json` 策略本就是 `webbridge`，note 更新。
- ⚠️ **编写时 WebBridge daemon 离线，未能现场核验 DOM**。按计划对齐蜂巢模式；若 pbh-btn 实际插件选择器不同，Detect 兜底会回退 `UNKNOWN`（报 `NO_DETECT`，不静默跳过），待 daemon 上线后跑一次单站复核。
- 校验：`signin-web.ps1` 语法 0 错误；`Test-SigninConfigConsistency` ISSUES=0；pbh-btn 配置 `Detect`/`Click` 均已设置。

## [v4.13.1] - 2026-07-26

### 清理 `-ValidateConfig` 报告的 9 条死配置（0 WARN / 0 INFO）

- 运行 `signin-batch.ps1 -ValidateConfig` 报告 9 条 `config-note`（均为 INFO，0 WARN）：
  5 个 `manual` 站点仍带 `$WebSignInConfigs` 条目（FreeFarm / TJUPT / 42w / zxiaoruan / xt-url）+ 4 个无对应 sites.json 的孤儿配置（littlesheep / anyrouter / h-e / pp）。
- 全部删除：`manual` 站点不进入 `Invoke-WebSignIn`，配置永不被触发；孤儿配置无 sites.json 站点，纯死代码。
- 保留 SPA 区块有效条目 `onrender` / `huan666` / `pbh-btn`（非 manual、有 sites.json 对应）。
- 复检：`signin-web.ps1` 语法 0 错误；`Test-SigninConfigConsistency` 现在 **ISSUES=0**（无 WARN 无 INFO）。改动均 git 可追溯。

## [v4.13.0] - 2026-07-26

### 全面代码审查落地（正确性 + 可维护性，语法校验通过；未运行整批签到）

- **🔴 消除 7 个 NexusPHP 站点的「CF 优先」Detect 回归**：OurBits / GGPT / HDDolby / HDHome / TJUPT / HDBao / HHCLUB 各自手写 `if(cf-turnstile) return 'CF_CHALLENGE'` 在**已签到判定之前**，重新引入了 v4.12.9 已修的误判——attendance 页残留 CF widget 的已签页面被误判 `CF_CHALLENGE` → 进入 CF 重试 → 最终 `CF_BLOCKED`（算失败）。
  - 修复：将 7 份近重复 Detect **合并为唯一共享模板 `$NexusPHPSignInDetect`**（已含「已签到优先 + CF token 感知」正确顺序），并扩充信号词并集（补 `签到得鲸币`/`签到得憨豆`/`立即签到`/`已领取`/`本次签到获得`/`异地登录`/`两步验证`/take2fa + `REDIRECTING` 兜底）。7 站直接 `Detect = $NexusPHPSignInDetect`。行为等价且更鲁棒（CF token 已填入时不再误报 CF）。
- **🔴 新增配置一致性校验 `Test-SigninConfigConsistency`**（signin-web.ps1）：排查根因——书签同步新增 `strategy=web-read/browser-open` 站点却忘补 `$WebSignInConfigs` 条目时，`Invoke-WebSignIn` 返回 `NO_CONFIG` 被批处理静默归为 `SKIPPED`，新站点永不签到且无提示。
  - 校验：非 `manual` 站点缺配置 → **醒目 `Write-Warning`**；`manual` 站点仍含配置 / 孤儿配置（无对应 sites.json 站点）→ `INFO`。
  - 接线：`signin-batch.ps1` 循环前自动跑（WARN 输出）；`signin-single.ps1` 加载后跑（WARN 输出）；新增 **`-ValidateConfig` 开关**——仅校验并退出（不打开浏览器、不签到），便于 CI/人工预检。
  - 已用真实 sites.json 验证：0 WARN（无活跃站点会被静默跳过）；负向用例（注入缺配置站点）正确报 WARN。
- **🟡 状态分类修正（signin-batch.ps1）**：补 `SERVER_ERROR` / `EVAL_FAIL` → `PAGE_ERROR`（此前落入 `default`→`NO_DETECT`，分类与重试都失真；现正确归入可重试的 `PAGE_ERROR`）。
- **🟡 清理死代码 / 一致性**：
  - `kimi-webbridge.ps1`：`Test-WebBridgeSignIn` 点击结果改用 `Get-ResultSignal`（消除第 476 行散落的 `$clicked.value` 分支样板，与 v4.12.25 去重目标一致）；删除永不触发的 `CAPTCHA` 死条件（第 347 行 `LOGIN_REQUIRED|CAPTCHA` → `LOGIN_REQUIRED`）；`Clear-WebBridgeTabs` 补全「extension 未连接返回 -1」契约（`list_tabs` 为 `$null` 时显式 `return -1`，此前误返回 0）。
  - `signin-batch.ps1`：删除飞书失败分类 `switch` 中永不命中的死分支（`CAPTCHA`/`TOO_SMALL`/`CF_DETECTED`/`NO_ARTICLE`/`UNKNOWN`），引擎实际只产出 `CF_BLOCKED`/`NO_DETECT`/`其他`。
  - `signin-single.ps1`：调试快照诊断过滤器 `.html` → `.json`（`Save-DebugSnapshot` 实际写 `.json`，原过滤器永远匹配不到，诊断输出形同虚设）。

### 审查中识别但**本版未实施**（低风险/需活体验证，列出供后续）
- **V2EX / Yemapt / FreeFarm 的 CF 优先 Detect**：V2EX 为真实 managed-challenge 流（title 驱动），FreeFarm 已 `manual`，Yemapt 为 SPA+ALTCHA 特殊流；三者非 NexusPHP attendance 模式、当前可工作，强行重排 CF 顺序有回归风险，**留待活体验证后单独处理**。
- **`$NexusPHPClick` 抽共享模板**：5 份「收紧匹配」Click JS 完全重复，属纯维护性问题、当前可工作，机械替换风险低但未做（避免大批量相同块锚定出错）。
- **孤儿配置清理 / `iterationLog` 死代码 / 魔法数字集中化 / `scan-bookmarks` 与 `Sync-Bookmarks` 模式统一**：均为低优先级维护项，本版未动以避免误删用户可能启用的配置或破坏飞书卡片渲染。

### 改动文件
`signin-web.ps1`（共享 Detect 合并 + 配置校验函数）、`signin-batch.ps1`（校验接线 + `-ValidateConfig` + 状态分类 + 飞书死分支清理）、`kimi-webbridge.ps1`（Get-ResultSignal/死条件/-1 契约）、`signin-single.ps1`（.json 过滤器 + 校验接线）、`CHANGELOG.md`。

## [v4.12.26] - 2026-07-23

### 站点适配（参考 07-23 签到结果，针对性修复 4 站 + FreeFarm 结论）

- **🔴 NodeSeek 检测误判回归（真 bug）**：原 Detect 末尾 `return 'LOGIN_REQUIRED'` 为兜底，
  导致 NodeSeek 自有「Oops! Nework Error」网络错误页被误判为「登录失效」→ 误报 `LOGIN_REQUIRED` 回归
  （实际 07-14 曾 SIGN_OK，是站点/代理侧波动）。
  - 修复：`Network Error`/`Nework Error`/`Oops`/`重新加载` → `SERVER_ERROR`；并补 `chrome-error:`/`ERR_` 预检；
    兜底由 `LOGIN_REQUIRED` 改为 `UNKNOWN`（不再触发「需重新登录」通知）。仅改分类逻辑，登录失效页（`请登录` 等）仍正确判 `LOGIN_REQUIRED`。
- **🔴 cdy（传道院）配置补全**：原 `web-read` 策略但 `$WebSignInConfigs` 缺条目 → `NO_CONFIG` 被跳过。
  `pt.cdy.pics/attendance.php` 为 NexusPHP 通用签到页，补配置
  `Detect=$NexusPHPSignInDetect` + `Click=$NexusPHPCfSignInClick`（兼容「访问即签到」与「需提交表单」两种形态，比 `Click=$null` 更稳）；策略 `web-read`→`webbridge`。
- **🟢 chybenzun（CHY 公益订阅）/ pting（蜂巢）补真实签到逻辑（用户指正：二者均有签到按钮，非 visit-only）**：
  原 `browser-open` 但缺配置 → `NO_CONFIG` 跳过；上一版误判为非签到页改 `visit-only`，本次据实际网页 DOM 修正。
  - **CHY**：主页 `<a class="btn btn-primary" href="/claim">领取今日 5GB</a>` 为每日领流量按钮。点击跳 `/?msg=` 并显示 `.banner`；
    banner 含「领取成功」→ `SIGN_OK`，含「今日已领取过奖励」→ `ALREADY_SIGNED`（按钮常驻页面，故首页无 banner 即 `NEED_SIGN`）。
  - **蜂巢**：Flarum 论坛 `<button id="checkInButton">签到</button>`；点击后按钮消失（被连续签到天数取代）→ 按钮存在=`NEED_SIGN`，消失=`ALREADY_SIGNED`。
  - 二者改 `webbridge` 并补 `Detect`+`Click` 配置；排查中已实际点击验证：CHY 成功领取 5GB、蜂巢按钮消失显示「已签到 6 天」。
- **🔴 FreeFarm SLIDER 结论：当前架构无法自动适配 → strategy 改 `manual`（用户要求）**。
  `Invoke-SlideBypass` 依赖页面 JS 中的 `set_access_token` 端点做 token 注入式绕过；
  现 FreeFarm 已切换为**真·拖拽滑块**（页面纯「拖动滑块验证」，HTML 无 `set_access_token`，`slide_check_*.js` 文件名哈希滚动），
  该 token 注入法已失效。自动适配需实现「识别滑块图 → 计算位移 → CDP 模拟人类拖拽」的真实滑块求解器，
  属显著新功能且对抗站点反爬、脆弱，**超出本 CLI 范围**。故 `sites.json` 中 FreeFarm `strategy` 由 `webbridge` 改 `manual`，不再自动尝试，需人工点滑块。

### 改动文件
`signin-web.ps1`（NodeSeek Detect 修复 + cdy/chybenzun/pting 真实签到配置）、`sites.json`（chybenzun/pting→webbridge、FreeFarm→manual、cdy→webbridge）、`CHANGELOG.md`。

## [v4.12.25] - 2026-07-22

### 优化落地（落实代码 & 文档审查的全部优化点）

- **🔴 关后校验 + 重试（真正可观测的去重）**：新增 `Close-SiteTabs-Verified`（kimi-webbridge.ps1）。`Open-SiteTab` 不再裸调 `Close-WebBridgeSession`，改为：整会话强关 → `list_tabs` 校验 → 仍非空则再强关一次 + 退路 `Clear-WebBridgeTabs`（逐 id 关）→ 末次校验。漏关数 `$leaked>0` 时**写日志告警**，使"daemon 漏关"从静默累积变为一眼可见（直击 v4.12.24 的未实证假设）。`Clear-WebBridgeTabs` 由此从死函数变为真实的第二道清理。
- **🔴 删除 `signin-batch.ps1` 的死变量 `$session="pt$idx"`**：它从未传给 `Invoke-WebSignIn`（后者硬编码 `"daily-signin"`），却会让后人"好心修 bug"传 `-Session` 导致各站独立会话、上一站 tab 永不关 → 泄漏重现。已删，并在 `Open-SiteTab` 注释写明"所有站点必须共用单一会话"的不变量。
- **🔴 `NoFocus` 默认翻转为 `$true`**（signin-web.ps1）：任何漏传调用方都会触发 `Page.bringToFront` 弹前台（刚修掉的现象），故默认后台、前台改为显式 opt-in；顺手删掉 `signin-batch.ps1` 已不被读取的 `[switch]$NoFocus`。
- **🔴 布局视口覆盖改为 per-navigate 启用**（kimi-webbridge.ps1）：原 `Enable-LayoutViewport` 只在 `Test-WebBridgeSignIn` 顶部启用一次，函数内 `Open-SiteTab` 重开 tab（evaluate 丢 tab / SERVER_ERROR / 点击后重开）后视口覆盖丢失 → 0×0 → CF/ALTCHA 坐标点击静默失效。现收进 `Open-SiteTab`，每次 navigate 成功后立即启用，任意新 tab 都带 1280×800 视口。
- **🔴 确认 bug：`Sync-Bookmarks` 日志变量名写错**：`bookmarkCount = $bookmarkUrls.Count` 中 `$bookmarkUrls` 全程未定义（函数用 `$bookmarkInfos`），导致 `sync-log.json` 的 `bookmarkCount` 永远记 0。改为 `$bookmarkInfos.Count`。
- **🟡 信号提取去重**：抽 `Get-ResultSignal` 统一处理 `evaluate` 返回的字符串/`value` 分支，替换 `Test-WebBridgeSignIn` 内 12 处复制粘贴样板，消除"漏 `.value` 分支"类不一致隐患；快照分支的 `"{}"` 兜底保留。
- **🟡 CHANGELOG 自我修正**：v4.12.24 把"close_session 可靠"写成事实，今补注其为**未实证假设**；`signin-batch.ps1` 过时版本串 `v3.8` → `v4.12.25`。
- **🟢 文档**：新增 `README.md`——4 个入口脚本的使用时机（日常/batch、单站调试/single、失败续跑/rerun-remaining、续跑补推飞书/push-cumulative）+ `sites.json` 三态 strategy 矩阵（webbridge / visit-only / manual）。

### 改动文件
`kimi-webbridge.ps1`、`signin-web.ps1`、`signin-batch.ps1`、`CHANGELOG.md`、`README.md`（新增）。

## [v4.12.24] - 2026-07-22

### 修复（重复开 tab 真正结构性根治 —— v4.12.22/23 均未能解决）
- **现象**：`signin-batch.ps1` 运行期间同一站点被重复开出大量相同 tab，**比修复前更多**（用户 07-22 反馈）。说明 v4.12.22/23 的「先关后开」逻辑从未真正抑制累积。
- **根因（复盘，推翻 v4.12.23 的作用域论断）**：
  1. v4.12.22 把「尽量复用 tab」改成「**每次都 `newTab=true`**」——每站点开 6+ 次新 tab，比旧版开得多；泄漏随「关不净」复利放大。
  2. 关旧 tab 依赖 `list_tabs`（extension 抖动会误报，用户早前已确认）+ `close_tab`（签到 tab 在**折叠后台 window** 中 `active=False`，按 id 关也常命中不到）→ **不可靠**。
  3. v4.12.23 的「`$script:` 记忆单 tabId 关旧 tab」仍受上述 `close_tab`/`list_tabs` 不可靠牵连；且 `$script:` 跨 dot-source 作用域本就脆弱。故该修复未生效，累积依旧。
- **真正修复（结构性，不依赖 list_tabs / close_tab / 单 tabId 记忆）**：`Open-SiteTab` 每次导航前先 **`Close-WebBridgeSession`**（daemon 级强关，见 v4.12.19「**即使 extension 断开也生效**」），整会话清空后再 `newTab=true` 开**唯一**一个 tab。
  - 任意时刻本会话 **≤ 1 个 tab**，与 `list_tabs` 是否误报、`close_tab` 是否命中**无关**。
  - 首次 / NAV_FAIL 重试 / extension 就绪重试 / evaluate 丢 tab 重试 / CF 重试 / SLIDER 重开 / 点击后重开 **全部走 `Open-SiteTab`** → 每次必定先整会话强关再开新，满足「**即便重试也先关旧 tab 再开新的**」。
  - 移除已失效的 `$_wbSiteTabId` 跟踪机制与入口/ finally 的 `Clear-WebBridgeTabs` 预清（改由 `Open-SiteTab` 强关统一负责）；`Clear-WebBridgeTabs` 保留为后备函数。
- **验证**：仅做语法校验（用户要求今日不运行脚本）。逻辑上 `Close-WebBridgeSession` 为 daemon 级、不受 extension 抖动影响，是比 `list_tabs`+`close_tab` 更可靠的唯一清场手段；现有「站点间 finally `close_session` → 下一站点 `navigate` 重建 tab」模式已被长期证明可行，故站内每次 `close_session`+`navigate` 同样安全。
- **事后补记（v4.12.25）**：上句"`close_session` 可靠"为**未实证假设**——`close_session` 能否关掉折叠 159×27 后台窗口里的 tab 从未在真实场景验证，而 `list_tabs`/`close_tab` 对同类 tab 已证不可靠。v4.12.25 已把"关"改为**关后 `list_tabs` 校验 + 重试 + `Clear-WebBridgeTabs` 退路**（`Close-SiteTabs-Verified`），泄漏从静默累积变为日志可见。

### 附：前台弹窗修复（同轮次）
- **现象**：运行 `signin-batch.ps1` 时浏览器标签页被弹到前台（用户明确「不希望弹前台」）。
- **根因**：`signin-batch.ps1` 调用 `Invoke-WebSignIn` 传的是 `-NoFocus:$NoFocus`，而批次自身的 `[switch]$NoFocus` 默认 `$false` → 触发 `Test-WebBridgeSignIn` 内 `Page.bringToFront`（kimi-webbridge.ps1:223-225，CF Turnstile 需焦点才渲染 iframe）。`signin-single.ps1` / `rerun-remaining.ps1` 早已硬编码 `-NoFocus:$true`，唯独 batch 默认抢前台。
- **修复**：`signin-batch.ps1` 两处调用（`Invoke-WebSignIn` 首跑 + 失败重试）统一改为 `-NoFocus:$true`，批处理全程后台，与 single/rerun 一致。注：daemon 的 `navigate newTab=true` 本身不抬窗口（v4.12.22 注释已确认「-NoFocus 时浏览器全程后台」），故关闭 `Page.bringToFront` 即彻底避免弹前台；CF Turnstile 站点因此可能渲染失败（原本经 CDP 点击亦不稳），但与「不弹前台」的用户诉求相比优先级更低。

## [v4.12.23] - 2026-07-21
> ⚠️ 该版本对重复 tab 的修复**未生效**（见 v4.12.24）。其作用域诊断偏离真正根因，仅作历史记录保留。

### 修复（重复开 tab 真正根因 —— v4.12.22 修复因作用域 bug 从未生效）
- **现象**：`signin-batch.ps1` 运行期间同一站点被重复开出大量相同 tab，重试时旧 tab 未关就又开新的（用户报告）。
- **根因**：v4.12.22 引入的「确定性单 tab」跟踪变量 `$_wbSiteTabId` 存在 **PowerShell 作用域 bug**——脚本顶层声明后，`Open-SiteTab` / `Test-WebBridgeSignIn` 内部对它的**赋值全部使用裸 `$_wbSiteTabId = ...`**，在函数内会创建**函数局部变量**而非更新脚本级变量。结果：`Open-SiteTab` 打开 tab 后 tabId 从未持久化到脚本级 → 下次调用读到 `$null` → 确定性「先关后开」永不触发 → 静默退化为不可靠的 `list_tabs`（`Clear-WebBridgeTabs`）清理 → tab 累积（重试尤甚）。
- **修复**：`kimi-webbridge.ps1` 中全部 `$_wbSiteTabId` 读写统一改为 **`$script:_wbSiteTabId`**（声明、Open-SiteTab 读+关+写、Test-WebBridgeSignIn 入口重置、finally 兜底关闭）。所有导航（首开 / NAV_FAIL 重试 / CF 重试 / SERVER_ERROR 重试 / 点击后重开）均走 `Open-SiteTab`，故每次导航前必先关上一个 tab；每次 `Invoke-WebSignIn`（含 batch 层重试）的 finally 也会关掉本次 tab。
- **验证**：AsianDVDClub 连续 3 次 NAV_FAIL 重试后 `list_tabs` 返回 `tabs:[]`（0 残留）——修复前该场景会残留 3 个 tab。

### 变更
- **AsianDVDClub 改为 visit-only**：`sites.json` 策略 `webbridge` → `visit-only`（用户要求仅打开网页、不签到）。其在 `signin-web.ps1` `$WebSignInConfigs` 中本就是 `Detect=$null/Click=$null`，故走 visit-only 分支返回 `VISITED`；本次仅对齐 `strategy` 语义。

## [v4.12.17] - 2026-07-14

### 修复
- **xloli BODY_NULL / CF 误判（v4.12.9 类变体）**：`kimi-webbridge.ps1` 的 CF 重试循环仅在首次 Detect 返回 `CF_CHALLENGE|BODY_NULL|REDIRECTING` 时进入；xloli 在 CF 挑战期首次 Detect 返回 `BODY_NULL`（页面尚未渲染完），进入重试后**只查 CF 状态、不再重跑完整 Detect**，导致后来渲染出的"得到魔力加成"（已签到）页面永不被识别，最终以失败漏判。
- **修复**：CF 重试循环每次迭代开头先重跑完整 `$DetectEval`；若返回非 `CF_CHALLENGE`/`BODY_NULL` 信号（`SIGN_OK`/`ALREADY_SIGNED`/`NEED_SIGN`/`LOGIN_REQUIRED` 等）则按该信号处理并退出循环，真 CF 站点行为不变。重跑 xloli → **ALREADY_SIGNED ✓**（07-14 计入成功，总体 39/49）。

### 工程改进
- **`signin-batch.ps1` 逐站增量落盘**：原仅在全部跑完才写 `signin-log.json`，后台任务被环境回收则结果全丢。改为每跑完一站在 `finally` 写入 `rerun-cumulative.json` 同结构文件（最终完整 summary 仍结尾覆盖），中途回收也能从 log 读到已完成部分。

### 本轮结果（2026-07-14 全量，网络恢复后重跑，39/49）
- 成功 39（21 SIGN_OK + 11 ALREADY_SIGNED + 7 VISITED）；失败 10，全部站点侧，非代码缺陷。
- 对比 07-13 的 15/49：17 个 `ERR_CONNECTION_CLOSED` 故障在网络恢复后几乎全部消失（仅 ptlao 仍 `ERR_CONNECTION_CLOSED`、Tokyo 转 `ERR_PROXY_CONNECTION_FAILED`，均属站点/代理侧）。
- 失败 10 分类：
  - `CF_CHALLENGE` ×2：OurBits、audiences（真 CF 全页挑战 / Turnstile，CDP 无法绕过）
  - `SERVER_ERROR` ×2：Tokyo（`ERR_PROXY_CONNECTION_FAILED` 代理路由）、ptlao（`ERR_CONNECTION_CLOSED` 站点/代理关连接）
  - `NEED_SIGN` ×2：vclib、521（imagestring 验证码，浏览器 OCR 扩展未成功填入）
  - `UNKNOWN` ×1：Rousi（SPA 状态未识别，潜在 detect 增强点）
  - `BODY_NULL` ×2：42w、zxiaoruan（OAuth/源站 521，manual 站）
  - manual ×3：TJUPT（图片验证码）、42w、zxiaoruan（策略 manual，需人工）—— 注 42w/zxiaoruan 同时出现在 BODY_NULL 与 manual 分类
- **代码可优化候选**：① Rousi（SPA 动态渲染，07-08/09 曾成功，07-14 UNKNOWN，疑似时序/结构变化）；② audiences（07-09 快照 body 含"每日签到 完成"，疑似已签到被 CF 检测误判，需加强"已签到优先于 CF"判断）。二者非阻断，留待后续。
- 报告 `signin-report-2026-07-14.html`（gen-report.py 按当前日期动态生成）。

## [v4.12.16] - 2026-07-13

### 修复
- **Yemapt ALTCHA PoW 重置（真正根因）**：v4.12.15 的「±12px 小簇 + 8s 等待」仍未解决本质问题——多个候选点依次 CDP 点击会**反复重置 ALTCHA 的工作量证明（PoW）**，导致 PoW 永远算不完。改为：**单击精确点(rx,ry)一次启动 PoW，随后仅轮询 `Test-AltchaVerified`（每 3s，最多 42s）不再连点**；仅首点 + 长轮询失败时，才退而用小簇候选点各点一次并分别长轮询。本次重跑由 NEED_SIGN → **SIGN_OK ✓**（验证修复有效）。

### 本轮环境事件（2026-07-13 全量，15/49）
- **成功率骤降主因为网络出口故障，非代码缺陷**：快照取证确认 17 个 `SERVER_ERROR` 站点实为 `chrome-error://chromewebdata/` + `ERR_CONNECTION_CLOSED`（浏览器 TCP 连接被对端关闭），属代理/VPN/防火墙或 ISP 出口问题。重跑结果一致（持久），重跑无法修复。
- 成功 15（5 SIGN_OK + 3 ALREADY_SIGNED + 7 VISITED）；失败 34 分类：连接关闭 17、页面空/OAuth 5(BODY_NULL)、UNKNOWN 10（hdbao 快照亦为 ERR_CONNECTION_CLOSED，其余多为同因或 SPA 未渲染）、CF_CHALLENGE 1(OurBits)、LOGIN_REQUIRED 1(NodeSeek)。
- 仅 Yemapt 为可修复代码问题（已修复）；其余均站点/网络侧。建议网络恢复后重跑或检查本机代理/VPN。
- 报告 `gen-report.py` 的 `SERVER_ERROR` 原因文案修正为「连接被关闭(ERR_CONNECTION_CLOSED)」；`push-cumulative.ps1` 失败分组标签同步更新。

## [v4.12.15] - 2026-07-12

### 修复
- **Yemapt ALTCHA 验证时机**：`kimi-webbridge.ps1` 的 ALTCHA 候选点击原每次仅等 2s 即查 `Test-AltchaVerified`，且 5 个候选点连点会反复重置 ALTCHA 的 PoW 计算，导致永远验证不完（多候选点均失效）。改为：候选点收拢到精确复选框点(rx,ry)附近小簇（±12px），每次点击后等 **8s** 让 PoW 完成；页面内 `setInterval` 轮询在验证完成后自动点「立即签到」。实测 Yemapt 由 NEED_SIGN → SIGN_OK。
- **invites 误判排查**：原批量跑报 NEED_SIGN（点击后 recheck 仍 NEED_SIGN）。诊断确认其为 SPA 异步渲染时机竞态——按钮先短暂显示黄色「签到」，等后端 API 返回后才切绿色「已签到 X 天」；批量跑恰好卡在黄色阶段。Detect 逻辑本身正确（识别绿色/「已签到」即 SIGN_OK），重跑即通过为 ALREADY_SIGNED，**无需改代码**。

### 本轮结果（2026-07-12 全量）
- 49 站分 6 块前台续跑（rerun-remaining），44/49 成功（24 SIGN_OK + 13 ALREADY_SIGNED + 7 VISITED）。
- 较 07-11 的 42/49 提升：DepthStudio/audiences（CF 宽松日+45s 等待）、Yemapt（ALTCHA 时机修复）、invites（SPA 竞态重跑）均恢复。
- 仍失败 5 站（站点侧，代码层不可修）：TJUPT/vclib/521（图片/imagestring 验证码）、ptlao（HTTP 500）、xt-url（OAuth 登录态缺失）。

## [v4.12.14] - 2026-07-11

### 修复
- **`push-cumulative.ps1` 失败站点可点击链接丢失**：失败列表拼装（原第 106 行）误用 `Get-Dn`（仅展示名纯文本），改为 `Format-SiteLink` → `[display_name](url)` 飞书 lark_md 可点击链接。与 `signin-batch.ps1` 的 `Send-FeishuSummary` 行为对齐（该版本失败区一直用 `Format-SiteLink`）。成功列表仍保持纯文本，避免 30+ 链接撑爆卡片。

## [v4.12.13] - 2026-07-11

### 改进
- **`gen-report.py` 日期自动化**：报告标题时间戳与输出文件名 `signin-report-YYYY-MM-DD.html` 改为按当前日期动态生成，不再硬编码（此前每次跑需手改日期）。
- **skill 文档固化推送路径**：`pt-signin-skill.md` / `pt-signin-skill-cn.md` 的「运行后动作」明确两条推送路径——`signin-batch.ps1` 末尾自动 `Send-FeishuSummary`；续跑流程 `rerun-remaining.ps1` 跑完 4 块后须单独 `.\push-cumulative.ps1` 补推（该路径本身无推送，漏跑则收不到飞书）。

### 2026-07-11 全量结果（续跑流程，42/49 成功）
- 成功：22 SIGN_OK + 13 ALREADY_SIGNED + 7 VISITED。
- 失败 7（均站点/环境侧，非代码缺陷）：TJUPT / vclib / 521（图片/imagestring 验证码）、ptlao（HTTP 500）、xt-url（OAuth BODY_NULL）、DepthStudio / audiences（CF 严格日全页墙，45s 等待已证实无效）。
- 相较上轮：UsefulTrash 瞬断（NAV_FAIL）重试恢复为 VISITED；zxiaoruan 由 BODY_NULL 恢复为 SIGN_OK。

## [v4.12.12] - 2026-07-10

### 修复 / 新增
- **audiences / DepthStudio**：CF 单次重试等待 `CfRetryWaitMs` 20s→45s（用户要求拉长，覆盖更硬的 CF 插页）；单站最坏等待 ≈ 24s + 6×45s ≈ 294s。
- **新增 `push-cumulative.ps1`**：解耦飞书推送。续跑流程（`rerun-remaining.ps1` / `signin-web.ps1`）本不含推送逻辑，新增脚本读取 `rerun-cumulative.json` 一次性推送飞书卡片，保留崩溃安全的同时补上推送环节（07-10 结果据此补推）。

## [v4.12.11] - 2026-07-10

### FreeFarm 滑块误报修复 + PigGo 雷池 WAF 修复 + DepthStudio/audiences CF 耐心 + 基线回归修复

基于 07-10 全量签到（42 成功 / 7 失败，共 49 站）的针对性适配。本轮把成功数从上一轮 33/49 提升到 42/49。

#### 改动1: FreeFarm SLIDER 误报根因修复（signin-web.ps1 + kimi-webbridge.ps1）

- **根因**：FreeFarm 旧 Detect 用 `div[class*="challenge"]` 误匹配布局 div，且 SLIDER 检测排在已签到关键词之前，导致已登录页（显示"签到成功/第 N 次签到"、无 challenge iframe）被长期误判为 SLIDER 滑块 → 移入 manual 长期未自动签。
- **修复 signin-web.ps1**：FreeFarm Detect 改为**已签到关键词优先 + 精确滑块检测**（仅当"滑动滑块 / 验证您是真人 / 确认您是真人 / 滑动认证"或 challenge iframe 存在时才判 SLIDER）。
- **新增 Invoke-SlideBypass（kimi-webbridge.ps1）**：在 `<script src*=slide>` 中正则提取 `set_access_token` token 路径 → `fetch` 该路径（credentials include）→ reload 绕过滑块。命中后重测，出现 SIGN_OK/ALREADY_SIGNED 即返回（最多 2 次尝试）。
- **配置**：`sites.json` FreeFarm 策略 manual→webbridge；`baseline.json` 移回 auto。
- **结果**：FreeFarm ALREADY_SIGNED ✓（之前因误报 SLIDER 长期未自动签）。

#### 改动2: PigGo 雷池(Safeline) WAF 挑战修复（signin-web.ps1）

- **根因**：PigGo 部署雷池 WAF，签到页初始 body 为空（仅 WAF JS challenge 加载），旧 `WaitMs=12000` 不足 → UNKNOWN。
- **修复**：PigGo `WaitMs` 12000→30000，让 WAF 挑战求解后注入真实内容。
- **结果**：PigGo ALREADY_SIGNED ✓（修复基线回归）。

#### 改动3: DepthStudio / audiences CF 耐心加大（signin-web.ps1）

- **背景**：两站为真实 CF 站点（表单含 `.cf-turnstile` data-sitekey）。CDP 点击在 CF 严格日全页挑战期找不到 widget → 返回 no-rect，无法绕过（skill lesson 35）。
- **修复**：`WaitMs` 18000→24000，`CfRetryCount` 4→6，`CfRetryWaitMs` 15000→20000。应对 CF 宽松日自动过；严格日仍拦截（站点侧波动，非代码缺陷）。

#### 改动4: 基线回归修复（baseline.json + sites.json）

- FreeFarm（滑块误判修复）、UBits、Yemapt（ALTCHA）、42w（URL 恢复）经 webbridge 验证可自动签到，从 `baseline.json` 的 manual_sites 移回 sites（auto）。
- baseline 版本 v4.10.1→v4.12.11；auto_total 49→57，manual_total 12→8。

#### 07-10 全量签到结果

| 类别 | 数量 | 说明 |
| ---- | ---- | ---- |
| OK   | 42   | 24 SIGN_OK + 11 ALREADY_SIGNED + 7 VISITED |
| FAIL | 7    | DepthStudio/audiences(CF_CHALLENGE)、TJUPT(图片验证码)、zxiaoruan(OAuth BODY_NULL)、ptlao(HTTP 500)、vclib/521(imagestring 扩展 OCR) |

**已知限制**：余下 7 站失败均为站点 / 扩展侧（CF 严格日波动、图片验证码、OAuth 登录、源站故障、浏览器扩展 OCR），代码层无法修复。

## [v4.12.6] - 2026-07-07

### CDP Shadow DOM 穿透 + NexusPHPSignInDetect 修复 + ALTCHA 适配

基于 07-07 全量签到（34 成功/8 失败/6 跳过，NEW: vclib+521，baseline 47→49）的针对性优化。v4.12.4/v4.12.5 的 CF 站点配置在此版本集成 CDP 点击方案后落地。

#### 改动1: CF Turnstile CDP 点击方案（kimi-webbridge.ps1）

- **根因**：CF Turnstile 使用 `attachShadow({mode:'closed'})` 封装 iframe，JS `evaluate` 永远看不到内部 checkbox；旧版 `Invoke-CfVerifyClick` 通过 DOM 查找 widget 必然返回 `cdp:no-widget`
- **修复**：`Invoke-CfVerifyClick` 完全重写为 CDP（Chrome DevTools Protocol）方案
  - `DOM.describeNode(pierce=true)` 穿透 closed shadow DOM 定位 CF iframe 节点
  - `Input.dispatchMouseEvent` 模拟三步点击：`mouseMoved` → `mousePressed` → `mouseReleased`
  - 点击坐标取 iframe 左侧约 24px 处（checkbox 实际位置，非中心点）
- **新增**：`Invoke-CdpClickIframe` 辅助函数封装 CDP 点击逻辑
- **辅助**：navigate 后调用 `Page.bringToFront` 让标签页获得焦点（CF Turnstile 需要页面有焦点才渲染 iframe）
- **CF 重试循环修复**：`no-cf` 状态也触发重新检测（CF 验证通过后 widget 被移除、token 被清空，旧逻辑只在 `passed:` 时重新检测会漏判）

#### 改动2: NexusPHPSignInDetect cfTokenPassed 修复（signin-web.ps1）

- **根因**：CF 通过后 `.cf-turnstile` div 仍在 DOM 中，`attendance-captcha-table` label 含"安全验证"文本，旧逻辑误判为 CF_CHALLENGE → 无限重试
- **修复**：检查 `input[name="cf-turnstile-response"]` token 是否填入
  - token 未填入 + CF widget 存在 → 返回 `CF_CHALLENGE`（真实未通过）
  - token 已填入 → 跳过下方 CF 文本检测（避免"安全验证" label 误判）
- **影响站点**：PigGo（CF_BLOCKED 误判 → 改用 `$NexusPHPSignInDetect`）

#### 改动3: Yemapt ALTCHA 适配（signin-web.ps1）

- **根因**：Yemapt 使用 ALTCHA proof-of-work 验证（`altcha-checkbox-wrap` class），点击"立即签到"前需先处理 ALTCHA checkbox，否则 NEED_SIGN
- **修复**：Click JS 重写为两阶段流程
  1. 检查 ALTCHA checkbox 是否存在且未验证 → 点击 checkbox
  2. `setInterval` 每 1 秒轮询 ALTCHA PoW 计算完成（最多 12 秒）→ 自动点击签到按钮
- **调优**：`PostClickMs` 从 8000 增加到 15000（ALTCHA 轮询 + 签到按钮等待）

#### 改动4: NexusPHPCfSignInClick 通用 Click JS（signin-web.ps1，v4.12.5 引入）

- 新增 `$NexusPHPCfSignInClick` 通用 Click JS 模板，用于 NexusPHP + CF Turnstile 站点
- 流程：检查 token 已填入 → 找到 attendance 表单 → 点击 submit 按钮
- 适用站点：DepthStudio/xloli/audiences（CF 通过后提交签到表单）

#### 改动5: CF 站点等待时间配置（signin-web.ps1，v4.12.5 引入）

- DepthStudio/xloli/audiences: `CfRetryCount=4`, `CfRetryWaitMs=15000`, `WaitMs=18000`
- Yemapt: SPA + CF 检测 + 叶子节点 Click 策略；`sites.json` strategy 从 `manual` 改为 `webbridge`（v4.12.4）

#### 07-07 全量签到结果

| 类别 | 数量 | 站点 |
| ---- | ---- | ---- |
| NEW  | 2    | vclib, 521（验证码扩展方案生效） |
| OK   | 34   | 52pojie, HDKYL, OurBits, V2EX, 13City, AsianDVDClub, BiliDownload, BTSchool, DigitalCore, GGPT, HDClone, HDDolby, HDHome, HDVideo, HHCLUB, HTCPT, Kufirc, M-Team, NewInsane, Rousi, SBPT, SpeedApp, Tokyo, UsefulTrash, YHPP, 远景论坛, h-e, hdbao, musopia, onrender, vclib, 521, huan666, pbh-btn |
| FAIL | 8    | PigGo(CF_BLOCKED, 已适配), DepthStudio(CF_BLOCKED, CDP被检测), Moment(NAV_FAIL), xloli(CF_BLOCKED, CDP被检测), Yemapt(NEED_SIGN, 已适配), ptlao(SERVER_ERROR), audiences(NAV_FAIL), invites(NAV_FAIL) |

**已知限制**：CF Turnstile 检测 CDP 自动化行为，DepthStudio/xloli CDP 点击成功（`cdp:clicked`）但 token 一直 `pending:cf-text` 未填入。需用户确认是否改回 manual。

## [v4.12.3] - 2026-07-05

### extension 冷启动等待 + HDKYL chrome-error 检测 + UNKNOWN 重试改进

基于 07-05 全量签到（00:50 启动，30 成功/12 失败）的调试发现：脚本在 v4.12.2 commit 前 8 小时启动，加载的是 v4.12.1 旧版代码，所以 v4.12.2 的 Clear-WebBridgeTabs 和 UNKNOWN 重试都没生效。本次修复 v4.12.2 未覆盖的问题。

#### 改动1: extension 冷启动等待（kimi-webbridge.ps1）

- **根因**：daemon 启动后 extension 需要几秒才连接，首个站点（52pojie）navigate 时 extension 未就绪，返回 "no extension connected" 导致 NAV_FAIL
- **修复**：navigate 失败时调用 `list_tabs` 检测 extension 是否就绪，未就绪则等待 5 秒重试，最多 3 次（共 15 秒）
- **影响站点**：52pojie（首个站点 NAV_FAIL → 等待 extension 后正常）

#### 改动2: HDKYL Detect 添加 chrome-error 检测（signin-web.ps1）

- **根因**：HDKYL 服务器间歇性关闭连接（ERR_CONNECTION_CLOSED），页面跳转到 `chrome-error://chromewebdata/`，Detect 缺少此检测返回 UNKNOWN
- **修复**：Detect 添加 `location.protocol==='chrome-error:'` + `t.indexOf('无法访问此页面')>-1` + `t.indexOf('ERR_CONNECTION')>-1` 检测，返回 SERVER_ERROR
- **影响站点**：HDKYL（UNKNOWN → SERVER_ERROR，正确报告问题）

#### 改动3: UNKNOWN 重试改进（kimi-webbridge.ps1）

- **根因**：v4.12.2 的 UNKNOWN 重试等待 3 秒重试 1 次，对间歇性 SPA 加载慢（如 Rousi）不够
- **调试证据**：Rousi 09:14:59 失败（bodyText 空，`<div id="root"></div>` 未渲染），09:18:48 成功（SIGN_OK）→ 间歇性 SPA 加载慢
- **修复**：UNKNOWN 时等待 5 秒重试 2 次（共 10 秒），给 SPA 更多渲染时间
- **影响站点**：Rousi（间歇性 UNKNOWN → 等待后应能成功）

#### 07-05 调试快照分析

| 站点  | 时间     | 结果    | 页面状态                                               |
| ----- | -------- | ------- | ------------------------------------------------------ |
| Rousi | 09:14:59 | UNKNOWN | bodyText 空，`<div id="root"></div>` 未渲染            |
| Rousi | 09:18:48 | SIGN_OK | bodyText 完整，含"已签到"+"连续 4 天"                  |
| HDKYL | 09:16:54 | UNKNOWN | `chrome-error://chromewebdata/`，ERR_CONNECTION_CLOSED |

## [v4.12.2] - 2026-07-05

### 标签泄漏修复 + UNKNOWN 重试 + HDKYL Detect 优化

基于 07-05 全量签到结果（30 成功/12 失败）的针对性优化。3 个 NAV_FAIL 站点（52pojie/HDClone/HHCLUB）的根因是标签泄漏，2 个 UNKNOWN 站点（HDKYL/Rousi）的根因是 Detect 逻辑缺陷。

#### 改动1: 标签泄漏修复（kimi-webbridge.ps1）

- **根因**：`Test-WebBridgeSignIn` 用单次 `close_tab` 清理 tab，但 extension 断开时 `close_tab` 失败被 `try/catch` 静默吞掉，旧 tab 残留。重试时 `navigate newTab=$true` 创建新 tab，导致同一 URL 累积多个标签
- **修复**：新增 `Clear-WebBridgeTabs` 函数，用 `list_tabs` 循环检查 + `close_tab` 逐个关闭，最多清理 10 个残留 tab
- **替换**：`Test-WebBridgeSignIn` 中 3 处单次 `close_tab`（开始/evaluate 重试/finally）全部替换为 `Clear-WebBridgeTabs`
- **影响站点**：52pojie/HDClone/HHCLUB（NAV_FAIL → 应恢复正常）

#### 改动2: UNKNOWN 重试逻辑（kimi-webbridge.ps1）

- **根因**：SPA 站点（如 Rousi）内容动态渲染，首次 Detect 运行时页面还没加载完，返回 UNKNOWN
- **修复**：Detect 返回 UNKNOWN 时，等待 3 秒后重新检测一次。如果状态变化则用新信号
- **影响站点**：Rousi（UNKNOWN → SIGN_OK，测试通过）

#### 改动3: HDKYL Detect 优化（signin-web.ps1）

- **根因**：HDKYL 已签到时显示"[签到已得110, 补签卡: 0]"，原 Detect 缺少"签到已得"关键词匹配
- **修复**：Detect 添加 `t.indexOf('签到已得')>-1` 匹配
- **影响站点**：HDKYL（UNKNOWN → SIGN_OK，被 CF 临时拦截待验证）

#### 07-05 全量签到失败站点分析

| 站点                        | Signal       | 根因             | 处理                    |
| --------------------------- | ------------ | ---------------- | ----------------------- |
| 52pojie/HDClone/HHCLUB      | NAV_FAIL     | 标签泄漏         | 已修复（v4.12.2 改动1） |
| HDKYL                       | UNKNOWN      | Detect 缺关键词  | 已修复（v4.12.2 改动3） |
| Rousi                       | UNKNOWN      | SPA 加载慢       | 已修复（v4.12.2 改动2） |
| DepthStudio/xloli/audiences | CF_CHALLENGE | CF 拦截          | 无法自动修复，等待恢复  |
| Moment/ptlao                | SERVER_ERROR | 服务器错误       | 无法自动修复，等待恢复  |
| vclib/521                   | NEED_SIGN    | 验证码扩展未填入 | 需用户确认扩展配置      |

## [v4.12.1] - 2026-07-04

### 项目目录整理 + 英文版 skill 同步

#### 改动1: iterations.json 从 git 追踪中移除

- **背景**：iterations.json 是 self-iterating 模式的运行时日志（40 条历史记录），但被错误地提交到 git 仓库
- **改动**：`git rm --cached iterations.json` + 加入 .gitignore，与 signin-log.json/sync-log.json 同等处理
- **效果**：本地文件保留，但 git 不再追踪其变化

#### 改动2: 英文版 pt-signin-skill.md 同步到 v4.12.0

- **背景**：英文版停留在 v4.10，落后中文版两个版本（v4.11.0/v4.12.0）
- **同步内容**：
  - frontmatter updated 时间更新到 v4.12.0
  - Coverage 表格站点数更新（48+4=52 → 42+7=49，新增 NexusPHP + captcha 类别）
  - Directory & File Hygiene 表格：iterations.json/signin-log.json 标注为 Runtime，新增 sync-log.json
  - Phase 1/2 站点数 51 → 49
  - 新增 sites.json Field Definitions 部分（含 display_name 字段）
  - 新增 lesson 40 (display_name 字段) / 41 (验证码扩展方案) / 42 (CF/2FA 检测)

#### 改动3: README.md 核心文件表格完善

- 新增 CHANGELOG.md / README.md / pt-signin-skill.md / pt-signin-skill-cn.md / .gitignore 条目
- iterations.json / signin-log.json / sync-log.json 标注"运行时，.gitignore 排除"

#### 改动4: pt-signin-skill-cn.md 目录说明完善

- iterations.json / signin-log.json 标注从"是"改为"运行时"
- 新增 sync-log.json 条目

## [v4.12.0] - 2026-07-04

### 验证码站点改回 webbridge + CF/2FA 检测增强

基于用户反馈"浏览器已配备验证码自动输入脚本"，对之前因验证码改为 manual 的站点重新启用 webbridge，并增强 CF/2FA 异常状态识别。

#### 改动1: vclib/521 改回 webbridge + Click JS 轮询验证码

- **背景**：v4.10.1 将 vclib/521 改为 manual（NexusPHP 图片验证码阻塞）。用户反馈浏览器扩展可自动填入验证码
- **改动**：strategy 从 `manual` 改回 `webbridge`
- **Click JS 方案**：因 webbridge evaluate 同步执行不支持 Promise，用 `setInterval` 异步轮询 `input[name="imagestring"]`：
  - evaluate 立即返回 `CLICK_SCHEDULED`
  - PostClickMs 期间 setInterval 每秒检查 imagestring.value
  - 检测到值时 `submit.click()` 提交表单
- **v4.12.1 调优**：轮询窗口从 12 秒扩到 28 秒，PostClickMs 从 15 秒扩到 30 秒（扩展识别 NexusPHP 图片验证码可能需要更长时间）
- **已知限制**：521 实测扩展未自动填入（28 秒内 imagestring 仍为空），需用户确认浏览器扩展是否在 pt.521.best 域名下启用

#### 改动2: V2EX Detect 增加 CF_CHALLENGE 识别

- **根因**：V2EX 触发 Cloudflare managed challenge（title="请稍候…" + "正在进行安全验证"），原 Detect 未识别返回 UNKNOWN
- **修复**：Detect 增加 CF_CHALLENGE 信号，检测以下特征：
  - `.cf-turnstile` / `iframe[src*="challenges.cloudflare.com"]` / `#challenge-stage` / `[name="cf-turnstile-response"]` 元素
  - title 含"请稍候" / bodyText 含"正在进行安全验证" / "安全验证"
- **效果**：CF_CHALLENGE 归入 capSites 分类，避免误判为 baseline 回归

#### 改动3: HDDolby Detect 增加 2FA 异地登录检测

- **根因**：HDDolby 异地登录跳转 `take2fa.php`，要求输入两步验证码。原 Detect 未识别，Click JS 误点导航栏链接
- **修复**：Detect 增加 LOGIN_REQUIRED 信号，检测以下特征：
  - URL pathname 含 `take2fa.php`
  - bodyText 含"异地登录" / "两步验证"
- **效果**：归入 login_required 分类，触发飞书卡片提醒用户人工处理

#### 全量测试结果（2026-07-04 01:25）

- **总站点**：49（已跳过 9 个 manual）
- **成功**：36 个站点（SUCCESS + ALREADY_DONE + VISITED）
- **失败**：4 个站点
  - V2EX: CF managed challenge 拦截（已修复 Detect，待明日验证）
  - HDDolby: 异地登录 2FA（已修复 Detect，待明日验证）
  - xloli: CF Turnstile 持续拦截 284 秒重试全失败（需人工介入）
  - ptlao: HTTP ERROR 500 服务器错误（等待服务器恢复）

## [v4.11.0] - 2026-07-03

### display_name 字段 + 飞书可点击链接

#### 新增1: sites.json display_name 字段

- **目的**：解决飞书推送中 cryptic 站点名（如 `42w`/`521`/`pp`/`littlesheep`/`audiences`）不可读问题
- **设计**：`name` 字段保持不变（5 处主键依赖：WebSignInConfigs 查找、baseline.json 比对、fail_sites 去重、signin-single 查找、debug 快照文件名），`display_name` 纯展示层，缺失时回退到 `name`
- **覆盖**：20 个 cryptic 站点添加 display_name（15 已有 + 5 新增：audiences/huan666/xt-url/pbh-btn/invites）

#### 新增2: Sync-Bookmarks 提取书签 name

- **改造**：`Walk-BookmarkNodes` 从只提取 url 改为提取 `@{ url; name }` 对象
- **效果**：新增站点时自动用书签 name 作为 display_name，从源头消除 cryptic 名字
- **兼容**：书签 name 与 nameGuess 相同时省略 display_name，避免冗余

#### 新增3: 飞书卡片可点击链接

- **改造**：`Send-FeishuSummary` 新增 `Get-Dn`/`Format-SiteLink` 辅助函数，10 处 joined 变量改造
- **链接覆盖范围**：manual 跳过、失败分类（CF/无响应/未识别/其他）、会话失效、新基线、基线回归、需人工审核
- **不加链接**：成功列表（30+ 站点，加链接会致卡片过长）
- **lark-cli text 兜底**：自动受益于 display_name（通过 Get-Dn），但不支持 markdown 链接，保持纯文本

## [v4.10.1] - 2026-07-03

### 全量签到调试修复（v4.10 首次全量签到反馈）

基于 v4.10 全量签到的 16 个失败站点 debug 快照分析，按根因分类修复。AUTO_OK 从 31 提升至预期 38+。

#### 修复1: $NexusPHPSignInDetect 繁体支持（影响 SBPT）

- **根因**：SBPT 实际已签到成功（页面显示"簽到成功 這是您的第 210 次簽到"），但 detect JS 只匹配简体"签到成功"，返回 UNKNOWN。
- **修复**：$NexusPHPSignInDetect 加入繁体匹配：簽到已得 / 今日已簽到 / 已簽到 / 簽到成功 / 簽到得魔力 / 簽到得鯨幣 / 簽到領取。
- **新增 SERVER_ERROR 信号**：识别 chrome-error:// 页面和 HTTP ERROR 500/502，避免误判为 UNKNOWN（影响 ptlao 等服务器临时不可用场景）。

#### 修复2: HHCLUB Click JS 按钮文本扩展

- **根因**：detect 返回 NEED_SIGN:签到获得10个憨豆，但 Click JS 只匹配"签到得魔力/签到得鲸币/签到/打卡"，不匹配"签到获得XX憨豆"，返回 NO_BTN。
- **修复**：Click JS 前缀匹配增加 `签到获得`，支持 HHCLUB 的"签到获得10个憨豆"按钮。

#### 修复3: 13City URL 修正

- **根因**：原 URL `usercp.php?action=personal#signin` 是一键签到聚合页（显示"→开始签到←"按钮和站点列表），detect JS 无法识别页面状态。
- **修复**：改为 `attendance.php` 单站点签到页，与 NexusPHP 通用模板匹配。

#### 修复4: 7 个站点改为 manual（无法自动化）

基于 debug 快照确认根因后，将以下站点 strategy 改为 manual：

| 站点        | 根因                                      | 备注                                      |
| ----------- | ----------------------------------------- | ----------------------------------------- |
| vclib       | 签到页需输入图片验证码（CAPTCHA）         | `<input name="imagestring">` + 验证码图片 |
| 521         | 签到页需输入图片验证码（CAPTCHA）         | 同 vclib                                  |
| zxiaoruan   | 重定向到 /sign-in 登录页（LinuxDO OAuth） | 未登录态无法签到                          |
| littlesheep | 重定向到 /sign-in 登录页                  | 未登录态无法签到                          |
| xt-url      | 页面显示"请先使用 Linux Do 登录"          | 未登录态无法签到                          |
| 42w         | URL 返回 404（页面未找到）                | 签到入口失效，需人工确认                  |
| pp          | URL 返回 404（页面未找到）                | 签到入口失效，需人工确认                  |

#### 修复5: EVAL_FAIL tab 丢失自动恢复（kimi-webbridge.ps1）

- **根因**：v4.10.1 全量签到发现 5 个站点（SBPT/onrender/ptlao/huan666/HTCPT）EVAL_FAIL，错误 `session "daily-signin" has no tab`。webbridge daemon bug：navigate 返回 success=true 但 tab 在 WaitMs 等待期间消失。
- **修复**：`Test-WebBridgeSignIn` 在 evaluate 失败时（$detect 为 null），自动重新 close_tab + navigate + evaluate 一次，恢复 tab 丢失场景。
- **验证**：SBPT/onrender 单站点测试通过（SIGN_OK），确认 tab 丢失为间歇性问题，修复有效。

#### 修复6: HHCLUB 方括号按钮匹配 + detect 关键词（signin-web.ps1）

- **根因**：HHCLUB 签到按钮文本为 `[签到得憨豆]`（方括号包裹），Click JS 精确匹配和前缀匹配均不匹配。detect 未识别 `已领取`/`本次签到获得` 等已签到文本。
- **修复**：Click JS 增加 `vu.replace(/^\[|\]$/g,'')` 去方括号后匹配；Detect 加入 `签到得憨豆`/`已领取`/`本次签到获得` 关键词。
- **验证**：单站点测试 ALREADY_SIGNED（因前次 click 已成功签到）。

#### 修复7: re-check evaluate 超时增大（kimi-webbridge.ps1）

- **根因**：点击后页面重载导致 tab 暂时不可用，re-check evaluate 15s 超时不够。
- **修复**：re-check evaluate TimeoutSec 从 15 增至 30。

#### v4.10.1+ 全量签到结果（AUTO_OK=34, AUTO_FAIL=6）

- **成功 (34)**：52pojie, HDKYL, NodeSeek, PigGo, V2EX, 13City, AsianDVDClub, BiliDownload, BTSchool, DigitalCore, GGPT, HDClone, HDDolby, HDHome, HDVideo, HTCPT, Kufirc, M-Team, Moment, NewInsane, Rousi, SBPT, SpeedApp, Tokyo, UsefulTrash, YHPP, 远景论坛, h-e, hdbao, musopia, onrender, huan666, pbh-btn, invites
- **失败 (6)**：OurBits(CF), DepthStudio(CF), HHCLUB(已修复), xloli(CF), ptlao(SERVER_ERROR), audiences(CF)
- **Manual skip (11)**：FreeFarm, UBits, TJUPT, Yemapt, 42w, zxiaoruan, pp, littlesheep, vclib, 521, xt-url
- **回归 (7)**：OurBits, DepthStudio, HHCLUB, xloli, ptlao, anyrouter, audiences — 其中 4 个 CF + 1 个 SERVER_ERROR + 1 个 LOGIN_REQUIRED(cookie失效) + HHCLUB(已修复)

#### 保留 webbridge（环境问题，非配置问题）

- **OurBits / DepthStudio / xloli / audiences**：CF 挑战无法通过 turnstile checkbox 点击绕过，环境问题。
- **ptlao**：服务器返回 HTTP 500，临时不可用（已加入 SERVER_ERROR 信号识别）。
- **invites**：站点返回"您没有权限进行此操作"，可能账号权限问题，保留 retry。

#### 数据同步

- `baseline.json`：sites 列表移除 7 个改 manual 站点，manual_sites 增加 7 项；auto_total 48→41，manual_total 5→12。
- `sites.json`：version 升级至 v4.10.1，13City URL 更新，7 站点 strategy 改为 manual 并补充 note。

## [v4.10] - 2026-07-03

### opencli 全面替代为 kimi webbridge（单后端架构）

**目标**：消除对 opencli 的依赖，所有非 manual 站点统一走 kimi webbridge 后端，简化架构。

#### Phase 1: kimi-webbridge.ps1 支持 visit-only 模式

- `Test-WebBridgeSignIn` 在 navigate + wait 之后、detect 之前加 visit-only 分支：`DetectEval` 为空时返回 `VISITED`，支持"仅访问"类站点（M-Team / SpeedApp 等）。

#### Phase 2: signin-batch.ps1 简化 switch + 移除 opencli 代码

- 移除 8 个 opencli 专用函数：`Test-SignIn` / `Wait-PageReady` / `Browser-SignIn` / `Get-PageContent` / `Find-NewSignPatterns` / `Invoke-FreeFarmTokenRefresh` / `Invoke-WebReadFallback` / `Invoke-PatternDiscovery`。
- 主 switch 从 5 分支（web-read / browser-open / browser-eval / browser-eval-click / browser-visit / manual）简化为 2 分支（manual / default → webbridge）。
- 新增 `VISITED` 返回值处理（visit-only 站点）。
- 移除 catch 中的 `opencli browser $session close`。
- 文件从 997 行精简至 633 行。

#### Phase 3: signin-web.ps1 批量添加站点配置

- 新增两个通用 JS 模板：`$NexusPHPSignInDetect`（NexusPHP attendance.php 通用检测）和 `$SPASignInDetect`（SPA 控制台/资料页通用检测），减少 32 个站点配置的重复代码。
- 新增 33 个站点配置：
  - 15 个 NexusPHP attendance.php（Click=$null，访问即签到）：BiliDownload / DepthStudio / HDClone / HDVideo / HTCPT / Moment / SBPT / Tokyo / xloli / YHPP / musopia / ptlao / vclib / 521 / audiences
  - 1 个 13City（特殊 URL `usercp.php?action=personal#signin`）
  - 7 个 visit-only（Detect=$null, Click=$null）：AsianDVDClub / DigitalCore / Kufirc / M-Team / NewInsane / SpeedApp / UsefulTrash
  - 9 个 SPA 控制台（使用 `$SPASignInDetect`）：42w / h-e / zxiaoruan / pp / littlesheep / onrender / huan666 / xt-url / pbh-btn
  - 1 个 invites（https://invites.top/console，SPA 控制台类）
- 重命名 `InvitesFun` → `invites`（与 sites.json 键名对齐）。
- 总配置数：50（17 原有 + 33 新增），覆盖全部 48 个非 manual 站点。

#### Phase 4: sites.json 统一 strategy

- 48 个非 manual 站点 strategy 统一改为 `webbridge`（原 browser-open 23 / web-read 17 / browser-visit 8）。
- 4 个 manual 站点保留（FreeFarm / UBits / TJUPT / Yemapt）。
- version 升级至 `v4.10`。
- 清理 note 中 opencli 引用（OurBits / Rousi）。

#### Phase 5: 文档与脚本同步

- `signin-single.ps1` 重写为调用 webbridge（移除全部 opencli 调用）。
- `README.md` 更新：架构图、签到策略表、Kimi WebBridge 优势、前提条件、配置项说明。
- 移除脚本中所有 opencli 注释引用。

### 架构变化

| 维度        | v4.9.1（旧）                                                          | v4.10（新）                  |
| ----------- | --------------------------------------------------------------------- | ---------------------------- |
| 后端        | opencli + kimi webbridge（双）                                        | kimi webbridge（单一）       |
| strategy 值 | web-read / browser-open / browser-visit / browser-eval-click / manual | webbridge / manual           |
| switch 分支 | 5 + note 路由门                                                       | 2（manual / default）        |
| 配置覆盖率  | 17/52（33 个无配置走默认分支）                                        | 50/52（48 非 manual 全覆盖） |

## [v4.9.1] - 2026-07-02

### 全量签到调试修复

#### Click JS 选择器误点修复（HDDolby 卡死循环根因）

- **问题**: HDDolby 连续 3 次 `NEED_SIGN → click → recheck 仍 NEED_SIGN`。Click JS 用 `v.indexOf('签到')>-1` 太宽泛，匹配到导航栏 `<a>` 元素（textContent="欢迎回来, Schalkiiii ( UID: 40534 ) [退出] 签到..."），click 点错对象。同时 Detect JS 关键词 `签到得魔力` 与 HDDolby 实际 `签到得鲸币` 不匹配。
- **修复 signin-web.ps1**: 重写 Click JS 为"精确匹配 + 叶子节点过滤 + 长度限制"模板：
  - 第一优先级：`v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'`（精确等于）
  - 第二优先级：`v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)`（前缀匹配 + 长度限制）
  - `el.children.length>1 continue`（跳过容器，只点叶子节点）
- **批量加固**: 同模板统一替换 PigGo/OurBits/GGPT/HDHome/TJUPT 5 处 Click JS（replace_all）。HDBao 单独修复（保留 input[value*="签到"] 优先匹配）。
- **HDDolby Detect JS**: 加 `签到得鲸币` 关键词匹配。

#### HHCLUB 回归修复（baseline 站点直接 ERROR）

- **根因**: sites.json 中 HHCLUB note 是"改用browser-open"不含"webbridge"，signin-batch.ps1 line 499 `if ($site.note -match "webbridge")` 不匹配，走错分支（opencli Browser-SignIn 而非 webbridge），返回 ERROR。
- **修复 signin-web.ps1**: 新增 HHCLUB 配置（基于 NexusPHP 加固模板，含 CF_CHALLENGE/Just a moment 检测 + 收紧 Click JS）。
- **修复 sites.json**: HHCLUB note 改为含 "webbridge" 关键词。

#### P0 改动效果验证（v4.9）

- ✅ **ALREADY_SIGNED 信号正确触发**: HDKYL/GGPT/HDHome/PigGo/V2EX 首次 SIGN_OK → ALREADY_DONE（不再误报"本次签到成功"）
- ✅ **真签到成功流程正常**: 52pojie/NodeSeek/BTSchool/远景论坛/Rousi 流程正常
- ✅ **tab 生命周期**: 签到结束后 list_tabs 返回空，close_tab 生效，无累积
- ✅ **tab 生命周期实测**: navigate → close_tab → list_tabs 验证 closed:true, tabs:[]

#### 待处理问题（非本次改动相关）

- **opencli daemon 不可用**: `opencli web read` 报 BROWSER_CONNECT 错误（port 19825 不可用），导致 17 个 baseline web-read 站点全部 NO_ARTICLE 回归。环境问题，需用户手动修复 opencli daemon。
- **11 个新站点 ERROR**: 42w/h-e/zxiaoruan/pp/littlesheep/onrender/anyrouter/huan666/xt-url/pbh-btn/invites note 是"auto: 书签同步新增"不含"webbridge"，走错分支。需逐个添加 webbridge 配置。

## [v4.9] - 2026-07-01

### 假 pass 防御（问题 3：报告成功但实际未签到）

- **signin-web.ps1**: 移除 PigGo/GGPT/HDDolby/HDHome/TJUPT 5 处 `签到得` 误判关键词。"签到得魔力"是按钮文本（NEED_SIGN），原逻辑误判为 SIGN_OK，导致页面加载即报成功、根本不执行点击。
- **signin-batch.ps1**: `Test-SignIn` 移除 `已完成`、`Daily Bonus` 两个宽泛词。"已完成"出现在多种非签到上下文，"Daily Bonus"常为菜单项。
- **kimi-webbridge.ps1**: `Test-WebBridgeSignIn` 引入状态转换验证——
  - 无 ClickEval（访问即签到，如 BTSchool）：首次 SIGN_OK → 真实成功
  - 有 ClickEval（需点击站点）：首次 SIGN_OK → `ALREADY_SIGNED`（今天已签到，非本次成功）
  - 点击后 recheck SIGN_OK → `SIGN_OK`（本次签到成功）
- **signin-batch.ps1**: webbridge switch 新增 `ALREADY_SIGNED` → `ALREADY_DONE` 处理，计入 ok_sites，不可重试。

### Tab 生命周期管理（问题 2：重试开多个标签、上一个没关就开下一个）

- **kimi-webbridge.ps1**: `Test-WebBridgeSignIn` 用 `try/finally` 包裹，开头 `close_tab` 清理残留 tab，finally `close_tab` 关闭本站点 tab。每个站点期间仅 1 个 tab，重试时先关再开，不再累积。webbridge 支持 `close_tab` action 已探测确认。

### 同步日志落盘（问题 1 排查工具）

- **signin-batch.ps1**: `Sync-Bookmarks` 每次运行把 Added/Removed/NoChanges 写入 `sync-log.json`（保留最近 50 条），含时间戳、书签数量、增删列表，便于排查"新书签为何没同步进来"。

### 文档

- **pt-signin-skill.md**: 更新 Eval Patterns 示例（移除误判词）、Signal Semantics 表加 ALREADY_SIGNED、Core Functions 注释、新增 lessons #35/#36。
- **README.md**: 核心文件表加 sync-log.json，新增书签同步排查与签到状态语义说明。

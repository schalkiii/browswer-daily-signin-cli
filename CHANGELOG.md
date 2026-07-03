# Changelog

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

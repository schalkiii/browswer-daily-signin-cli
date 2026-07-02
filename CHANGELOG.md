# Changelog

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

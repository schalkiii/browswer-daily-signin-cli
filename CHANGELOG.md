# Changelog

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

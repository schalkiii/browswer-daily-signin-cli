# Browser Daily Sign-in CLI

一键批量签到 PT 站点、论坛的 PowerShell 自动化工具。支持 40+ 站点，CF 完美绕过，飞书卡片推送。

## 为什么需要这个工具？

PT 站点和论坛的每日签到是典型的「重复性手工劳动」——每天打开几十个标签页、逐个点击签到按钮。这个工具把这些操作压缩成一条命令，跑完自动推送到飞书，全程无需人工干预。

## 快速开始

### 前提条件

| 依赖           | 版本要求      | 用途                                 |
| -------------- | ------------- | ------------------------------------ |
| PowerShell     | 7.0+          | 脚本运行环境                         |
| kimi webbridge | daemon 运行中 | 真实浏览器操控（签到 + CF/WAF 绕过） |
| Edge / Chrome  | 任意          | 书签数据来源                         |

### 三步上手

```powershell
# 1. 克隆仓库
git clone https://github.com/schalkiii/browswer-daily-signin-cli.git
cd browswer-daily-signin-cli

# 2. 配置（复制模板并填写你的浏览器路径和飞书 Webhook）
copy config.example.json config.json
notepad config.json

# 3. 运行
.\signin-batch.ps1
```

> **注意**: `config.json` 包含私密信息（飞书 Webhook），已被 `.gitignore` 排除。
> 仓库中提供 `config.example.json` 作为模板，运行前请复制并填写真实值。
> 首次运行前请确保 kimi webbridge daemon 已在 `http://127.0.0.1:10086` 运行。

## 配置

所有路径和参数集中在 `config.json`，无需修改脚本代码。`config.example.json` 是仓库中的脱敏模板。

```json
{
  "version": "1.0",
  "description": "浏览器每日签到 CLI — 集中配置文件。复制为 config.json 后填写你自己的值。",
  "browser": {
    "type": "edge",
    "userDataPath": "C:\\你的浏览器UserData目录", // 浏览器用户数据目录
    "profilePath": "Data\\Default", // Profile 子路径
    "bookmarkFolder": "PT/签到" // 书签文件夹名称
  },
  "webbridge": {
    "baseUrl": "http://127.0.0.1:10086/command" // daemon 地址
  },
  "feishu": {
    "webhook": "", // 飞书机器人 Webhook URL
    "chatId": "",
    "enabled": true
  },
  "signin": {
    "concurrency": 1,
    "waitOpenMs": 6000,
    "waitEvalMs": 8000,
    "timeoutSec": 90,
    "articleDir": "web-articles"
  }
}
```

### 配置项说明

| 配置路径                 | 类型   | 默认值                           | 说明                                      |
| ------------------------ | ------ | -------------------------------- | ----------------------------------------- |
| `browser.userDataPath`   | 路径   | —                                | 浏览器安装目录或 User Data 父目录（必填） |
| `browser.profilePath`    | 路径   | `Data\Default`                   | 相对于 userDataPath 的 Profile 路径       |
| `browser.bookmarkFolder` | 字符串 | `PT/签到`                        | 书签栏中用于筛选签到站点的文件夹名        |
| `webbridge.baseUrl`      | URL    | `http://127.0.0.1:10086/command` | kimi webbridge daemon 地址                |
| `feishu.webhook`         | URL    | —                                | 飞书机器人 Webhook 地址                   |
| `feishu.chatId`          | 字符串 | —                                | 飞书群聊 ID（可选，用于 lark-cli 推送）   |
| `feishu.enabled`         | 布尔   | `true`                           | 是否启用飞书推送                          |
| `signin.waitOpenMs`      | 毫秒   | `6000`                           | 页面打开后等待时间                        |
| `signin.waitEvalMs`      | 毫秒   | `8000`                           | JS 执行后等待时间                         |
| `signin.timeoutSec`      | 秒     | `90`                             | 单站点超时时间                            |

## 架构

```
config.json                     sites.json（站点列表）
    │                                │
    │  ┌─────────────────────────────┘
    ▼  ▼
signin-batch.ps1（主调度）
    │
    ├─ Sync-Bookmarks（扫描浏览器书签 → 同步增删到 sites.json）
    │
    ├─ 签到策略分发（v4.10 单后端）
    │   ├─ webbridge ─→ signin-web.ps1 → kimi-webbridge.ps1 → 真实浏览器
    │   │                ├─ NexusPHP attendance.php（访问即签到）
    │   │                ├─ JS 点击签到（论坛/控制台）
    │   │                └─ visit-only（仅访问，不检测）
    │   └─ manual ─────→ 跳过（需人工）
    │
    ├─ baseline.json（基线追踪：回归检测 / 新站点发现）
    │
    └─ 飞书卡片推送
```

## 签到策略

v4.10 起统一为单一 `webbridge` 后端，移除 opencli 依赖。站点配置在 `signin-web.ps1` 的 `$WebSignInConfigs` hashtable 中按站点名匹配，通过 `Detect`/`Click` JS 模板差异化处理：

| 策略        | 站点数 | 原理                                      | 适用场景                       |
| ----------- | ------ | ----------------------------------------- | ------------------------------ |
| `webbridge` | 42     | 操控真实浏览器：navigate → detect → click | NexusPHP / 论坛 / SPA 控制台等 |
| `manual`    | 7      | 跳过                                      | 验证码/滑块/未登录/人工确认    |

**webbridge 站点配置类型**（由 `signin-web.ps1` 中的 Detect/Click 决定）：

| 配置类型            | Detect       | Click   | 状态转换                                                                                |
| ------------------- | ------------ | ------- | --------------------------------------------------------------------------------------- |
| NexusPHP attendance | 通用检测模板 | `$null` | 访问即签到，首次 SIGN_OK = 真实签到成功                                                 |
| 论坛/JS 点击        | 站点特定 JS  | 站点 JS | 首次 SIGN_OK = ALREADY_SIGNED（今天已签到）                                             |
| SPA 控制台          | SPA 模板     | `$null` | 登录态保持即视为成功                                                                    |
| visit-only          | `$null`      | `$null` | 仅访问，返回 VISITED                                                                    |
| NexusPHP + 验证码   | 通用检测模板 | 轮询 JS | Click JS 用 setInterval 轮询 imagestring，待浏览器扩展填入后提交（v4.12.0+，vclib/521） |

### 重要规则：禁止自动添加 manual

**系统永远不会自动将站点改为 `manual` 策略。** 遇到疑似需要人工处理的站点（CF 拦截、滑块验证等），系统只会：

1. 在控制台输出 `[REVIEW] 需人工审核` 提示
2. 在飞书卡片中显示"需人工审核"区块
3. 在 `signin-log.json` 中记录 `needs_manual_review` 列表

是否改为 `manual` 策略，**必须由用户人工确认后手动修改 `sites.json`**。

### Kimi WebBridge 优势

v4.10 起为唯一后端，操控用户真实浏览器（Chrome/Edge）完成签到：

- **CF/WAF 完美绕过**：真实浏览器携带 CF 信任令牌，零挑战
- **真实登录态**：复用用户浏览器 Profile，无需独立登录
- **固化代码**：每个站点的 Detect/Click JS 已调试验证，稳定重放
- **不可检测**：与人工浏览行为一致，不被识别为自动化

## 核心文件

| 文件                  | 说明                                                       |
| --------------------- | ---------------------------------------------------------- |
| `signin-batch.ps1`    | **主入口** — 书签同步 → 签到 → 飞书推送                    |
| `signin-single.ps1`   | 单站点调试工具                                             |
| `signin-web.ps1`      | webbridge 各站点签到逻辑固化（URL + detect JS + click JS） |
| `kimi-webbridge.ps1`  | webbridge HTTP API 封装                                    |
| `scan-bookmarks.ps1`  | 独立书签扫描器（调试用）                                   |
| `config.example.json` | **配置模板**（复制为 `config.json` 后填写真实值）          |
| `config.json`         | **本地配置文件**（已在 .gitignore 中排除，不上传仓库）     |
| `sites.json`          | 站点列表（自动由书签同步维护）                             |
| `baseline.json`       | 基线追踪（记录曾成功签到的站点）                           |
| `CHANGELOG.md`        | 版本变更日志                                               |
| `README.md`           | 项目说明（本文件）                                         |
| `pt-signin-skill.md`  | 技能文档（英文）                                           |
| `pt-signin-skill-cn.md` | 技能文档（中文）                                         |
| `.gitignore`          | Git 忽略规则                                               |
| `iterations.json`     | 自迭代修复日志（运行时，.gitignore 排除）                  |
| `signin-log.json`     | 每次运行的结构化日志（运行时，.gitignore 排除）            |
| `sync-log.json`       | 书签同步日志（运行时，.gitignore 排除）                    |

## 使用指南

### 日常签到

```powershell
.\signin-batch.ps1
```

每次运行自动完成：

1. 扫描浏览器书签，同步新增/删除的站点
2. 逐个执行签到
3. 写入运行日志
4. 推送飞书卡片报告

### 单站点调试

```powershell
# 测试指定站点（使用 webbridge）
.\signin-single.ps1 -SiteName "52pojie"

# 指定配置文件
.\signin-single.ps1 -SiteName "V2EX" -ConfigFile ".\sites.json"
```

### 扫描书签

```powershell
# 扫描浏览器书签中的签到站点
.\scan-bookmarks.ps1
```

### 飞书推送

运行成功后会推送飞书卡片消息，包含：

- **彩色标题栏**：绿色=全部成功 / 黄色=部分失败 / 红色=大量失败
- **成功列表** + 回归新发现标记
- **失败分类**：CF 拦截、无响应、登录失效、未知信号、其他
- **人工签到** 汇总
- **自迭代摘要**

要在飞书中接收通知，需要在 `config.json` 中配置 `feishu.webhook`：

```json
{
  "feishu": {
    "webhook": "https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxxxx",
    "enabled": true
  }
}
```

## 书签管理

工具通过浏览器书签自动维护站点列表。推荐做法：

1. 在 Edge 书签栏创建文件夹（默认名 `PT/签到`）
2. 将要签到的站点书签放入该文件夹
3. 每次运行自动同步：新增站点自动加入、删除站点自动移除
4. `sites.json` 中的 `note` 字段记录同步状态
5. `display_name` 字段（可选）：飞书推送和日志展示用的可读名称，缺失时回退到 `name`。Sync-Bookmarks 新增站点时自动从书签 name 提取

## 调试与排错

### Debug 快照（v4.8+）

签到失败时，可以保存页面的完整 HTML/文本快照为 JSON，用于事后分析。

```powershell
# 批量签到时保存所有站点的快照
.\signin-batch.ps1 -SaveDebugSnapshot

# 快照保存位置
debug-snapshots/
  ├── UBits_cf_blocked_final_20260623-212533.json
  ├── BTSchool_sign_ok_20260623-212015.json
  └── ...
```

每个快照包含：

- `url` / `title` / `readyState` — 页面基本信息
- `bodyText` — 页面文本内容（前 5000 字）
- `bodyHtml` — 页面 HTML（前 30000 字）
- `cfIframes` — 检测到的 Cloudflare iframe 列表
- `signTexts` — 包含签到/验证/登录等关键词的上下文片段

### 书签同步排查（v4.9+）

如果发现新书签没被同步进 `sites.json`，查 `sync-log.json`：

```powershell
# 查看最近一次同步记录
Get-Content .\sync-log.json -Raw -Encoding UTF8 | ConvertFrom-Json | Select-Object -Last 1
```

每条记录含 `bookmarkCount`（匹配到的书签数）、`added`/`removed`（增删列表）。常见原因：

- `bookmarkCount=0`：书签文件夹名与 `config.json` 的 `browser.bookmarkFolder` 不匹配
- 新书签不在 `added` 且 domain 已存在：被 domain 去重（同 domain 不同 URL 视为同站点）
- 新书签在签到文件夹的子文件夹下：当前 `Walk-BookmarkNodes` 只收集匹配文件夹的直接 url 子节点，不递归子文件夹

### 签到状态语义（v4.9+）

webbridge 站点的签到结果新增 `ALREADY_SIGNED` 信号，与 `SIGN_OK` 区分：

| 信号             | 含义                                   | 报告状态     |
| ---------------- | -------------------------------------- | ------------ |
| `SIGN_OK`        | 本次点击后检测到签到成功               | SUCCESS      |
| `ALREADY_SIGNED` | 今天已签到（无需点击，非本次签到成功） | ALREADY_DONE |

需点击的站点（有 ClickEval）首次检测到 SIGN_OK 即返回 `ALREADY_SIGNED`，避免误把"今天已签到"当"本次签到成功"。访问即签到的站点（无 ClickEval，如 BTSchool）首次 SIGN_OK 仍为真实成功。

### 单站点调试

```powershell
# 加载工具函数
. .\signin-web.ps1

# 单站点调试（保存快照）
Invoke-WebSignIn -SiteName "UBits" -SaveDebugSnapshot $true -DebugDir ".\debug-snapshots"
```

### AI 调试反馈循环

遇到签到失败的站点时，按以下步骤系统性排查（详见 `pt-signin-skill.md` #33）：

1. **收集证据** — 读取 debug 快照 JSON，分析页面实际内容
2. **提出假设** — 至少 3 个可证伪的失败原因假设
3. **定向测试** — 每次只改一个变量，验证假设
4. **修复验证** — 修复后重新运行，确认 SIGN_OK
5. **固化沉淀** — 更新配置、基线、skill 文档

## 常见问题

**Q: 如何添加新的签到站点？**
A: 将站点 URL 加入浏览器的书签文件夹，下次运行时自动同步并分配默认策略。如需特殊策略（如 webbridge），在 `sites.json` 中手动修改。

**Q: webbridge 签到失败？**
A: 检查 daemon 是否运行：`Invoke-RestMethod http://127.0.0.1:10086/command -Method Post -Body '{"action":"snapshot"}'`

**Q: 飞书收不到推送？**
A: 确认 `config.json` 中的 `feishu.webhook` 正确，且 `feishu.enabled` 为 `true`。

**Q: 如何更换浏览器？**
A: 修改 `config.json` 中的 `browser.userDataPath`，指向新浏览器的 User Data 目录。

**Q: 签到结果不准确？**
A: 检查 `signin-log.json` 查看站点级信号。用 `.\signin-single.ps1 -SiteName "站点名"` 单步调试。

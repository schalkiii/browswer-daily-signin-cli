---
name: pt-signin
description: |
  使用 kimi webbridge（单一后端）自动化 PT（私人种子站）及论坛签到。
  涵盖 NexusPHP attendance.php 站点、Cloudflare Turnstile 绕过、点击签到页面、
  SPA 控制台站点和人工站点。当用户要求 PT 站点签到、论坛签到、
  或自动化私人种子站每日签到时使用此技能。
updated: 2026-07-05 (v4.12.3 — extension 冷启动等待 + HDKYL chrome-error 检测 + UNKNOWN 重试改进)
---

# PT 站点签到自动化

## 快速开始

```powershell
cd d:\workspace\browswer-daily-signin-cli

# 全量批处理: 41 个 webbridge 站点 + 11 个人工站点, 约 15-25 分钟
.\signin-batch.ps1
```

## 覆盖范围 (v4.10.1+ — 单 webbridge 后端)

| 类别                            | 数量   | 描述                       |
| ------------------------------- | ------ | -------------------------- |
| webbridge (NexusPHP attendance) | 15     | 访问即签到 (Click=$null)   |
| webbridge (JS 点击签到)         | 17     | 点击按钮 + 重检（论坛/PT） |
| webbridge (SPA 控制台)          | 9      | 登录态保持即视为成功       |
| webbridge (仅访问)              | 7      | 纯浏览类站点，不检测签到   |
| webbridge (特殊 URL)            | 1      | 13City (attendance.php)    |
| manual（验证码/政策原因）       | 4      | 需人工交互                 |
| **总计**                        | **52** | 全部书签站点均尝试         |

### sites.json 字段定义

| 字段           | 必填 | 说明                                                                   |
| -------------- | ---- | ---------------------------------------------------------------------- |
| `name`         | 是   | 站点主键（5 处依赖：WebSignInConfigs/baseline/fail_sites/single/快照） |
| `url`          | 是   | 签到页面 URL                                                           |
| `strategy`     | 是   | `webbridge` 或 `manual`                                                |
| `display_name` | 否   | 展示名（飞书推送/日志），缺失时回退到 `name`。Sync-Bookmarks 自动提取  |
| `note`         | 否   | 同步状态/变更说明                                                      |

**核心规则：尝试书签文件夹中的全部站点，而非仅尝试曾经成功过的。**
以基线（`baseline.json`）为参考，判断哪些站点*理应*成功 — 基线站点失败 = 真实 bug。不在基线中的站点是探索机会。

## 核心架构 (v3.3)

### 目录与文件清理规范

每次批处理运行前，工作目录中**仅应存在以下文件**：

| 文件                    | 用途                                                 | 保留？ |
| ----------------------- | ---------------------------------------------------- | ------ |
| `signin-batch.ps1`      | 主批处理脚本                                         | 是     |
| `signin-single.ps1`     | 单站点调试工具                                       | 是     |
| `signin-web.ps1`        | **站点签到固化模块**（webbridge 各站点配置）         | 是     |
| `kimi-webbridge.ps1`    | **WebBridge API 封装**（HTTP 操控 kimi 浏览器）      | 是     |
| `scan-bookmarks.ps1`    | 书签扫描器                                           | 是     |
| `config.example.json`   | **配置模板**（脱敏版，供用户复制为 config.json）     | 是     |
| `config.json`           | **本地配置**（含私密 webhook，在 .gitignore 中排除） | 本地   |
| `sites.json`            | 站点配置                                             | 是     |
| `baseline.json`         | 已知成功站点                                         | 是     |
| `iterations.json`       | 自迭代日志（运行时，.gitignore 排除）                | 运行时 |
| `signin-log.json`       | 每次运行结果日志（运行时，.gitignore 排除）          | 运行时 |
| `sync-log.json`         | 书签同步日志（运行时，.gitignore 排除）              | 运行时 |
| `.gitignore`            | Git 忽略规则                                         | 是     |
| `pt-signin-skill.md`    | 技能文档（英文）                                     | 是     |
| `pt-signin-skill-cn.md` | 技能文档（中文）                                     | 是     |

所有调试/临时脚本（`debug-browser*.ps1`、`fix-encoding.ps1`、`test-browser.ps1`、`check-syntax.ps1`）必须在稳定化后删除。批处理脚本会在每次运行开始时自动清理 `web-articles/`。

### JSON BOM 容错

PowerShell 的 `ConvertFrom-Json` 遇到 UTF-8 BOM（`\uFEFF`）会解析失败。**每次**解析 JSON 前必须剥离 BOM：

```powershell
$configRaw = Get-Content $ConfigFile -Raw -Encoding UTF8
$configRaw = $configRaw -replace '^\uFEFF', ''
$config = $configRaw | ConvertFrom-Json
```

此规则适用于 `sites.json` 和 `iterations.json` 的所有读取点。

### 检测策略: 浏览器原生 JS 信号

```javascript
// 核心突破: JS 在浏览器内运行 → UTF-8 原生处理 → 返回 ASCII 信号给 PowerShell
(function () {
  var t = document.body.innerText || "";
  // 所有中文比较在浏览器内完成, 不在 PowerShell 中
  if (t.indexOf("签到成功") > -1 || t.indexOf("簽到成功") > -1)
    return "SIGN_OK";
  if (
    t.indexOf("签到已得") > -1 ||
    t.indexOf("簽到已得") > -1 ||
    t.indexOf("签到得") > -1 ||
    t.indexOf("簽到得") > -1
  )
    return "SIGN_OK";
  if (t.indexOf("已签到") > -1 || t.indexOf("已簽到") > -1) return "SIGN_OK";
  if (t.indexOf("这是您的第") > -1 || t.indexOf("這是您的第") > -1)
    return "SIGN_OK";
  if (t.indexOf("签到获得") > -1 || t.indexOf("簽到獲得") > -1)
    return "SIGN_OK";
  if (t.indexOf("每日登录奖励已领取") > -1) return "SIGN_OK";
  if (t.indexOf("Already checked") > -1) return "SIGN_OK";
  if (t.indexOf("打卡成功") > -1 || t.indexOf("已完成") > -1) return "SIGN_OK";
  if (t.indexOf("签到领奖") > -1) return "SIGN_OK";
  if (t.indexOf("签到完成") > -1) return "SIGN_OK";
  if (t.indexOf("连续签到") > -1) return "SIGN_OK";
  if (t.indexOf("获得奖励") > -1 || t.indexOf("獲得獎勵") > -1)
    return "SIGN_OK";
  if (
    t.indexOf("cf-turnstile") > -1 ||
    t.indexOf("challenges.cloudflare") > -1 ||
    t.indexOf("安全驗證") > -1 ||
    t.indexOf("安全验证") > -1
  )
    return "CF_CHALLENGE";
  if (t.indexOf("请稍候") > -1) return "WAITING";
  if (t.indexOf("滑动") > -1 || t.indexOf("拖动滑块") > -1) return "SLIDER";
  if (t.indexOf("请登录") > -1 || t.indexOf("必須登录") > -1)
    return "LOGIN_REQUIRED";
  if (t.indexOf("欢迎回来") > -1 || t.indexOf("歡迎回來") > -1)
    return "LOGGED_IN";
  return "UNKNOWN";
})();
```

**为什么这样设计**: PowerShell 的 `Out-String` 和重定向操作符会损坏 UTF-8 中文字符（产生乱码）。通过在浏览器内通过 `opencli browser eval` 执行检测，中文比较使用浏览器的原生 UTF-8 处理能力，返回 ASCII 字符串信号（"SIGN_OK"、"CF_CHALLENGE" 等），PowerShell 可以正确地正则匹配，不会出现编码损坏。

### 信号语义

| 信号             | 含义                           | 处理方式             |
| ---------------- | ------------------------------ | -------------------- |
| `SIGN_OK`        | 签到成功或今日已签             | 报告 SUCCESS         |
| `CF_CHALLENGE`   | Cloudflare Turnstile/JS 验证页 | 等 20s, 重试 eval    |
| `WAITING`        | 页面显示"请稍候"（加载中）     | 给予更多时间         |
| `SLIDER`         | 检测到滑动验证码               | 需要 API 绕过（D类） |
| `LOGIN_REQUIRED` | 未登录, 显示登录页             | 跳过, 需手动重新登录 |
| `LOGGED_IN`      | 已登录但未检测到签到动作       | 标记待调查           |
| `UNKNOWN`        | 未匹配以上任何模式             | 等 20s 后重试        |

### 策略矩阵 (v4.10 — 单 webbridge 后端)

v4.10 起所有非 manual 站点统一走 `webbridge` strategy。差异化由 `signin-web.ps1` 中的 `Detect`/`Click` JS 模板决定：

| 配置类型            | Detect                  | Click   | 信号流                                    | 站点数 |
| ------------------- | ----------------------- | ------- | ----------------------------------------- | ------ |
| NexusPHP attendance | `$NexusPHPSignInDetect` | `$null` | 访问 → SIGN_OK = 真实签到                 | 16     |
| JS 点击签到         | 站点特定 JS             | 站点 JS | 访问 → NEED_SIGN → 点击 → SIGN_OK/ALREADY | 17     |
| SPA 控制台          | `$SPASignInDetect`      | `$null` | 访问 → 登录态保持 = SIGN_OK               | 10     |
| visit-only          | `$null`                 | `$null` | 访问 → VISITED（不检测）                  | 7      |
| 特殊 URL            | 站点特定 JS             | `$null` | 13City usercp.php                         | 1      |
| manual              | 不适用                  | 不适用  | 跳过                                      | 4      |

**重试策略**：CF_BLOCKED / SLIDER_FAIL / PAGE_ERROR / NO_DETECT / TIMEOUT 最多重试 2 次，间隔 10s。

## 基线追踪 (v3.5)

### 目的

基线（`baseline.json`）记录每个**曾经成功过**的自动化签到站点。它有两个关键作用：

1. **回归检测**：基线中的站点如果失败 → 说明出现了**真正的 bug**（CF 升级、站点结构变更、Token 过期），必须立即诊断并修复。
2. **发现追踪**：不在基线中的站点如果成功 → 这是**新的成功**，基线会增量更新以包含它。

### 文件格式

```json
{
  "version": "v3.5",
  "sites": ["GGPT", "V2EX", "UBits", ...],
  "manual_sites": ["52pojie", "北洋园PT"],
  "auto_total": 24,
  "last_updated": "2026-05-24 10:00:00"
}
```

### 规则

| 场景                  | 处理方式                     |
| --------------------- | ---------------------------- |
| 站点成功 + 在基线中   | 正常，无需处理               |
| 站点成功 + 不在基线中 | **庆祝** — 加入基线，计数 +1 |
| 站点失败 + 在基线中   | **警报** — 回归，必须修复    |
| 站点失败 + 不在基线中 | **探索** — 下次尝试不同策略  |
| 人工站点              | 在基线计算中忽略             |

### 飞书报告格式 (v3.5+)

```
[PASS] PT Sign-in Report
Time: 2026-05-24 10:15:00
Total: 51 sites | Baseline: 24
Auto: 30/49 OK | 19 FAIL (19 new) | Manual: 2 SKIP | 15.3min
[NEW] +6 site(s) added to baseline: HDKYL, PigGo, Srvfi, ...
[REGR] 1 baseline site(s) failed: UBits
```

报告展示：

- **Total vs Baseline**：追踪了多少站点 vs 已成功过多少
- **FAIL (N new)**：失败中，有多少是探索性的（预期不成功）
- **[NEW]**：今日首次成功的站点
- **[REGR]**：基线站点意外失败（最高优先级）

### 不变式

> **每次运行尝试全部书签站点。基线是活的参考，永远不是过滤器。不要因为站点不在基线中就跳过它。每次失败都是一次调试机会。**

## 站点分类与策略

### A 类: NexusPHP `attendance.php`（web-read）

此类站点在页面加载时自动签到。`opencli web read` 使用浏览器 cookies — 无需交互。

**模式**: `https://<site>/attendance.php`
**策略**: `web-read`
**站点**: GGPT、YHPP、海棠PT、HDVideo、xloli、HDClone、Moment、Tokyo、NicePT、RailgunPT

### B 类: 需要 JS 触发的签到（browser-open）

此类站点需要 JS 执行来触发或检测签到结果。`opencli web read` 仅获取页面源码，不运行 JS。

**策略**: `browser-open` — 打开真实浏览器，运行 JS 检测，支持重试

**无 CF 站点**: HDDolby、SBPT、HHCLUB、13City、HDCITY、DepthStudio、PTLAO、音乐乌托邦、HDBao
**有 CF 站点**: UBits、OurBits、HDHome（需 12s 等待 + note 字段含 "CF"）

### C 类: Cloudflare Turnstile

opencli 浏览器复用用户的 Chrome/Edge Profile（路径在 `config.json → browser` 中配置），携带已有的 CF 信任令牌。通过 `opencli browser` 打开站点在大多数情况下会自动通过 Turnstile。

**关键发现 (v3)**: CF 站点需要至少 12s 来完成 Turnstile 自动通过。始终在 eval 前检查 `readyState`。

**CF 失败（CF_CHALLENGE 信号）**: 等待 8s 后重试 eval。如果仍为 CF，标记为 `CF_BLOCKED`。

### D 类: 滑动验证码绕过（browser-eval）

当滑动验证码阻塞页面时，从页面 JS 源码中提取验证 API 并直接调用。**注意**: API Token 哈希可能过期；出现 SLIDER 信号时需要重新提取。

**示例**（FreeFarm / pt.0ff.cc）:

```bash
# 1. 打开页面, 检查滑块 JS 源码
opencli browser <s> open "https://pt.0ff.cc/attendance.php"
opencli browser <s> eval "fetch(document.querySelector('script[src*=slide]').src).then(r=>r.text())"

# 2. 在输出中找到 set_access_token URL
#    模式: "https://pt.0ff.cc/set_access_token-<hash>"

# 3. 调用 Token API 绕过滑块
opencli browser <s> eval "fetch('TOKEN_URL').then(()=>setTimeout(()=>location.reload(),2000))"

# 4. 等待 8s, 然后检测签到
opencli browser <s> eval "$checkJS"
```

### E 类: 点击签到（browser-eval-click）

需要在专用签到页面上点击按钮来完成每日签到的站点。点击触发页面刷新/跳转；之后运行检测。

**模式**: 访问签到页 → 通过 JS 查找目标按钮 → 点击 → 等待 → 检测结果
**策略**: `browser-eval-click`
**站点**: 远景论坛、Rousi、InvitesFun

> **注**: V2EX、52pojie、NodeSeek 原属此类，已在 v3.9 切换为 webbridge（G 类），CF 绕过更稳定。

**关键设计原则（v3.6+）**:

1. **按钮选择器必须精确匹配实际 DOM**：不同站点按钮标签不同（`<a>`、`<button>`、`<input>`），JS 脚本必须使用正确的选择器。例如远景论坛使用 `<button class="check-in">` 而非 `<a>`。
2. **检测模式覆盖点击后的成功文本**：点击签到后页面显示的文本（如"签到完成"）必须在 Test-SignIn 中有对应检测模式。
3. **优先用 class/ID 选择器，再做全遍历降级**：`document.querySelector('button.check-in')` 优先，`document.querySelectorAll('button')` 遍历作为降级。

**V2EX 配置示例**:

```json
{
  "name": "V2EX",
  "url": "https://www.v2ex.com/mission/daily",
  "strategy": "browser-eval-click",
  "eval": "(function(){var t=document.body.innerText||'';if(t.indexOf('\\u6BCF\\u65E5\\u767B\\u5F55\\u5956\\u52B1\\u5DF2\\u9886\\u53D6')>-1)return'SIGN_OK';var b=document.querySelector('.super.normal.button');if(b&&b.value.indexOf('\\u9886\\u53D6')>-1){b.click();return'CLICKED'}return'UNKNOWN';})()",
  "note": "访问 /mission/daily 点击领取按钮签到，页面自动跳转验证"
}
```

**远景论坛配置示例（v3.7 修复）**:

```json
{
  "name": "远景论坛",
  "url": "https://bbs.pcbeta.com/",
  "strategy": "browser-eval-click",
  "eval": "(function(){var t=document.body.innerText||'';if(t.indexOf('签到成功')>-1||t.indexOf('签到完成')>-1||t.indexOf('已签到')>-1||t.indexOf('签到领奖')>-1)return'SIGN_OK';var b=document.querySelector('button.check-in');if(b){b.click();return'CLICKED'}var all=document.querySelectorAll('button');for(var i=0;i<all.length;i++){var v=all[i].textContent||'';if(v.indexOf('每日签到')>-1){all[i].click();return'CLICKED'}}return'NO_BTN'})()",
  "note": "右上角<button class='check-in'>每日签到</button> 按钮点击签到"
}
```

**经验教训**: 远景论坛原 JS 仅查询 `<a>` 标签，实际签到按钮为 `<button class="check-in">`，导致点击失败。修复后先精确匹配 `button.check-in`，再遍历所有 `<button>` 查找"每日签到"文本。

eval JS 做两件事：

1. 首先检查页面是否已显示"每日登录奖励已领取"（已领取）→ `SIGN_OK`
2. 否则找到 value 含"领取"的按钮并点击 → `CLICKED`

点击后脚本等待 5s，然后运行检测 JS，识别"每日登录奖励已领取"文本。

### F 类: 人工站点

由于技术或政策原因无法自动化的站点：

| 站点       | 原因                                                             |
| ---------- | ---------------------------------------------------------------- |
| 北洋园PT   | 图片识别验证码：需选择与影视名称对应的图片。当前工具无法自动化。 |
| 兜总PT签到 | 灰度测试站点，URL 不稳定，暂设为 manual。                        |

### G 类: Kimi WebBridge 签到（browser-open + webbridge）

使用 kimi webbridge 操控用户真实浏览器完成签到，替代 opencli 浏览器扩展。核心优势：

- **CF 完美绕过**：真实浏览器环境，Cloudflare Turnstile 自动通过，零挑战
- **环境检测免疫**：非自动化工具，站点无法检测到异常环境
- **登录状态保留**：使用用户真实的 kimi 浏览器 Profile，无需额外登录（除首次）
- **流程固化可重放**：每个站点的 detect/click JS 代码经过调试验证，固化在 `signin-web.ps1` 中

#### 架构

```
signin-batch.ps1（主调度）
    → sites.json note 字段含 "webbridge"
        → signin-web.ps1（站点固化配置：URL + detect JS + click JS）
            → kimi-webbridge.ps1（HTTP API 封装）
                → http://127.0.0.1:10086/command（kimi 浏览器 daemon）
```

#### kimi-webbridge.ps1 核心函数

```powershell
# 基础 API 调用
function Invoke-WebBridgeCommand {
    param(
        [string]$Action,       # navigate / evaluate / click / close_session
        [hashtable]$CmdArgs,   # 操作参数
        [string]$Session,      # 会话隔离
        [int]$TimeoutSec = 30
    )
}

# 标准化签到流程
function Test-WebBridgeSignIn {
    param(
        [string]$SiteName,
        [string]$Url,
        [string]$DetectEval,   # 签到状态检测 JS
        [string]$ClickEval,    # 签到按钮点击 JS
        [int]$WaitMs,          # 页面加载等待
        [int]$PostClickWaitMs  # 点击后等待
    )
    # 流程: navigate → wait → detect → [click] → re-check → close
}
```

#### signin-web.ps1 站点配置示例

```powershell
$WebSignInConfigs = @{
    "52pojie" = @{
        Url = "https://www.52pojie.cn/forum.php"
        WaitMs = 8000
        PostClickMs = 5000
        Detect = @'
(function(){
  var btn = document.querySelector('button.custom-function-button.check-in');
  if(btn){
    var txt = (btn.textContent||'').trim();
    if(txt.indexOf('今日已签到')>-1) return 'SIGN_OK';
    if(txt==='每日签到') return 'NEED_SIGN';
  }
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var btn = document.querySelector('button.custom-function-button.check-in');
  if(btn){ btn.click(); return 'CLICKED'; }
  return 'NO_BTN';
})()
'@
    }

    "FreeFarm" = @{
        Url = "https://hdfans.org"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = @'
(function(){
  var t = document.body.innerText||'';
  if(t.indexOf('签到已得')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1) return 'NEED_SIGN';
  return 'UNKNOWN';
})()
'@
        Click = @'
// 遍历 b/font/a 标签查找"签到得魔力"并点击
(function(){
  var bolds = document.querySelectorAll('b');
  for(var i=0;i<bolds.length;i++){
    if((bolds[i].textContent||'').trim().indexOf('签到得魔力')>-1){
      bolds[i].click(); return 'CLICKED_B';
    }
  }
  return 'NO_BTN';
})()
'@
    }
}
```

#### 站点调试验证结果

| 站点         | 信号             | 关键发现                                                               |
| ------------ | ---------------- | ---------------------------------------------------------------------- |
| **52pojie**  | `SIGN_OK`        | `button.custom-function-button.check-in` → NEED_SIGN → CLICK → SIGN_OK |
| **FreeFarm** | `SIGN_OK`        | hdfans.org 通过 kimi 浏览器访问，CF 零挑战                             |
| **HDKYL**    | `SIGN_OK`        | attendance.php 页面自动签到                                            |
| **V2EX**     | `SIGN_OK`        | 导航至 `/mission/daily`，检测已领取                                    |
| **NodeSeek** | `LOGIN_REQUIRED` | kimi 浏览器未登录，信号正确返回，飞书报告提醒                          |
| **PigGo**    | `NO_CONFIG`      | 死站（超时不可达），返回 SKIPPED                                       |

#### webbridge 签到调试流程

```powershell
# 1. 验证 daemon 运行
Invoke-RestMethod "http://127.0.0.1:10086/command" -Method Post -Body '{"action":"snapshot"}' -TimeoutSec 5

# 2. 导航到目标站点
Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{url="https://hdfans.org"; newTab=$true} -Session "debug"

# 3. 检测签到状态
Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{code=$detectJS} -Session "debug"

# 4. 点击签到按钮（如需）
Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{code=$clickJS} -Session "debug"

# 5. 再次检测
Start-Sleep 5
Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{code=$detectJS} -Session "debug"
```

## Eval 模式（JS 代码片段）

```javascript
// === 签到检测（主要，用于批处理脚本） ===
(function () {
  var t = document.body.innerText || "";
  if (t.indexOf("签到成功") > -1 || t.indexOf("簽到成功") > -1)
    return "SIGN_OK";
  if (
    t.indexOf("签到已得") > -1 ||
    t.indexOf("簽到已得") > -1 ||
    t.indexOf("签到得") > -1 ||
    t.indexOf("簽到得") > -1
  )
    return "SIGN_OK";
  if (t.indexOf("已签到") > -1 || t.indexOf("已簽到") > -1) return "SIGN_OK";
  if (t.indexOf("这是您的第") > -1 || t.indexOf("這是您的第") > -1)
    return "SIGN_OK";
  if (t.indexOf("签到获得") > -1 || t.indexOf("簽到獲得") > -1)
    return "SIGN_OK";
  if (t.indexOf("每日登录奖励已领取") > -1) return "SIGN_OK";
  if (t.indexOf("Already checked") > -1) return "SIGN_OK";
  if (t.indexOf("打卡成功") > -1 || t.indexOf("已完成") > -1) return "SIGN_OK";
  if (t.indexOf("签到领奖") > -1) return "SIGN_OK";
  if (t.indexOf("签到完成") > -1) return "SIGN_OK";
  if (t.indexOf("连续签到") > -1) return "SIGN_OK";
  if (t.indexOf("获得奖励") > -1 || t.indexOf("獲得獎勵") > -1)
    return "SIGN_OK";
  if (
    t.indexOf("cf-turnstile") > -1 ||
    t.indexOf("challenges.cloudflare") > -1 ||
    t.indexOf("安全驗證") > -1 ||
    t.indexOf("安全验证") > -1
  )
    return "CF_CHALLENGE";
  if (t.indexOf("请稍候") > -1) return "WAITING";
  if (t.indexOf("滑动") > -1 || t.indexOf("拖动滑块") > -1) return "SLIDER";
  if (t.indexOf("请登录") > -1 || t.indexOf("必須登录") > -1)
    return "LOGIN_REQUIRED";
  if (t.indexOf("欢迎回来") > -1 || t.indexOf("歡迎回來") > -1)
    return "LOGGED_IN";
  return "UNKNOWN";
})()(
  // === 页面就绪检查 ===
  function () {
    return document.readyState || "unknown";
  },
)()(
  // === 页面内容快照（前800字符，用于诊断） ===
  function () {
    var t = document.body.innerText || "";
    return t.substring(0, 800).replace(/[\r\n]+/g, "\\n");
  },
)();

// === 查找页面上的签到链接 ===
JSON.stringify(
  Array.from(document.querySelectorAll("a"))
    .filter(
      (a) => a.textContent.includes("签到") || a.textContent.includes("簽到"),
    )
    .map((a) => ({ text: a.textContent.trim(), href: a.href })),
);

// === 提取滑块 JS 源码 ===
fetch(document.querySelector('script[src*="slide"]').src).then((r) => r.text());

// === 调用 SET_ACCESS_TOKEN 绕过滑块 ===
fetch("TOKEN_URL").then(() => setTimeout(() => location.reload(), 2000));

// === V2EX 点击签到（browser-eval-click） ===
(function () {
  var t = document.body.innerText || "";
  if (t.indexOf("每日登录奖励已领取") > -1) return "SIGN_OK";
  var b = document.querySelector(".super.normal.button");
  if (b && b.value.indexOf("领取") > -1) {
    b.click();
    return "CLICKED";
  }
  return "UNKNOWN";
})();
```

## 诊断驱动稳定性规则

### 规则 1: 不要信任 CF 站点的 6 秒等待

CF Turnstile 自动通过需要至少 12s。`note` 字段含 "CF" 的站点默认为 12s。始终在 eval 前通过 `readyState` 轮询验证。

### 规则 2: UNKNOWN/CF_CHALLENGE 时始终重试

8 秒重试可修复约 80% 的间歇性失败。在批处理运行期间，由于顺序会话间的浏览器资源争用，页面加载较慢。

### 规则 3: 非确定性仍可调试

50% 的不稳定性（例如 OurBits 间歇性返回 UNKNOWN）通过适当的检测手段是可以调试的。页面就绪轮询 + 重试将成功率提升至接近 100%。

### 规则 4: PowerShell 的 UTF-8 处理有缺陷 — 绕过它

绝不在 PowerShell 中比较中文字符串。始终通过 `opencli browser eval` 在浏览器内执行 JS 并返回 ASCII 字符串。PowerShell 的 `Out-String` 和 `>` 重定向会损坏 GBK/UTF-8 多字节字符。

**补充（v3.7.2 — 编码全链路修复）**：

PowerShell 在 Windows 中文系统上存在三个关键编码边界问题：

| 边界                | 问题                                                                                | 修复                                                                                                                                |
| ------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **子进程输出捕获**  | `opencli`（Node.js）输出 UTF-8，PowerShell 用 GBK 解码 → 乱码写入 `iterations.json` | 脚本开头设置 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`                                                             |
| **HTTP 请求体编码** | `Invoke-RestMethod` 发送字符串 body 时使用系统默认编码（GBK）→ 飞书收到后中文变 `?` | 将 body 转为 UTF-8 字节数组：`[System.Text.Encoding]::UTF8.GetBytes($body)`，并设置 `Content-Type: application/json; charset=utf-8` |
| **JSON 文件 BOM**   | `Out-File -Encoding UTF8` 写入 BOM → `ConvertFrom-Json` 解析失败                    | 解析前剥离 BOM：`-replace '^\uFEFF', ''`（已在规则中）                                                                              |

```powershell
# 脚本开头（必须在所有 opencli 调用之前）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 飞书推送（必须使用字节数组）
$body = @{ msg_type = "text"; content = @{ text = $text } } | ConvertTo-Json -Depth 3 -Compress
$utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$result = Invoke-RestMethod -Uri $Webhook -Method Post -ContentType "application/json; charset=utf-8" -Body $utf8Bytes -TimeoutSec 10
```

### 规则 5: 一次只改一个变量

调试时：先改等待时间，再加重试，再加轮询。同时改多个东西会让人搞不清到底是哪个修复起的作用。

### 规则 6: FreeFarm Token 是临时的

`set_access_token` 哈希周期性变化。脚本透明处理：SLIDER_FAIL → 自动提取 → 应用 → 重试。不再需要手动重新提取。

### 规则 7: Web-read 可能悄无声息地变成 CF

曾经用 `opencli web read` 能正常工作的站点可能后续添加 Cloudflare JS Challenge。回退机制会捕获此情况并记录变更，以便更新策略。

### 规则 8: UNKNOWN 不总是时序问题

模式发现通过提取页面内容来区分"页面未加载"和"页面已加载但模式库中缺少新的签到文本"。

### 规则 9: 每次签到运行都是一次调试机会

PT 站点每天只能签到一次。每次运行都必须视为高价值的调试会话：

**运行前检查清单**：

- 查看上次运行的 `signin-log.json`，检查失败或异常
- 检查 `iterations.json`，查看自迭代变更需审核
- 确保工作目录仅有核心文件（见规则 13）

**运行中**：

- 发现新站点 → 立即添加到配置并选择合适的策略，同一次运行中测试
- 任何失败 → 诊断根因、修复代码、重新验证修复逻辑
- 成功的策略 → 固化为代码和技能文档中的可复用模式

**运行后动作**（每次运行，无例外）：

- 生成区分自动/人工的详细签到报告
- 将报告推送到飞书 Webhook
- 清理工作目录中的临时调试文件
- 用新的模式、修复或方法学改进更新技能文档
- 将所有英文变更同步到中文技能文档

### 规则 10: 将操作固化为代码 — 而非指令

调试过程中识别的每一个手动操作，都必须转化为自动化代码路径。技能文档描述代码**做了什么**；代码**自动完成**具体操作。

**固化示例**：
| 手动操作 | 自动化代码路径 |
| ---------------------- | ----------------------------------------------- |
| "手动点击按钮" | `browser-eval-click` 策略 + JS 点击逻辑 |
| "为此站点调整等待时间" | 含 CF 标志的站点级 `note` 触发更长等待 |
| "重新提取 API Token" | `Invoke-FreeFarmTokenRefresh` 函数 + 自动检测 |
| "处理 JSON 中的 BOM" | 在所有 `ConvertFrom-Json` 调用点剥离 BOM |
| "报告中区分自动/人工" | 摘要逻辑中使用 `$autoTotal = $total - $skipped` |

**反模式**：在技能文档中保留手动操作步骤却没有对应的代码自动化。每一个手动步骤都是潜在的 bug。

### 规则 11: 人工跳过不算失败

标记为 `manual` 策略的站点是有意排除自动化的。它们永远不应该：

- 导致 PASS 信号为 `False`
- 在报告中被计为失败
- 触发自迭代调试

退出码 = 0 当且仅当 `fail_sites.Count == 0`，与 `skip_sites.Count` 无关。全部自动化站点成功时飞书报告显示 `[PASS]`。

### 规则 12: 报告清晰区分自动化/人工

所有报告（控制台、JSON、飞书）必须区分：

- **自动化站点**：实际尝试签到的站点（web-read、browser-open、browser-eval、browser-eval-click）
- **人工站点**：有意跳过的站点（manual 策略）

报告格式：`总计: 51 | 成功: N | 失败: M | 跳过: 2 | 基线: K` — 区分自动化/人工，使用 emoji 标记。

### 规则 13: 目录清理防止残留状态导致的 bug

每个稳定化周期后清理工作目录。删除所有调试/临时脚本。批处理脚本在每次运行时自动清理 `web-articles/`。干净的目录确保没有残留数据干扰下一次运行。

**v3.7 改进**：批处理脚本末尾增加清理逻辑，确保每次运行结束后 `web-articles/` 自动清空，不再依赖下次运行的启动清理。

### 规则 14: 论坛点击签到适配原则（v3.6+）

### 规则 15: iterations.json 必须是扁平数组（v3.7.1）

`iterations.json` 在多次写入后可能出现嵌套结构：外层 `{"value": [...], "Count": N}` 包裹实际记录。PowerShell 的 `ConvertTo-Json` 在处理混合类型对象时很容易产生这种问题。

**症状**：

- `foreach ($it in $Summary.iteration_log)` 遍历外层对象而非记录 → iterCounts 结果为 0
- `$it.action` 为 null → `++` 运算符报 "仅适用于数字" 异常

**修复**：

1. **代码层**（`signin-batch.ps1`）：遍历时跳过 null action，强转为 `[int]` 再递增
2. **数据层**（`iterations.json`）：定期检测嵌套，用 PowerShell 展平：`if ($item.value) { $flat += $item.value } else { $flat += $item }`
3. **预防**：每次写入 `iterations.json` 后验证顶层元素是否直接有 `site`/`action` 字段

非 PT 论坛站点（如 52pojie、远景论坛、Rousi、NodeSeek）的签到机制各不相同，适配时必须遵循以下流程：

1. **先手动探索确认按钮**：用 `opencli browser open` 打开站点，在浏览器中手动定位签到按钮，确认确切标签（`<a>`、`<button>`、`<input>`）和 class/id。
2. **获取点击后成功文本**：手动点击签到按钮后，查看页面显示的签到成功文本，将其编码为 `\uXXXX` 添加至检测模式库。
3. **编写三阶段 JS 脚本**：
   - 阶段1：检查是否已签到（如页面显示"已签到"/"签到完成"）→ `SIGN_OK`
   - 阶段2：精确定位按钮并点击 → `CLICKED`
   - 阶段3：遍历降级查找（未找到精确匹配时）→ `CLICKED` 或 `NO_BTN`
4. **同步更新 Test-SignIn**：确保点击签到后的成功文本在 `$checkJS` 中转义为 `\uXXXX` 格式。
5. **注意登录状态**：部分论坛（如 NodeSeek）需要保持登录态，若检测到 `LOGIN_REQUIRED` 需排查 Cookie 过期问题。

## 书签提取

Edge 书签存储在 `C:\...\Edge\User Data\Default\Bookmarks`（JSON 格式）。路径通过 `config.json → browser.userDataPath` + `browser.profilePath` 配置。提取 PT 文件夹 URL：

```powershell
$bm = Get-Content "$UserDataDir\$ProfilePath\Bookmarks" -Raw -Encoding UTF8 | ConvertFrom-Json
function Get-AllUrls($node, $prefix) {
    $urls = @()
    if ($node.children) {
        foreach ($c in $node.children) {
            $path = if ($prefix) { "$prefix/$($c.name)" } else { $c.name }
            if ($c.type -eq "folder") { $urls += Get-AllUrls $c $path }
            elseif ($c.type -eq "url") { $urls += [PSCustomObject]@{ Path=$prefix; Name=$c.name; Url=$c.url } }
        }
    }
    return $urls
}
$ptUrls = (Get-AllUrls $bm.roots.bookmark_bar "") | Where-Object { $_.Path -match "PT/签到" }
```

当前书签分类：

| 类别         | 数量 | 占比 |
| ------------ | ---- | ---- |
| 可自动化签到 | 30   | 59%  |
| 人工签到     | 1    | 2%   |
| CF/WAF 拦截  | 7    | 14%  |
| 非签到 URL   | 13   | 25%  |

## 飞书推送（Webhook）

```json
// 在 config.json 中配置:
"feishu": {
  "webhook": "https://open.feishu.cn/open-apis/bot/v2/hook/xxx",
  "enabled": true
}
```

或通过命令行: `.\signin-batch.ps1 -FeishuWebhook "https://open.feishu.cn/..."`

**推送格式**（v3.8+ 使用 `msg_type: interactive` 卡片消息）:

```
┌──────────────────────────────────────────┐
│ ✅ PT 签到报告                  ← 彩色标题栏 │  (green = 全通, red = 有失败)
├──────────────────────────────────────────┤
│ 📊 总计 51 站 | 基线 28 | ⏱ 18.8min       │
│ 🟢 成功 28/50 | 🔴 失败 22 | ⏭ 跳过 1    │
│ 🆕 新基线: +1 (Yemapt)                    │
├──────────────────────────────────────────┤
│ 🟢 签到成功 (28)                          │
│ GGPT, V2EX, UBits, HDHome, ...           │
├──────────────────────────────────────────┤
│ 🔴 签到失败 (22)                          │
│ 🚫 CF拦截 (3): DreamingTree, PigGo, ...  │
│ ❓ 无响应 (6): FearNoPeer, HDVbits, ...   │
│ 🔍 未识别 (11): BTSchool, M-Team, ...    │
│ ❌ 其他 (2): 52pojie, NodeSeek            │
├──────────────────────────────────────────┤
│ ⏭ 人工签到 (1)                           │
│ 北洋园PT                                  │
├──────────────────────────────────────────┤
│ 🔄 自迭代: 12 次 (Token刷新×11, 模式探测×1)│
├──────────────────────────────────────────┤
│ 📅 2026-05-26 09:00:44 | signin-log.json  │  ← 脚注
└──────────────────────────────────────────┘
```

卡片元素结构：

- `header`: 绿色（全部成功）或红色（有失败）标题栏
- `div` + `lark_md`: 各分区使用 Markdown 格式化文本
- `hr`: 分区之间水平分割线
- `note`: 底部时间戳脚注

仅 webhook 路径支持卡片；lark-cli 路径保持纯文本兼容。

**分组说明**：

| Emoji | 分组     | 说明                                  |
| ----- | -------- | ------------------------------------- |
| ✅    | 总体状态 | 全部自动化通过→✅；任何失败→⚠️        |
| 🟢    | 签到成功 | 全部成功站点（含新基线站点）          |
| 🔴    | 签到失败 | 按原因细分：CF拦截/无响应/未识别/其他 |
| 🚫    | CF拦截   | Cloudflare Turnstile/JS Challenge     |
| ❓    | 无响应   | 服务器不响应或返回空内容              |
| 🔍    | 未识别   | 页面加载但签到状态无法确认            |
| ❌    | 其他     | 未归类失败                            |
| ⏭    | 人工签到 | manual 策略站点                       |
| 🆕    | 新基线   | 本次新成功的站点                      |
| 🚨    | 基线回归 | 基线站点意外失败                      |
| 🔄    | 自迭代   | 本次运行的自修复次数                  |

## 自迭代机制 (v3.2+)

脚本在运行时自动检测和修复常见故障模式：

### 1. Token 自动刷新（browser-eval）

FreeFarm 的滑动验证 Token 过期时（SLIDER_FAIL 信号）：

- 从页面 `<script>` 标签中提取新的 `slide_check_*.js` URL
- 抓取 JS 源码，用正则提取新的 `set_access_token-XXX` URL
- 用新的 eval 命令更新 `sites.json`
- 重新执行绕过并重新检测签到
- 将变更记录到 `iterations.json`

### 2. Web-Read 回退

web-read 站点返回 NO_ARTICLE 或 TOO_SMALL 时：

- 通过浏览器打开页面，检查是否迁移到 CF 保护或需要 JS
- 如果检测到 CF，记录发现并建议策略变更
- 如果页面正常加载，通过浏览器 eval 运行签到检测
- 成功后报告为 ITER_FIX

### 3. 模式发现（browser-open UNKNOWN）

browser-open 站点返回 UNKNOWN 或 NO_DETECT 时：

- 提取页面文本内容（前 800 字符）
- 在内容中搜索已知的签到模式
- 如果找到了签到文本但检测遗漏了，记录漏报告警
- 将发现记录到 `iterations.json` 供审查

### 迭代日志

所有变更记录在 `iterations.json` 中：

```json
[
  {
    "timestamp": "2026-05-22 08:30:00",
    "site": "FreeFarm",
    "action": "token_refresh",
    "oldToken": "fetch('https://pt.0ff.cc/set_access_token-OLD...')...",
    "newToken": "fetch('https://pt.0ff.cc/set_access_token-NEW...')..."
  }
]
```

## 完整执行工作流 (v3.5+)

每次签到会话必须遵循此完整工作流。不可跳过任何步骤。

### 阶段 1: 准备

1. 查看上次运行的 `signin-log.json` — 检查失败或异常
2. 查看 `iterations.json` — 检查自上次运行以来的自迭代变更
3. 查看 `baseline.json` — 了解哪些站点预期会成功
4. 验证工作目录仅有目录清理规范中列出的 10 个核心文件
5. 确保 `sites.json` 在解析前已剥离 BOM
6. **关键**：不要按基线筛选站点。尝试全部 51 个站点。

### 阶段 2: 执行

7. 运行 `.\signin-batch.ps1` — 按顺序处理全部 51 个站点
8. 脚本在启动时自动清理 `web-articles/`，运行中生成新的文章目录
9. 自迭代在失败时触发：Token 刷新、web-read 回退、模式发现
10. 每个站点结果与基线对照，检测回归/新成功
11. 所有变更记录到 `iterations.json` 作为审计跟踪

### 阶段 3: 报告（必须）

12. 脚本自动生成 `signin-log.json`，包含每个站点的完整结果
13. 脚本自动推送飞书报告，包含：
    - 自动/人工/新站/回归 分离
    - Total vs Baseline 对比
    - [NEW] 和 [REGR] 部分（如适用）
14. 控制台显示 PASS/FAIL 信号 + 基线统计

### 阶段 4: 清理与同步（必须）

15. 删除工作目录中的所有临时调试脚本
16. 验证目录仅包含目录清理规范中列出的 10 个核心文件
17. 如果基线新增了站点，验证 `baseline.json` 已自动更新
18. 审查任何回归 — 计划下次运行的修复方案
19. 用新的模式、修复或经验教训更新 `pt-signin-skill.md`
20. 同步 `pt-signin-skill-cn.md` 以完全匹配所有英文变更
21. 确认两份技能文档版本号和更新日期一致

### 退出码约定

| 退出码 | 含义                               |
| ------ | ---------------------------------- |
| `0`    | 全部自动化站点通过（忽略人工跳过） |
| `1`    | 一个或多个自动化站点失败           |

## 故障排除

| 问题                                        | 解决方案                                                                             |
| ------------------------------------------- | ------------------------------------------------------------------------------------ |
| `web read` 显示登录页                       | Cookies 已过期。在浏览器配置文件中手动重新登录。                                     |
| 页面显示 CF 挑战（"安全验证" / Turnstile）  | 等待时间增加到 12s，启用重试。确保 `note` 字段含 "CF"。                              |
| 信号为 "UNKNOWN"                            | 页面未完全加载。等待 8s 后重试。检查 `readyState`。                                  |
| 滑动验证码页面                              | 从 `<script src="...slide...">` 提取 JS Token URL，直接调用 `set_access_token` API。 |
| 图片验证码（选择匹配图片）                  | 当前无法自动化。标记为 `manual` 策略。                                               |
| `ERROR_NO_SIGNAL` / null-valued expression  | 浏览器 eval 未返回结果。浏览器可能崩溃或会话已关闭。                                 |
| 飞书推送失败                                | 验证 webhook URL；网络可能拦截 `open.feishu.cn`。检查代理设置。                      |
| 雷池 WAF 页面                               | 需要人工验证一次。通过后，站点可能变为可用。                                         |
| `ConvertFrom-Json` 失败, "无效的 JSON 基元" | 文件开头有 UTF-8 BOM。解析前用 `-replace '^\uFEFF', ''` 剥离。                       |

## 事后总结: 经验教训

1. **从一开始就做页面就绪轮询**: `Wait-PageReady` 模式应成为每个浏览器自动化脚本的默认配置——它消除了最常见的失败模式。
2. **重试优先思维**: 对任何 `UNKNOWN` 或 `CF_CHALLENGE` 信号，自动等待 8s 后重试——几乎总是时序问题，而非逻辑错误。
3. **CF 站点差异化**: Cloudflare 保护的站点比非 CF 站点需要多 50% 的等待时间。这应该从一开始就是站点级可配置参数。
4. **模式库持续扩展**: 每种新的签到变体（"签到得魔力"、"这是您的第N次签到"、"每日登录奖励已领取"）都在扩展检测模式库。维护一个集中的 JS 代码片段。
5. **书签优先盘点**: 始终先提取完整的书签列表。最初的扫描漏掉了 4 个站点，因为 web-read 超时被误解为"不可访问"而非"用浏览器重试"。
6. **BOM 不可见但具破坏性**: UTF-8 BOM（`\uFEFF`）会导致 `ConvertFrom-Json` 静默失败。始终在每个 JSON 读取点剥离 BOM。此规则适用于任何通过 PowerShell 的 `Out-File -Encoding UTF8` 写入 UTF-8 文件的工具。
7. **先点后检模式**: 对需要按钮交互的站点（V2EX），JS eval 应先检查"已完成"，再点击，然后由主检测 JS 确认结果。这种两阶段方法同时处理首次签到和重复运行。
8. **策略选择需考虑政策因素**: 部分站点（52pojie）明确禁止自动化。尊重这些政策：标记为 `manual` 并附带清晰的 `reason` 字段说明为何不尝试自动化。避免浪费调试精力并防止账户风险。
9. **退出码语义很重要**: 人工跳过不算失败 — 退出码和报告的 PASS/FAIL 应仅反映自动化站点结果。将人工和自动化计数混在一起会产生误导性报告，暗示本来不存在的失败。使用 `$autoTotal = $total - $manual` 计算准确比例。
10. **运行后工作流是强制性的**: 每次成功运行必须以以下步骤结束：报告生成 → 飞书推送 → 目录清理 → 技能文档更新 → 中文版同步。跳过任何一步都会使系统处于不完整状态，影响下一次运行。
11. **基线是参考，不是过滤器**: 不要因为站点不在基线中就跳过它。每次运行尝试全部 51 个站点。基线的作用是检测回归，而不是削减测试集。
12. **基线增量增长是目标**: 每个首次成功的站点都是胜利。基线应单调增长 — 庆祝每次新增并记录到 `baseline.json`。
13. **回归是最高优先级的 bug**: 基线中的站点如果失败，意味着某些东西坏了（CF 升级、Token 过期、登录失效）。必须在下次运行前诊断并修复。在飞书中显著报告 `[REGR]`。
14. **探索性失败是正常的**: 尚未加入基线的新站点首次尝试很可能会失败。这些是发现机会，不是 bug。报告为 `FAIL (N new)` 以区别于回归。

15. **iterations.json 结构会悄然损坏**: PowerShell 的 `ConvertTo-Json` 在追加混合类型条目时，极易将扁平数组扭曲为嵌套结构。v3.7.1 修复同时从代码层（遍历时空安全）和数据层（定期展平）双管齐下。永远不要信任 PowerShell 产出的 JSON 结构是扁平的——每次追加写入后都应验证顶层键的存在性与类型。

16. **失败站点必须分类分析才能系统化改进**: v3.7.1 失败站点可分为五类——(a) 服务器关闭/连接中断，(b) 404/站点消失，(c) CF/WAF 拦截，(d) 登录失效/需要重新登录，(e) 页面空/无内容。每一类对应不同处理策略：a→跳过等待恢复，b→标记为疑似下线，c→增加12s等待/复用信任Token，d→排查Cookie过期，e→调整策略为browser-open。统一报告格式为飞书推送提供可读的细分数据。

17. **webbridge 优于 opencli 浏览器扩展（v3.9）**: kimi webbridge 操控用户真实浏览器，CF/WAF 完美绕过（零挑战），站点不会检测到环境异常。对于 opencli 浏览器扩展被 CF 拦截或返回 UNKNOWN 的站点，应优先切换到 webbridge。每个站点需要单独调试验证其 detect/click JS 代码，然后固化到 `signin-web.ps1` 中确保流程可稳定重放。新增 webbridge 站点的调试流程：navigate → wait → detect → [click] → re-check → close_session。`Invoke-WebBridgeCommand` 必须使用显式命名参数（`-Action`、`-CmdArgs`、`-Session`），位置参数会导致参数类型冲突（`$Args` 与 PowerShell 自动变量冲突）。

18. **Cloudflare Managed Challenge 需转为 manual（v4.5）**: UBits 在 2026-06-20 启用 Cloudflare 托管挑战（Managed Challenge），页面显示"正在进行安全验证"并包含 CF 安全质询 iframe，webbridge 等待 30 秒后仍无法自动通过。
    - **诊断**: webbridge navigate 后，snapshot 显示标题为"请稍候…"，页面内容包含"正在进行安全验证"和"包含 Cloudflare 安全质询的小组件"
    - **与 CF Turnstile 的区别**: CF Turnstile 是自动化的 JavaScript 挑战，webbridge 可以自动通过；Managed Challenge 需要人机交互（如点击"我不是机器人"），webbridge 无法绕过
    - **修复**:
      1. `sites.json`: strategy 从 `browser-open` 改为 `manual`，note 记录"2026-06-20: 站点启用Cloudflare托管挑战（需人机交互验证），webbridge无法绕过，改为手动"
      2. `baseline.json`: 将 UBits 从 `sites` 移到 `manual_sites`，auto_total 41，manual_total 4
    - **关键区别**: CF Turnstile（自动通过）vs CF Managed Challenge（需人机交互）。前者 webbridge 可以处理，后者必须转为 manual。

19. **SPA 站点人机验证需转为 manual（v4.6）**: Yemapt 在 2026-06-22 持续返回 NEED_SIGN 即使点击"立即签到"按钮后仍无法变更状态。
    - **诊断**: webbridge navigate 到 `https://www.yemapt.org/#/consumer/checkIn` 后，detect 返回 NEED_SIGN，click 返回 CLICKED:立即签到，但 re-check 仍为 NEED_SIGN。历史记录显示该站点为 SPA 架构，6月2日曾出现"人机验证加载中"。
    - **根因**: SPA 站点的签到逻辑可能依赖异步 API 调用，点击后需要额外等待或存在前端验证机制；webbridge 的点击事件可能未触发实际的签到请求
    - **修复**:
      1. `sites.json`: strategy 从 `browser-open` 改为 `manual`，note 记录"2026-06-22: SPA站点且有人机验证加载中，webbridge点击签到后状态未变更，无法自动化，改为手动"
      2. `baseline.json`: 将 Yemapt 从 `sites` 移到 `manual_sites`，auto_total 40，manual_total 5
    - **经验**: SPA 站点（尤其是带人机验证的）自动化难度大，当多次尝试（包括增加等待时间、重试）仍失败后，应果断转为 manual 避免浪费每日签到机会。

20. **EVAL_FAIL tab 丢失自动恢复（v4.10.1+）**: webbridge daemon 存在间歇性 bug：navigate 返回 success=true 但 tab 在 WaitMs 等待期间消失，导致后续 evaluate 报 `session "daily-signin" has no tab`。
    - **症状**: 全量签到中多个站点（SBPT/onrender/ptlao/huan666/HTCPT/BTSchool/DepthStudio）报 EVAL_FAIL，单站点重测却 SIGN_OK，说明是非确定性问题
    - **修复**: `Test-WebBridgeSignIn` 在 evaluate 失败时（$detect 为 null），自动 close_tab + navigate + evaluate 一次重试。重试成功则继续正常流程，重试仍失败才返回 EVAL_FAIL
    - **验证**: 修复后全量签到 AUTO_OK 从 29 提升至 34，5 个原 EVAL_FAIL 站点全部 SIGN_OK
    - **关键**: 间歇性 bug 必须加重试逻辑，单次失败不应直接判失败

21. **HHCLUB 方括号按钮匹配（v4.10.1+）**: HHCLUB 签到按钮文本为 `[签到得憨豆]`（带方括号包裹），与常规 NexusPHP 按钮 `签到得魔力`/`签到得鲸币` 格式不同。
    - **诊断**: debug 快照显示按钮是 `<A href="...attendance.php">[签到得憨豆]</A>`，detect 匹配到的是描述文本"签到获得10个憨豆"而非按钮文本
    - **修复**: Click JS 增加 `v.replace(/^\[|\]$/g,'')` 去方括号后再匹配；Detect 加入 `签到得憨豆`/`已领取`/`本次签到获得` 关键词
    - **经验**: 不同 PT 站点的按钮文本格式可能差异很大（方括号、圆括号、emoji 等），Click JS 应先规范化文本再匹配

22. **re-check evaluate 超时需大于 click 后页面重载时间（v4.10.1+）**: 点击签到按钮后页面可能跳转/重载，tab 在重载期间暂时不可用，re-check evaluate 15s 超时不够。
    - **症状**: HHCLUB click 成功（CLICKED_EXACT），但 re-check evaluate 超时报 HttpClient.Timeout
    - **修复**: re-check evaluate TimeoutSec 从 15 增至 30，给页面重载足够时间
    - **经验**: click → re-check 之间应有充足等待（PostClickMs）+ re-check 超时（≥30s），以应对页面重载

23. **PowerShell 5.x vs 7.x 编码差异（v4.10.1+）**: PowerShell 5.x (powershell.exe) 按 GBK 读取无 BOM 的 .ps1 文件，中文字符被破坏；PowerShell 7.x (pwsh.exe) 默认按 UTF-8 读取，正确处理中文。
    - **症状**: powershell.exe 运行 kimi-webbridge.ps1 报 "daemon 鍚姩鎴愬姛"（中文"启动成功"被 GBK 解码破坏）
    - **修复**: 所有脚本验证和签到执行改用 pwsh（`pwsh -NoProfile -File signin-batch.ps1`）
    - **附加**: PowerShell 5.x 解析 here-string `'@` 结束符要求 CRLF；LF 结尾会导致 here-string 无法正确终止。git core.autocrlf=true 在 checkout 时会转 CRLF，但 Edit/Write 工具用 LF 写入工作区文件，可能导致 here-string 解析失败
    - **经验**: 含中文的 PowerShell 脚本必须用 pwsh 7.x 运行；here-string 必须保持 CRLF 行结束符

24. **展示名与主键名分离（v4.11.0）**: 站点配置中 `name` 字段作为 5 处主键依赖（WebSignInConfigs 查找、baseline.json 比对、fail_sites 去重、signin-single 查找、debug 快照文件名），不可随意修改。新增 `display_name` 字段作为纯展示层，缺失时回退到 `name`。
    - **背景**：Sync-Bookmarks 从 URL 域名倒数第二段生成 name（如 `42w`/`pp`/`audiences`），cryptic 不可读
    - **设计**：`display_name` 不参与任何匹配逻辑，仅用于飞书卡片推送和日志展示
    - **经验**：当主键字段被多处依赖时，新增展示字段比修改主键更安全；字段回退逻辑（`if ($dn) { $dn } else { $name }`）保证向后兼容

25. **验证码扩展自动填入方案（v4.12.0）**: 当用户浏览器配备验证码自动输入扩展时，可用 `setInterval` 异步轮询方案让 Click JS 等待扩展填入后再提交。
    - **背景**：vclib/521 等 NexusPHP 站点签到需输入图片验证码（`<input name="imagestring">` + `<img src="image.php?action=regimage">`），v4.10.1 改为 manual。用户反馈浏览器扩展可自动填入
    - **方案**：因 webbridge evaluate 同步执行不支持 Promise/awaitPromise，Click JS 用 `setInterval` 每 1 秒检查 `input.value`，evaluate 立即返回 `CLICK_SCHEDULED`，PostClickMs 期间 setInterval 在浏览器中异步执行
    - **调优**：v4.12.1 将轮询窗口从 12 秒扩到 28 秒，PostClickMs 从 15 秒扩到 30 秒
    - **限制**：521 实测扩展未在 28 秒内填入 imagestring，可能是扩展未在该域名下启用或不支持 NexusPHP 图片验证码格式。需用户确认扩展配置
    - **经验**：异步轮询方案绕过了 evaluate 同步限制，但需要扩展确实在目标域名下工作。设计时应假设扩展可能有域名白名单/格式限制，提供快速失败 + 人工兜底

26. **CF managed challenge 与异地登录 2FA 检测（v4.12.0）**: Detect 应识别"非签到页"的异常状态页面，避免 Click JS 误操作。
    - **CF managed challenge**：title="请稍候…" + bodyText 含"正在进行安全验证"，检测 `.cf-turnstile` / `iframe[src*="challenges.cloudflare.com"]` / `[name="cf-turnstile-response"]` 元素。返回 `CF_CHALLENGE` 信号归入 capSites
    - **异地登录 2FA**：URL 跳转到 `take2fa.php`，bodyText 含"异地登录"/"两步验证"。返回 `LOGIN_REQUIRED` 触发飞书提醒
    - **经验**：Detect 不仅识别"签到状态"，还要识别"页面异常状态"（CF 拦截/2FA/登录失效/服务器错误）。否则 Click JS 在异常页面上误点导航元素，产生难以 debug 的副作用

27. **标签泄漏：close_tab 失败不能静默吞掉（v4.12.2）**: `Test-WebBridgeSignIn` 用单次 `close_tab` 清理 tab，但 extension 断开时 `close_tab` 失败被 `try/catch` 静默吞掉，旧 tab 残留。重试时 `navigate newTab=$true` 创建新 tab，导致同一 URL 累积 2-3 个标签。
    - **根因**：extension 断开时 daemon 返回 `{"ok":false,"error":{"code":"tool_error","message":"no extension connected"}}`，但代码用 `try { close_tab } catch {}` 吞掉了错误
    - **修复**：新增 `Clear-WebBridgeTabs` 函数，用 `list_tabs` 循环检查 + `close_tab` 逐个关闭，最多清理 10 个残留 tab。`Test-WebBridgeSignIn` 中 3 处单次 `close_tab`（开始/evaluate 重试/finally）全部替换
    - **影响**：52pojie/HDClone/HHCLUB 三个站点 NAV_FAIL → 应恢复正常
    - **经验**：tab 管理操作（close_tab/navigate）失败时不能静默吞掉，应该用 `list_tabs` 验证状态并循环清理。单次 close_tab 只关闭当前活跃 tab，如果有多个残留 tab 需要循环关闭

28. **SPA 页面 UNKNOWN 重试（v4.12.2 → v4.12.3 改进）**: SPA 站点（如 Rousi）内容动态渲染，首次 Detect 运行时页面还没加载完，返回 UNKNOWN。
    - **根因**：SPA 框架（Vue/React）的内容是客户端渲染的，navigate 完成后页面 DOM 可能还是空的。WaitMs 12000ms 不够等待 SPA 完全渲染
    - **v4.12.2 修复**：Detect 返回 UNKNOWN 时，等待 3 秒后重新检测一次
    - **v4.12.3 改进**：等待 3 秒重试 1 次不够（Rousi 09:14:59 失败，bodyText 空，`<div id="root"></div>` 未渲染；09:18:48 成功），改为等待 5 秒重试 2 次（共 10 秒）
    - **影响**：Rousi（间歇性 UNKNOWN → 等待后应能成功）
    - **经验**：SPA 站点的 Detect 需要考虑渲染延迟。UNKNOWN 重试比增加 WaitMs 更高效——只对 UNKNOWN 的站点多等，不影响已成功的站点。间歇性问题需要多次重试

29. **extension 冷启动等待（v4.12.3）**: daemon 启动后 extension 需要几秒才连接，首个站点 navigate 时 extension 未就绪，返回 "no extension connected" 导致 NAV_FAIL。
    - **根因**：`Ensure-WebBridgeDaemon` 只检测 daemon 端口监听，不检测 extension 是否已连接。daemon 启动成功 ≠ extension 已就绪
    - **调试证据**：07-05 全量签到 52pojie（首个站点）连续 3 次 navigate 都报 "no extension connected"，但 HDKYL（第 2 个站点）重试时 extension 已连接
    - **修复**：navigate 失败时调用 `list_tabs` 检测 extension 是否就绪，未就绪则等待 5 秒重试，最多 3 次（共 15 秒）
    - **经验**：daemon 和 extension 是两个独立组件，daemon 启动后需要额外等待 extension 连接。首个站点的 NAV_FAIL 应该触发 extension 就绪检测，而非直接判失败

30. **chrome-error 页面检测（v4.12.3）**: 服务器间歇性关闭连接（ERR_CONNECTION_CLOSED），页面跳转到 `chrome-error://chromewebdata/`，Detect 缺少此检测返回 UNKNOWN。
    - **根因**：HDKYL 服务器间歇性关闭连接，浏览器显示 "嗯… 无法访问此页面" + "ERR_CONNECTION_CLOSED"，但 HDKYL 的 Detect 只检测签到关键词，不识别 chrome-error 页面
    - **调试证据**：HDKYL 09:16:54 快照显示 `location.protocol === 'chrome-error:'`，bodyText 含 "无法访问此页面" 和 "ERR_CONNECTION_CLOSED"
    - **修复**：Detect 添加 `location.protocol==='chrome-error:'` + `t.indexOf('无法访问此页面')>-1` + `t.indexOf('ERR_CONNECTION')>-1` 检测，返回 SERVER_ERROR
    - **经验**：Detect 必须覆盖 chrome-error 页面（与 $NexusPHPSignInDetect 一致），否则服务器问题时返回 UNKNOWN 而非 SERVER_ERROR，误导调试。每个站点的独立 Detect 都应包含 chrome-error 检测

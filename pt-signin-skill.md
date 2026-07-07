---
name: pt-signin
description: |
  Automated PT (Private Tracker) and forum site sign-in using kimi webbridge (single backend).
  Covers NexusPHP attendance.php sites, Cloudflare Turnstile bypass, click-to-sign pages,
  SPA console sites, and manual-only sites. Use when user asks to sign in to PT sites, checkin to
  tracker/forum sites, or automate daily attendance for private trackers.
updated: 2026-07-07 (v4.12.6 — CDP Shadow DOM piercing + NexusPHPSignInDetect cfTokenPassed fix + Yemapt ALTCHA adaptation)
---

# PT Site Sign-in Automation

## Quick Start

```powershell
cd d:\workspace\browswer-daily-signin-cli

# Full batch: 42 webbridge + 7 manual sites (~15-20min)
.\signin-batch.ps1
```

## Coverage (v4.12.0 — single webbridge backend)

| Category                        | Count  | Description                                                                    |
| ------------------------------- | ------ | ------------------------------------------------------------------------------ |
| webbridge (NexusPHP attendance) | 15     | Visit = sign-in (Click=$null)                                                  |
| webbridge (JS click sign-in)    | 17     | Click button + re-detect (forums/tracker)                                      |
| webbridge (SPA console)         | 9      | Login state = success (API consoles)                                           |
| webbridge (visit-only)          | 7      | Pure visit, no sign-in detection                                               |
| webbridge (NexusPHP + captcha)  | 2      | Click JS polls imagestring for browser extension to fill (v4.12.0+: vclib/521) |
| manual (captcha / policy)       | 7      | Requires human interaction                                                     |
| **Total**                       | **49** | All bookmark sites attempted                                                   |

**Key Rule: Attempt ALL sites in the bookmark folder, not just previously successful ones.**
Use the baseline (`baseline.json`) as a reference for which sites _should_ succeed — regressions are real bugs. Sites not in baseline are exploratory opportunities.

### sites.json Field Definitions

| Field          | Required | Description                                                                             |
| -------------- | -------- | --------------------------------------------------------------------------------------- |
| `name`         | Yes      | Site primary key (5 deps: WebSignInConfigs/baseline/fail_sites/single/snapshot)         |
| `url`          | Yes      | Sign-in page URL                                                                        |
| `strategy`     | Yes      | `webbridge` or `manual`                                                                 |
| `display_name` | No       | Display name (Feishu push/logs), falls back to `name`. Auto-extracted by Sync-Bookmarks |
| `note`         | No       | Sync status / change notes                                                              |

## Core Architecture (v3.3)

### Directory & File Hygiene

Before every batch run, the working directory must contain **only these files**:

| File                    | Role                                                             | Must Keep? |
| ----------------------- | ---------------------------------------------------------------- | ---------- |
| `signin-batch.ps1`      | Main batch script                                                | Yes        |
| `signin-single.ps1`     | Single-site debug tool                                           | Yes        |
| `signin-web.ps1`        | **Site sign-in hardening** (webbridge per-site configs)          | Yes        |
| `kimi-webbridge.ps1`    | **WebBridge API wrapper** (HTTP control of kimi browser)         | Yes        |
| `scan-bookmarks.ps1`    | Bookmark scanner                                                 | Yes        |
| `config.example.json`   | **Config template** (sanitized, for user to copy as config.json) | Yes        |
| `config.json`           | **Local config** (private webhook, gitignored)                   | Local      |
| `sites.json`            | Site configuration                                               | Yes        |
| `baseline.json`         | Known-success sites                                              | Yes        |
| `iterations.json`       | Self-iteration log (runtime, gitignored)                         | Runtime    |
| `signin-log.json`       | Per-run result log (runtime, gitignored)                         | Runtime    |
| `sync-log.json`         | Bookmark sync log (runtime, gitignored)                          | Runtime    |
| `.gitignore`            | Git ignore rules                                                 | Yes        |
| `pt-signin-skill.md`    | Skill doc (English)                                              | Yes        |
| `pt-signin-skill-cn.md` | Skill doc (Chinese)                                              | Yes        |

All debug/temp scripts (`debug-browser*.ps1`, `fix-encoding.ps1`, `test-browser.ps1`, `check-syntax.ps1`) must be deleted after stabilization. The batch script auto-clears `web-articles/` at the start of each run.

### JSON BOM Resilience

PowerShell's `ConvertFrom-Json` fails on UTF-8 BOM (`\uFEFF`). Always strip BOM before parsing:

```powershell
$configRaw = Get-Content $ConfigFile -Raw -Encoding UTF8
$configRaw = $configRaw -replace '^\uFEFF', ''
$config = $configRaw | ConvertFrom-Json
```

This applies to both `sites.json` and `iterations.json` reads.

### Detection Strategy: Browser-Native JS Signal

```javascript
// KEY INSIGHT: JS runs inside browser → UTF-8 handled natively → returns ASCII signal to PowerShell
(function () {
  var t = document.body.innerText || "";
  // All Chinese comparison happens in the browser, NOT in PowerShell
  if (t.indexOf("签到成功") > -1 || t.indexOf("簽到成功") > -1)
    return "SIGN_OK";
  if (t.indexOf("签到已得") > -1 || t.indexOf("簽到已得") > -1)
    return "SIGN_OK";
  if (t.indexOf("已签到") > -1 || t.indexOf("已簽到") > -1) return "SIGN_OK";
  if (t.indexOf("这是您的第") > -1 || t.indexOf("這是您的第") > -1)
    return "SIGN_OK";
  if (t.indexOf("签到获得") > -1 || t.indexOf("簽到獲得") > -1)
    return "SIGN_OK";
  if (t.indexOf("每日登录奖励已领取") > -1) return "SIGN_OK";
  if (t.indexOf("Already checked") > -1) return "SIGN_OK";
  if (t.indexOf("打卡成功") > -1) return "SIGN_OK";
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

**Why this works**: PowerShell's `Out-String` and redirect operators corrupt UTF-8 Chinese characters into mojibake. By evaluating the check inside the browser via `opencli browser eval`, the comparison uses the browser's native UTF-8 handling and returns ASCII string signals ("SIGN_OK", "CF_CHALLENGE", etc.) that PowerShell can correctly regex-match without corruption.

### Signal Semantics

| Signal           | Meaning                                  | Action                       |
| ---------------- | ---------------------------------------- | ---------------------------- |
| `SIGN_OK`        | Sign-in succeeded (click → recheck OK)   | Report SUCCESS               |
| `ALREADY_SIGNED` | Already signed today (no click this run) | Report ALREADY_DONE          |
| `CF_CHALLENGE`   | Cloudflare Turnstile/JS challenge page   | Wait 8s, retry eval          |
| `WAITING`        | Page says "please wait" (loading)        | Allow more time              |
| `SLIDER`         | Slider captcha detected                  | Need API bypass (Category D) |
| `LOGIN_REQUIRED` | Not logged in, shows login page          | Skip, needs manual re-login  |
| `LOGGED_IN`      | Logged in but no sign-in action detected | Flag for investigation       |
| `UNKNOWN`        | None of the above patterns matched       | Retry after 8s               |

### Strategy Matrix (v4.10 — single webbridge backend)

v4.10 起所有非 manual 站点统一走 `webbridge` strategy。差异化由 `signin-web.ps1` 中的 `Detect`/`Click` JS 模板决定：

| Config Type         | Detect                  | Click   | Signal Flow                                 | Count |
| ------------------- | ----------------------- | ------- | ------------------------------------------- | ----- |
| NexusPHP attendance | `$NexusPHPSignInDetect` | `$null` | visit → SIGN_OK = real sign-in              | 16    |
| JS click sign-in    | site-specific JS        | site JS | visit → NEED_SIGN → click → SIGN_OK/ALREADY | 17    |
| SPA console         | `$SPASignInDetect`      | `$null` | visit → login state = SIGN_OK               | 10    |
| visit-only          | `$null`                 | `$null` | visit → VISITED (no detect)                 | 7     |
| special URL         | site-specific JS        | `$null` | 13City usercp.php                           | 1     |
| manual              | N/A                     | N/A     | skipped                                     | 4     |

**Retry Policy**: CF_BLOCKED / SLIDER_FAIL / PAGE_ERROR / NO_DETECT / TIMEOUT 最多重试 2 次，间隔 10s。

## Baseline Tracking (v3.5)

### Purpose

The baseline (`baseline.json`) records every site that has **ever succeeded** in automated sign-in. It serves two critical roles:

1. **Regression Detection**: If a site in the baseline fails → it's a **real bug** (e.g., CF upgrade, site structure change, token expiry). These must be investigated and resolved immediately.
2. **Discovery Tracking**: If a site NOT in the baseline succeeds → it's a **new success**, and the baseline is incrementally updated to include it.

### File Format

```json
{
  "version": "v3.5",
  "sites": ["GGPT", "V2EX", "UBits", ...],
  "manual_sites": ["52pojie", "北洋园PT"],
  "auto_total": 24,
  "last_updated": "2026-05-24 10:00:00"
}
```

### Rules

| Scenario                        | Action                                           |
| ------------------------------- | ------------------------------------------------ |
| Site succeeds + in baseline     | Nothing (normal operation)                       |
| Site succeeds + NOT in baseline | **Celebrate** — add to baseline, increment count |
| Site fails + in baseline        | **ALARM** — regression detected, fix required    |
| Site fails + NOT in baseline    | **Explore** — try different strategy next run    |
| Manual site                     | Ignored in baseline calculations                 |

### Feishu Report Format (v3.5+)

```
[PASS] PT Sign-in Report
Time: 2026-05-24 10:15:00
Total: 51 sites | Baseline: 24
Auto: 30/49 OK | 19 FAIL (19 new) | Manual: 2 SKIP | 15.3min
[NEW] +6 site(s) added to baseline: HDKYL, PigGo, Srvfi, ...
[REGR] 1 baseline site(s) failed: UBits
```

The report now shows:

- **Total vs Baseline**: how many sites we track vs how many are known-successful
- **FAIL (N new)**: among failures, how many are exploratory (not expected to work yet)
- **[NEW]**: sites that succeeded for the first time today
- **[REGR]**: baseline sites that unexpectedly failed (highest urgency)

### Invariant

> **Every run attempts ALL sites in the bookmark folder. The baseline is a living reference — never a filter. Don't skip sites because they're not in the baseline. Every failure is a debugging opportunity.**

## Site Categories & Strategies

### Category A: NexusPHP `attendance.php` (web-read)

These sites auto-sign-in on page load. `opencli web read` uses browser cookies — no interaction needed.

**Pattern**: `https://<site>/attendance.php`
**Strategy**: `web-read`
**Sites**: GGPT, YHPP, 海棠PT, HDVideo, xloli, HDClone, Moment, Tokyo, NicePT, RailgunPT, HDVideo

```bash
opencli web read --url "https://www.gamegamept.com/attendance.php"
# Article will contain 签到成功 or 签到已得
```

### Category B: JS-triggered Sign-in (browser-open)

These sites require JS execution to trigger or detect the sign-in result. `opencli web read` only fetches the page source without running JS.

**Strategy**: `browser-open` — opens real browser, runs JS detection, supports retry

**Sites without CF**: HDDolby, SBPT, HHCLUB, 13City, HDCITY, DepthStudio, PTLAO, 音乐乌托邦, HDBao
**Sites with CF**: HDHome (need 12s wait + note field contains "CF")

### Category C: Cloudflare Turnstile

The opencli browser reuses the user's Chrome/Edge Profile (path configured in `config.json → browser`), carrying existing CF trust tokens. Opening a site via `opencli browser` auto-passes Turnstile in most cases.

**Key finding (v3)**: CF sites need at least 12s to complete the Turnstile auto-pass. Always check `readyState` before eval.

**Failed CF** (CF_CHALLENGE signal): Wait 8s and retry eval. If still CF, mark as `CF_BLOCKED`.

### Category D: Slider Captcha Bypass (browser-eval)

When a slider captcha blocks the page, extract the verification API from the page's JS source and call it directly. **Warning**: The API token hash may expire; re-extraction needed when SLIDER signal appears.

**Example** (FreeFarm / pt.0ff.cc):

```bash
# 1. Open page, inspect slider JS source
opencli browser <s> open "https://pt.0ff.cc/attendance.php"
opencli browser <s> eval "fetch(document.querySelector('script[src*=slide]').src).then(r=>r.text())"

# 2. Find set_access_token URL in the output
#    Pattern: "https://pt.0ff.cc/set_access_token-<hash>"

# 3. Call the token API to bypass slider
opencli browser <s> eval "fetch('TOKEN_URL').then(()=>setTimeout(()=>location.reload(),2000))"

# 4. Wait 8s, then check sign-in
opencli browser <s> eval "$checkJS"
```

### Category E: Click-to-Sign (browser-eval-click)

Sites that require clicking a button on a dedicated sign-in page to complete the daily check-in. The button click triggers a page refresh/redirect; detection runs afterward.

**Pattern**: Visit sign-in page → find target button via JS → click → wait → detect result
**Strategy**: `browser-eval-click`
**Sites**: 远景论坛 (PCEVA), Rousi

> **Note**: V2EX, 52pojie, NodeSeek, InvitesFun were previously in this category; moved to webbridge (Category G) in v3.9/v4.0.1 for better CF bypass reliability.

**Key design principles (v3.6+)**:

1. **Button selector must match actual DOM exactly**: Different sites use different button tags (`<a>`, `<button>`, `<input>`), JS scripts must use the correct selector. For example, 远景论坛 uses `<button class="check-in">` not `<a>`.
2. **Detection patterns must cover the post-click success text**: The text displayed after clicking (e.g. "签到完成") must have a corresponding detection pattern in Test-SignIn.
3. **Prioritize class/ID selectors, fall back to full traversal**: `document.querySelector('button.check-in')` first, `document.querySelectorAll('button')` traversal as fallback.

**V2EX example**:

```json
{
  "name": "V2EX",
  "url": "https://www.v2ex.com/mission/daily",
  "strategy": "browser-eval-click",
  "eval": "(function(){var t=document.body.innerText||'';if(t.indexOf('\\u6BCF\\u65E5\\u767B\\u5F55\\u5956\\u52B1\\u5DF2\\u9886\\u53D6')>-1)return'SIGN_OK';var b=document.querySelector('.super.normal.button');if(b&&b.value.indexOf('\\u9886\\u53D6')>-1){b.click();return'CLICKED'}return'UNKNOWN';})()",
  "note": "访问 /mission/daily 点击领取按钮签到，页面自动跳转验证"
}
```

**远景论坛 example (v3.7 fix)**:

```json
{
  "name": "远景论坛",
  "url": "https://bbs.pcbeta.com/",
  "strategy": "browser-eval-click",
  "eval": "(function(){var t=document.body.innerText||'';if(t.indexOf('签到成功')>-1||t.indexOf('签到完成')>-1||t.indexOf('已签到')>-1||t.indexOf('签到领奖')>-1)return'SIGN_OK';var b=document.querySelector('button.check-in');if(b){b.click();return'CLICKED'}var all=document.querySelectorAll('button');for(var i=0;i<all.length;i++){var v=all[i].textContent||'';if(v.indexOf('每日签到')>-1){all[i].click();return'CLICKED'}}return'NO_BTN'})()",
  "note": "右上角<button class='check-in'>每日签到</button> 按钮点击签到"
}
```

**Lesson learned**: The original JS for 远景论坛 only queried `<a>` tags, but the actual checkin button is `<button class="check-in">`, causing click failure. Fixed by matching `button.check-in` first, then traversing all `<button>` for "每日签到" text.

The eval JS does two things:

1. First checks if the page already shows "每日登录奖励已领取" (already claimed) → `SIGN_OK`
2. Otherwise finds the button with "领取" in its value and clicks it → `CLICKED`

After click, the script waits 5s then runs detection JS which recognizes the "每日登录奖励已领取" text.

### Category F: Manual Sites

Sites that cannot be automated due to technical or policy reasons:

| Site       | Reason                                                                                                   |
| ---------- | -------------------------------------------------------------------------------------------------------- |
| 北洋园PT   | Image recognition captcha: must select image matching a movie title. Cannot automate with current tools. |
| 兜总PT签到 | Canary/testing site with unstable URL. Kept as manual for now.                                           |

### Category G: Kimi WebBridge Sign-in (browser-open + webbridge)

Uses kimi webbridge to control the user's real browser for sign-in, replacing the opencli browser extension. Core advantages:

- **Perfect CF Bypass**: Real browser environment — Cloudflare Turnstile passes automatically, zero challenges
- **Environment Detection Immune**: Not an automation tool — sites cannot detect anomalous environment
- **Login State Preserved**: Uses the user's actual kimi browser Profile (except first-time login)
- **Hardened Ops, Replayable**: Each site's detect/click JS code is debug-verified and hardened in `signin-web.ps1`

#### Architecture

```
signin-batch.ps1 (scheduler)
    → sites.json note field contains "webbridge"
        → signin-web.ps1 (per-site hardened configs: URL + detect JS + click JS)
            → kimi-webbridge.ps1 (HTTP API wrapper)
                → http://127.0.0.1:10086/command (kimi browser daemon)
```

#### Core Functions (kimi-webbridge.ps1)

```powershell
function Invoke-WebBridgeCommand {
    param([string]$Action, [hashtable]$CmdArgs, [string]$Session, [int]$TimeoutSec)
}

function Test-WebBridgeSignIn {
    param([string]$SiteName, [string]$Url, [string]$DetectEval,
          [string]$ClickEval, [int]$WaitMs, [int]$PostClickWaitMs)
    # Flow: close_tab → navigate → wait → detect → [click] → re-check → close_tab
    # Tab lifecycle: close_tab at start (clean residue) + try/finally close_tab at end
    # State transition: NEED_SIGN → click → SIGN_OK = real success;
    #   first SIGN_OK with ClickEval = ALREADY_SIGNED (already done today)
}
```

#### Verified Webbridge Sites

| Site           | Signal           | Key Finding                                                                |
| -------------- | ---------------- | -------------------------------------------------------------------------- |
| **52pojie**    | `SIGN_OK`        | `button.custom-function-button.check-in` → NEED_SIGN → CLICK → SIGN_OK     |
| **FreeFarm**   | `SIGN_OK`        | hdfans.org via kimi browser, CF zero challenge                             |
| **HDKYL**      | `SIGN_OK`        | attendance.php auto check-in                                               |
| **V2EX**       | `SIGN_OK`        | Navigate to `/mission/daily`, detected as already claimed                  |
| **NodeSeek**   | `LOGIN_REQUIRED` | kimi browser not logged in; signal correctly returned, Feishu report warns |
| **PigGo**      | `SIGN_OK`        | attendance.php with body null guard; fixed v4.0.1                          |
| **InvitesFun** | `SIGN_OK`        | Moved from browser-eval-click (v4.0.1); detects 签到/已签到 via webbridge  |
| **OurBits**    | `SIGN_OK`        | Moved from web-read (v4.0.1); CF bypass via webbridge                      |
| **UBits**      | `SIGN_OK`        | Moved from web-read (v4.0.1); CF bypass via webbridge                      |

## Eval Patterns (JS Snippets)

```javascript
// === SIGN-IN DETECTION (primary, used in batch script) ===
(function () {
  var t = document.body.innerText || "";
  if (t.indexOf("签到成功") > -1 || t.indexOf("簽到成功") > -1)
    return "SIGN_OK";
  if (t.indexOf("签到已得") > -1 || t.indexOf("簽到已得") > -1)
    return "SIGN_OK";
  if (t.indexOf("已签到") > -1 || t.indexOf("已簽到") > -1) return "SIGN_OK";
  if (t.indexOf("这是您的第") > -1 || t.indexOf("這是您的第") > -1)
    return "SIGN_OK";
  if (t.indexOf("签到获得") > -1 || t.indexOf("簽到獲得") > -1)
    return "SIGN_OK";
  if (t.indexOf("每日登录奖励已领取") > -1) return "SIGN_OK";
  if (t.indexOf("Already checked") > -1) return "SIGN_OK";
  if (t.indexOf("打卡成功") > -1) return "SIGN_OK";
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
  // === PAGE-READY CHECK ===
  function () {
    return document.readyState || "unknown";
  },
)()(
  // === PAGE CONTENT DUMP (first 800 chars, for diagnosis) ===
  function () {
    var t = document.body.innerText || "";
    return t.substring(0, 800).replace(/[\r\n]+/g, "\\n");
  },
)();

// === FIND SIGN-IN LINKS ON PAGE ===
JSON.stringify(
  Array.from(document.querySelectorAll("a"))
    .filter(
      (a) => a.textContent.includes("签到") || a.textContent.includes("簽到"),
    )
    .map((a) => ({ text: a.textContent.trim(), href: a.href })),
);

// === EXTRACT SLIDER JS SOURCE ===
fetch(document.querySelector('script[src*="slide"]').src).then((r) => r.text());

// === CALL SET_ACCESS_TOKEN TO BYPASS SLIDER ===
fetch("TOKEN_URL").then(() => setTimeout(() => location.reload(), 2000));

// === V2EX CLICK-TO-SIGN (browser-eval-click) ===
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

## Diagnose-Driven Stability Rules

### Rule 1: Never trust 6-second waits for CF sites

CF Turnstile auto-pass needs 12s minimum. Sites with `note` containing "CF" get 12s by default. Always verify with `readyState` polling before eval.

### Rule 2: Always retry on UNKNOWN/CF_CHALLENGE

An 8-second retry fixes ~80% of intermittent failures. During batch runs, pages load slower due to browser resource contention across sequential sessions.

### Rule 3: Non-deterministic is still debuggable

A 50% flake (e.g., OurBits returning UNKNOWN intermittently) is debuggable with the right instrumentation. Page-ready polling + retry raised success rate to nearly 100%.

### Rule 4: PowerShell UTF-8 is broken — work around it

Never compare Chinese strings in PowerShell. Always evaluate JS in-browser via `opencli browser eval` and return ASCII strings. PowerShell's `Out-String` and `>` redirect corrupt GBK/UTF-8 multibyte characters.

**Addendum (v3.7.2 — Full encoding pipeline fix)**:

PowerShell on Chinese Windows has three critical encoding boundary issues:

| Boundary                       | Problem                                                                                                     | Fix                                                                                                                                   |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Subprocess output capture**  | `opencli` (Node.js) outputs UTF-8, PowerShell decodes as GBK → mojibake in `iterations.json`                | Set `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` at script start                                                        |
| **HTTP request body encoding** | `Invoke-RestMethod` sends string body using system default encoding (GBK) → Feishu receives `?` for Chinese | Convert body to UTF-8 byte array: `[System.Text.Encoding]::UTF8.GetBytes($body)`, set `Content-Type: application/json; charset=utf-8` |
| **JSON file BOM**              | `Out-File -Encoding UTF8` writes BOM → `ConvertFrom-Json` parse failure                                     | Strip BOM before parsing: `-replace '^\uFEFF', ''` (already in rules)                                                                 |

```powershell
# At script start (must be before any opencli calls)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Feishu push (must use byte array)
$body = @{ msg_type = "text"; content = @{ text = $text } } | ConvertTo-Json -Depth 3 -Compress
$utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$result = Invoke-RestMethod -Uri $Webhook -Method Post -ContentType "application/json; charset=utf-8" -Body $utf8Bytes -TimeoutSec 10
```

### Rule 5: One variable at a time

When debugging: change wait time first, then add retry, then add polling. Changing multiple things simultaneously obscures which fix actually worked.

### Rule 6: FreeFarm token is ephemeral

The `set_access_token` hash changes periodically. The script handles this transparently: SLIDER_FAIL → auto-extract → apply → retry. Manual re-extraction is no longer needed.

### Rule 7: Web-read can silently become CF

Sites that used to work with `opencli web read` may later add Cloudflare JS Challenge. The fallback mechanism catches this and logs the change so the strategy can be updated.

### Rule 8: UNKNOWN is not always a timing issue

Pattern discovery extracts page content to distinguish between "page not loaded" vs. "page loaded but new sign-in text not in our pattern library."

### Rule 9: Every sign-in run is a debugging opportunity

PT sites only allow one sign-in per day. Each run must be treated as a high-value debugging session:

**Pre-run checklist**:

- Review last run's `signin-log.json` for failures or anomalies
- Check `iterations.json` for any self-iteration changes that need review
- Ensure working directory has only core files (see Rule 13)

**During run**:

- New sites discovered → add to config with appropriate strategy immediately, test in same run
- Any failure → diagnose root cause, fix code, re-verify the fix logic
- Successful strategies → solidify into reusable patterns in both code and skill doc

**Post-run actions** (every run, no exceptions):

- Generate detailed sign-in report with auto/manual split
- Push report to Feishu webhook
- Clean temporary debug files from working directory
- Update skill doc with any new patterns, fixes, or methodology improvements
- Sync Chinese skill doc with all English changes

### Rule 10: Solidify operations into code — not instructions

Every manual operation identified during debugging must be converted into an automated code path. The skill doc describes WHAT the code does; the code handles HOW it's done automatically.

**Solidification examples**:
| Manual Operation | Automated Code Path |
|------------------|---------------------|
| "Manually click button" | `browser-eval-click` strategy with JS click logic |
| "Adjust wait time for this site" | Per-site `note` with CF flag triggering longer wait |
| "Re-extract API token" | `Invoke-FreeFarmTokenRefresh` function with auto-detection |
| "Handle BOM in JSON" | BOM-stripping at all `ConvertFrom-Json` call sites |
| "Distinguish auto from manual in report" | `$autoTotal = $total - $skipped` in summary logic |

**Anti-pattern**: Leaving a manual workaround in the skill doc without corresponding code automation. Every workaround is a bug waiting to happen.

### Rule 11: Manual skips are not failures

Sites marked as `manual` strategy are intentionally excluded from automation. They should never:

- Cause the PASS signal to be `False`
- Be counted as failures in reports
- Trigger self-iteration debugging

Exit code = 0 if `fail_sites.Count == 0`, regardless of `skip_sites.Count`. The Feishu report shows `[PASS]` when all automated sites succeed.

### Rule 12: Report auto/manual split clearly

All reports (console, JSON, Feishu) must distinguish between:

- **Automated sites**: those actually attempted (web-read, browser-open, browser-eval, browser-eval-click)
- **Manual sites**: intentionally skipped (manual strategy)

Report format: `Auto: X/Y OK | Z FAIL | Manual: W SKIP` — not `X/total OK` which misrepresents manual skips as failures.

### Rule 13: Directory hygiene prevents stale-state bugs

Clean working directory after every stabilization cycle. Remove all debug/temp scripts. The batch script auto-cleans `web-articles/` on each run. A clean directory ensures no stale data interferes with the next run.

**v3.7 improvement**: The batch script now also cleans `web-articles/` at the END of each run (via `Remove-Item` at the tail), not just at the start. This prevents leftover artifacts from accumulating between runs.

### Rule 14: Forum click check-in adaptation (v3.6+)

### Rule 15: iterations.json must be a flat array (v3.7.1)

`iterations.json` can develop nested structures after multiple writes: an outer `{"value": [...], "Count": N}` wrapping actual records. PowerShell's `ConvertTo-Json` is prone to this when dealing with mixed-type objects.

**Symptoms**:

- `foreach ($it in $Summary.iteration_log)` iterates outer objects instead of records → iterCounts shows 0
- `$it.action` is null → `++` operator throws "仅适用于数字" exception

**Fix**:

1. **Code side** (`signin-batch.ps1`): Skip null actions in loop, cast to `[int]` before incrementing
2. **Data side** (`iterations.json`): Periodically detect and flatten: `if ($item.value) { $flat += $item.value } else { $flat += $item }`
3. **Prevention**: After each write to `iterations.json`, verify that top-level elements have direct `site`/`action` fields

Non-PT forum sites (52pojie, 远景论坛, Rousi, NodeSeek, etc.) have diverse check-in mechanisms. Follow this process for each:

1. **Manually explore to confirm the button**: Use `opencli browser open` to open the site, locate the check-in button in the browser, and confirm the exact tag (`<a>`, `<button>`, `<input>`) and class/id.
2. **Capture the post-click success text**: After manually clicking, note the success text displayed on the page. Encode it as `\uXXXX` and add to the detection pattern library.
3. **Write a 3-phase JS script**:
   - Phase 1: Check if already signed in (e.g. "已签到"/"签到完成") → `SIGN_OK`
   - Phase 2: Precisely locate and click the button → `CLICKED`
   - Phase 3: Traversal fallback (if exact match not found) → `CLICKED` or `NO_BTN`
4. **Sync Test-SignIn**: Ensure the post-click success text exists in `$checkJS` as escaped `\uXXXX` format.
5. **Mind login state**: Some forums (e.g. NodeSeek) require persistent login sessions; if `LOGIN_REQUIRED` is detected, investigate cookie expiration.

## Bookmark Extraction

Edge bookmarks stored at `C:\...\Edge\User Data\Default\Bookmarks` (JSON). Path is configured via `config.json → browser.userDataPath` + `browser.profilePath`. Extract PT folder URLs:

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

Current bookmark breakdown:

| Category          | Count | Ratio |
| ----------------- | ----- | ----- |
| Automated sign-in | 30    | 59%   |
| CF/WAF blocked    | 7     | 14%   |
| Non-sign-in URLs  | 13    | 32%   |

## Feishu Push (Webhook)

```json
// In config.json:
"feishu": {
  "webhook": "https://open.feishu.cn/open-apis/bot/v2/hook/xxx",
  "enabled": true
}
```

Or via CLI: `.\signin-batch.ps1 -FeishuWebhook "https://open.feishu.cn/..."`

**Push format** (v3.8+ uses `msg_type: interactive` card message):

```
┌──────────────────────────────────────────┐
│ ✅ PT Sign-in Report       ← color header │  (green = all pass, red = failures)
├──────────────────────────────────────────┤
│ 📊 Total 51 | Baseline 28 | ⏱ 18.8min     │
│ 🟢 OK 28/50 | 🔴 FAIL 22 | ⏭ SKIP 1     │
│ 🆕 New: +1 (Yemapt)                      │
├──────────────────────────────────────────┤
│ 🟢 Sign-in OK (28)                       │
│ GGPT, V2EX, UBits, HDHome, ...           │
├──────────────────────────────────────────┤
│ 🔴 Sign-in Failed (22)                   │
│ 🚫 CF blocked (3): DreamingTree, ...     │
│ ❓ No response (6): FearNoPeer, ...      │
│ 🔍 Not detected (11): BTSchool, ...      │
│ ❌ Other (2): 52pojie, NodeSeek          │
├──────────────────────────────────────────┤
│ ⏭ Manual (1)                            │
│ 北洋园PT                                  │
├──────────────────────────────────────────┤
│ 🔄 Iterations: 12 (Token×11, Pattern×1)  │
├──────────────────────────────────────────┤
│ 📅 2026-05-26 09:00:44 | signin-log.json │  ← footnote
└──────────────────────────────────────────┘
```

Card element structure:

- `header`: Green (all success) or red (failures) color bar
- `div` + `lark_md`: Each section uses Markdown-formatted text
- `hr`: Horizontal dividers between sections
- `note`: Bottom timestamp footnote

Card support is webhook-only; lark-cli path keeps plain text for compatibility.

**Icon legend**:

| Icon | Group        | Meaning                                           |
| ---- | ------------ | ------------------------------------------------- |
| ✅   | Overall      | All automated OK → ✅; any failure → ⚠️           |
| 🟢   | OK sites     | All successful (including new baseline)           |
| 🔴   | FAIL sites   | Grouped by cause: CF/NoResponse/NotDetected/Other |
| 🚫   | CF block     | Cloudflare Turnstile/JS Challenge                 |
| ❓   | No response  | Server unreachable or returned empty              |
| 🔍   | Not detected | Page loaded but checkin status unknown            |
| ❌   | Other        | Unclassified failure                              |
| ⏭   | Manual skip  | Sites with `manual` strategy                      |
| 🆕   | New baseline | Site succeeded for the first time                 |
| 🚨   | Regression   | Baseline site unexpectedly failed                 |
| 🔄   | Iteration    | Auto-fix actions this run                         |

## Self-Iteration (v3.2+)

The script automatically detects and repairs common failure patterns at runtime:

### 1. Auto Token Refresh (browser-eval)

When FreeFarm's slider bypass token expires (SLIDER_FAIL signal):

- Extracts new `slide_check_*.js` URL from page `<script>` tags
- Fetches the JS source and regex-extracts the new `set_access_token-XXX` URL
- Updates `sites.json` with the new eval command
- Re-executes the bypass and re-checks sign-in
- Logs the change to `iterations.json`

### 2. Web-Read Fallback

When a web-read site returns NO_ARTICLE or TOO_SMALL:

- Opens the page via browser to check if it moved behind CF or requires JS
- If CF detected, logs the finding and suggests strategy change
- If page loads normally, runs sign-in detection via browser eval
- On success, reports as ITER_FIX

### 3. Pattern Discovery (browser-open UNKNOWN)

When a browser-open site returns UNKNOWN or NO_DETECT:

- Extracts page text content (first 800 chars)
- Searches for known sign-in patterns in the content
- If sign-in text found but detection missed it, logs a false-negative alert
- Records findings to `iterations.json` for review

### Iteration Log

All changes are recorded in `iterations.json`:

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

## Full Execution Workflow (v3.5+)

Every sign-in session must follow this complete workflow. No step may be skipped.

### Phase 1: Preparation

1. Review `signin-log.json` from last run — check for failures or anomalies
2. Review `iterations.json` — check self-iteration changes since last run
3. Review `baseline.json` — know which sites are expected to succeed
4. Verify working directory has only the 10 core files listed in Directory Hygiene
5. Ensure `sites.json` BOM is stripped before parsing
6. **CRITICAL**: Do NOT filter sites by baseline. Attempt ALL 49 sites.

### Phase 2: Execution

7. Run `.\signin-batch.ps1` — processes all 49 sites sequentially
8. Script auto-cleans `web-articles/` at start, generates fresh articles during run
9. Self-iteration fires on failures: token refresh, web-read fallback, pattern discovery
10. Each site result is tracked against baseline for regression/new-success detection
11. All changes logged to `iterations.json` for audit trail

### Phase 3: Reporting (mandatory)

12. Script auto-generates `signin-log.json` with full per-site results
13. Script auto-pushes Feishu report with:
    - Auto/manual/new/regression split
    - Total vs baseline comparison
    - [NEW] and [REGR] sections when applicable
14. Console shows PASS/FAIL signal + baseline stats

### Phase 4: Cleanup & Sync (mandatory)

15. Delete all temporary debug scripts from working directory
16. Verify directory contains only the 10 core files listed in Directory Hygiene
17. If baseline gained new sites, verify `baseline.json` was auto-updated
18. Review any regressions — plan fixes for next run
19. Update `pt-signin-skill.md` with new patterns, fixes, or lessons learned
20. Sync `pt-signin-skill-cn.md` to match all English changes exactly
21. Confirm both skill docs have the same version number and update date

### Exit Code Contract

| Exit Code | Meaning                                           |
| --------- | ------------------------------------------------- |
| `0`       | All automated sites passed (manual skips ignored) |
| `1`       | One or more automated sites failed                |

## Troubleshooting

| Problem                                          | Solution                                                                                      |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| `web read` shows login page                      | Cookies expired. Re-login manually in the browser profile.                                    |
| Page shows CF challenge ("安全验证" / Turnstile) | Increase wait to 12s, enable retry. Ensure `note` field has "CF".                             |
| Signal is "UNKNOWN"                              | Page not fully loaded. Retry after 8s. Check `readyState`.                                    |
| Slider captcha page                              | Extract JS token URL from `<script src="...slide...">`, call `set_access_token` API directly. |
| Image captcha (select matching picture)          | Cannot automate currently. Mark as `manual` strategy.                                         |
| `ERROR_NO_SIGNAL` / null-valued expression       | Browser eval returned nothing. Browser may have crashed or session was closed.                |
| `BODY_NULL` / PAGE_ERROR (webbridge)             | Page document.body is null after WaitMs — error page or interstitial. Check URL validity.     |
| `EVAL_FAIL` (webbridge)                          | JS evaluate crashed (e.g. `document.body.innerText` on null body). Add null guard in detect.  |
| Feishu push fails                                | Verify webhook URL; network may block `open.feishu.cn`. Check proxy settings.                 |
| Leichi WAF page                                  | Requires human verification once. After passing, site may become usable.                      |
| `ConvertFrom-Json` fails with "无效的 JSON 基元" | UTF-8 BOM at file start. Strip with `-replace '^\uFEFF', ''` before parsing.                  |

## Post-Mortem: Lessons Learned

1. **Page-ready polling from day one**: The `Wait-PageReady` pattern should be a default in every browser automation script — it eliminates the most common failure mode.
2. **Retry-first mindset**: For any `UNKNOWN` or `CF_CHALLENGE` signal, automatically wait 8s and retry — it's almost always a timing problem, not a logic error.
3. **CF site differentiation**: Sites behind Cloudflare need 50% more wait time than non-CF sites. This should be a per-site configurable parameter from the start.
4. **Pattern library expansion**: Each new sign-in variant ("签到得魔力", "这是您的第N次签到", "每日登录奖励已领取") expands the detection pattern library. Maintain a centralized JS snippet.
5. **Bookmark-first inventory**: Always extract the full bookmark list first. The original scan missed 4 sites because web-read timeout was interpreted as "inaccessible" rather than "retry with browser".
6. **BOM is invisible but destructive**: UTF-8 BOM (`\uFEFF`) causes `ConvertFrom-Json` to fail silently. Always strip BOM at every JSON read site. This applies to any tool that writes UTF-8 files via PowerShell's `Out-File -Encoding UTF8`.
7. **Click-then-detect pattern**: For sites requiring button interaction (V2EX), the JS eval should first check "already done", then click, then let the main detection JS confirm the result. This two-phase approach handles both fresh sign-ins and re-runs.
8. **Policy-aware strategy selection**: Some sites (52pojie) explicitly prohibit automation. Respect these policies: mark as `manual` with a clear `reason` field explaining why automation is not attempted. This prevents wasted debugging effort and potential account issues.
9. **Exit code semantics matter**: Manual skips are not failures — the exit code and report PASS/FAIL should only reflect automated site results. Mixing manual and automated counts produces misleading reports that suggest failures where none exist. Use `$autoTotal = $total - $manual` for accurate ratios.
10. **Running post-run workflow is mandatory**: every successful run must end with: report generation → Feishu push → directory cleanup → skill doc update → Chinese sync. Skipping any step leaves the system in an incomplete state for the next run.
11. **Baseline is a reference, never a filter**: Never skip sites because they are not in the baseline. Attempt ALL 49 sites every run. The baseline exists to detect regressions, not to reduce the test set.
12. **Incremental baseline growth is the goal**: Each new site that succeeds for the first time is a victory. The baseline should grow monotonically — celebrate each addition and record it in `baseline.json`.
13. **Regression is the highest-priority bug**: If a site in the baseline fails, it means something broke (CF upgrade, token expiry, login session lost). These must be diagnosed and fixed before the next run. Report `[REGR]` prominently in Feishu.
14. **Exploratory failures are normal**: New sites not yet in the baseline will likely fail on first attempt. These are discovery opportunities, not bugs. Report them as `FAIL (N new)` to distinguish from regressions.

15. **iterations.json structure silently corrupts**: PowerShell's `ConvertTo-Json` is highly prone to warping a flat array into a nested structure when appending mixed-type entries. The v3.7.1 fix addresses this from both the code side (null-safe iteration + `[int]` cast) and the data side (periodic flattening). Never trust PowerShell-emitted JSON to remain flat — verify top-level keys after every append.

16. **Failure sites must be taxonomized for systematic improvement**: v3.7.1 failures fall into five categories — (a) server down/connection closed, (b) 404/site gone, (c) CF/WAF blocked, (d) login required/session expired, (e) page empty/no content. Each category maps to a different action: a→skip & wait for recovery, b→flag as potentially offline, c→increase wait to 12s/reuse trust tokens, d→investigate cookie expiry, e→switch to browser-open strategy. Categorized reporting in Feishu provides actionable data.

17. **webbridge beats opencli browser extension (v3.9)**: kimi webbridge controls the user's real browser — CF/WAF is perfectly bypassed (zero challenges), and sites never detect an anomalous environment. For any site where the opencli browser extension is CF-blocked or returns UNKNOWN, prefer switching to webbridge. Each site needs individual debug-verification of its detect/click JS code, then hardening into `signin-web.ps1` to ensure stable replayability. The debug flow for new webbridge sites: navigate → wait → detect → [click] → re-check → close_session. `Invoke-WebBridgeCommand` must use explicit named parameters (`-Action`, `-CmdArgs`, `-Session`) — positional arguments cause parameter type conflicts (`$Args` collides with PowerShell's automatic variable).

18. **Always guard document.body access in detect JS (v4.0.1)**: `document.body` can be null when the page is still loading, is an interstitial page, or has an error. The JS expression `document.body.innerText||''` throws `TypeError: Cannot read properties of null` when body is null. Fix: `var t = document.body ? document.body.innerText : '';`. This applies to both detect and click JS functions. Returning `BODY_NULL` from detect JS is a valid signal that should be handled without crashing.

19. **BODY_NULL is a terminal signal**: When a page has no body element after the configured WaitMs, it's not a timing issue — the page is likely in an error state, a redirect, or a pre-render state that won't resolve. Return `BODY_NULL` immediately without attempting click. The webbridge switch in `signin-batch.ps1` reports it as `PAGE_ERROR` for diagnosis.

20. **web-read → webbridge migration is the preferred fix for CF-blocked sites (v4.0.1)**: When a web-read site starts returning CF_DETECTED and the fallback browser-open also fails, the correct fix is to switch the site to webbridge strategy. This requires: (a) adding a `$WebSignInConfigs` entry in `signin-web.ps1` with detect/click JS, (b) changing strategy to `browser-open` in `sites.json` with `"webbridge"` in the note field, and (c) removing any `eval` field from the site config. The webbridge detect JS should follow the same pattern as other PT attendance pages: check CF/slider first, then sign-in status, then login status.

21. **Site closure detection and graceful degradation (v4.2 → v4.3)**: Not all regressions are fixable — some sites simply close or become permanently unavailable.
    - **2026-06-09**: BTSchool 返回 HTTP 404，Musopia 返回"当前无法使用此页面"，FreeFarm 滑块拦截。
    - **2026-06-10**: BTSchool 持续返回 REDIRECTING（webbridge 多次重试均失败），确认站点已关闭。执行以下降级：
      1. `sites.json`: strategy 改为 `manual`，note 记录"2026-06-10: 站点持续返回404/REDIRECTING，疑似已关闭或更换域名"
      2. `baseline.json`: 移除 BTSchool，auto_total 43，manual_total 2
      3. 避免后续运行浪费 ~200s 重试时间
    - **Musopia**: 2026-06-10 通过 browser-open fallback 成功签到，恢复自动。
    - **FreeFarm**: 2026-06-10 webbridge 直接 SIGN_OK，滑块问题已解决。

    **Key insight**: 当基线站点连续多次以 404/REDIRECTING 失败时，这是**站点关闭**，不是自动化 bug。正确响应：
    1. 通过 webbridge 手动导航验证（navigate → evaluate title/text）
    2. 确认关闭后，将 strategy 改为 `manual`，更新 note 带时间戳
    3. 从 `baseline.json` 移除，更新 auto_total/manual_total
    4. 如站点未来恢复，可从 manual 改回并重新加入 baseline
    5. 考虑在 `sites.json` 增加 `status` 字段做系统性的离线追踪

    这避免了在不可修复的基础设施问题上浪费调试精力。

22. **Image captcha = manual site (v4.4)**: TJUPT (北洋园PT) 在 2026-06-11 启用图片验证码（选择与图片对应的影视名称），这是无法自动化的验证类型。与 BTSchool 不同，这不是站点关闭，而是验证升级。
    - **诊断**: webbridge navigate 成功，但页面显示"签到验证码"要求选择图片对应的影视名称
    - **修复**:
      1. `sites.json`: strategy 从 `browser-open` 改为 `manual`，note 记录"2026-06-11: 站点启用图片验证码，无法自动化"
      2. `baseline.json`: 将 TJUPT 从 `sites` 移到 `manual_sites`，auto_total 42，manual_total 3
    - **区别**: 图片验证码 (v4.4) vs 站点关闭 (v4.2) — 前者是验证升级需人工处理，后者是基础设施问题。两者都转为 manual，但原因不同。
    - **FreeFarm 补充**: 同日 FreeFarm 再次遇到间歇性滑块/CF验证，webbridge 偶发失败。保持 `browser-open` 策略，更新 note 记录间歇性问题。

23. **Cloudflare Managed Challenge = manual site (v4.5)**: UBits 在 2026-06-20 启用 Cloudflare 托管挑战（Managed Challenge），页面显示"正在进行安全验证"并包含 CF 安全质询 iframe，webbridge 无法自动通过。
    - **诊断**: webbridge navigate 后，snapshot 显示标题为"请稍候…"，页面内容包含"正在进行安全验证"和"包含 Cloudflare 安全质询的小组件"，等待 30 秒后仍未通过
    - **与 CF Turnstile 的区别**: CF Turnstile 是自动化的 JavaScript 挑战，webbridge 可以自动通过；Managed Challenge 需要人机交互（如点击"我不是机器人"），webbridge 无法绕过
    - **修复**:
      1. `sites.json`: strategy 从 `browser-open` 改为 `manual`，note 记录"2026-06-20: 站点启用Cloudflare托管挑战（需人机交互验证），webbridge无法绕过，改为手动"
      2. `baseline.json`: 将 UBits 从 `sites` 移到 `manual_sites`，auto_total 41，manual_total 4
    - **关键区别**: CF Turnstile (自动通过) vs CF Managed Challenge (需人机交互)。前者 webbridge 可以处理，后者必须转为 manual。

24. **SPA sites with human verification = manual site (v4.6)**: Yemapt on 2026-06-22 consistently returned NEED_SIGN even after clicking the "立即签到" button.
    - **Diagnosis**: After webbridge navigate to `https://www.yemapt.org/#/consumer/checkIn`, detect returned NEED_SIGN, click returned CLICKED:立即签到, but re-check still returned NEED_SIGN. Historical records show this site uses SPA architecture and on 2026-06-02 displayed "人机验证加载中" (human verification loading).
    - **Root cause**: SPA sign-in logic likely depends on asynchronous API calls; the click event may not trigger the actual sign-in request, or additional frontend validation may be required
    - **Fix** (v4.7 update): Yemapt was restored to automated on 2026-06-23. The original assessment was premature — with proper webbridge configuration, Yemapt sign-in works correctly (SIGN_OK). The earlier failure may have been caused by timing issues or temporary site state.
    - **Lesson**: Don't move to manual too quickly. Multiple retry attempts with progressively longer waits and page reloads should be tried first before giving up on automation.

25. **Never auto-add manual strategy — notify only (v4.7)**: Automation must never automatically change a site's strategy to `manual`. Sites that appear to need manual intervention must be flagged in a `needs_manual_review` list and reported via Feishu, but the actual strategy change requires explicit user approval.
    - **Why**: Auto-moving sites to manual is irreversible without user awareness. False positives (sites that just need more wait/retry) permanently remove sites from automation unnecessarily.
    - **Implementation**:
      1. `$tracking.needs_manual_review` tracks sites with CF_BLOCKED or SLIDER_FAIL
      2. Feishu card shows "需人工审核" section with warning
      3. `signin-log.json` includes `needs_manual_review` field
      4. Console prints `[REVIEW]` line with reminder
      5. No code path sets strategy to "manual" automatically
    - **Rule**: Only the user can manually edit `sites.json` to change strategy to `manual`. The code only reports, never decides.

26. **Bookmark folder path matching bug (v4.7)**: The `Walk-BookmarkNodes` function used `$node.name` (leaf folder name only, e.g. "签到") to match against `$bookmarkFolderPattern` (full path like "PT/签到"). The leaf name never matches the full path pattern, so bookmark sync was completely broken — no new sites were ever discovered.
    - **Fix**: Pass accumulated `$path` parameter through recursive calls, building `$curPath = "$path/$($node.name)"` and matching against the full path.
    - **Affected files**: `signin-batch.ps1` (Sync-Bookmarks), `scan-bookmarks.ps1` (Walk-All, Collect-Urls)
    - **Lesson**: Always test path-based matching against the full path, not just the leaf name. Test with actual bookmark structure verification.

27. **CF retry enhancement: progressive wait + page reload (v4.7)**: For stubborn CF Managed Challenge sites (UBits), increase CF retry count and add page reload on odd-numbered retries to trigger CF re-evaluation.
    - **Config**: `CfRetryCount` (default 3) and `CfRetryWaitMs` (default 10000) are configurable per site in `signin-web.ps1`
    - **Pattern**: Wait grows linearly (1×, 2×, 3×... of base `CfRetryWaitMs`
    - **Page reload**: Every odd retry reloads the page via `location.reload()` to give CF a fresh chance to evaluate the client
    - **UBits config**: `WaitMs=45000, CfRetryCount=5, CfRetryWaitMs=20000` (total ~5min max wait)

28. **Visit-only sites (v4.7)**: Some PT sites don't have a sign-in/attendance feature. For these, "success" means just visiting the site while logged in (account activity maintenance).
    - **Example**: BTSchool — `attendance.php` returns 404, no sign-in button anywhere on the site
    - **Detection**: Check for "欢迎回来" (welcome back) in page text → return SIGN_OK
    - **Strategy**: `browser-open` + webbridge, no `Click = $null
    - **URL**: Use `index.php` (home page), not `attendance.php`
    - **Purpose**: Maintain account activity and share ratio visibility
    - **Report as**: SUCCESS / VISITED (logged-in visit counts as success)

29. **BTSchool is alive, attendance.php is dead (v4.7)**: Earlier conclusion that BTSchool was closed was incorrect — the site is fully operational. The mistake was testing only `attendance.php` which returns 404; the actual site works fine.
    - **Correct URL**: `https://pt.btschool.club/index.php` (home page works, user is logged in, 5.6TB upload, 72+ share ratio
    - **Why the mistake**: Only tested `attendance.php` (returns 404), never checked other pages
    - **Lesson**: Don't declare a site "closed" based on one URL returning 404. Always check the homepage and other key pages first.
    - **Fix**: Changed to visit-only strategy (see #28 above)

30. **Yemapt works with webbridge (v4.7)**: Yemapt was moved to manual in v4.6 due to SPA + human verification concerns. Re-tested in v4.7 with webbridge and it returns SIGN_OK on first attempt.
    - **URL**: `https://www.yemapt.org/#/consumer/checkIn`
    - **WaitMs**: 20000
    - **Result**: SIGN_OK (detects "连续签到N天" pattern
    - **Lesson**: Don't give up on SPA sites too quickly. Webbridge with proper wait time and retry logic can handle many SPA sign-in pages.

31. **Debug Snapshot System (v4.8)**: Every webbridge sign-in session can save full page snapshots as JSON files for post-mortem analysis. Snapshots are saved when `SaveDebugSnapshot = $true` and include:
    - **What's saved**: URL, title, readyState, bodyText (5000 chars), bodyHtml (30000 chars), cfIframes list, signTexts (keyword context snippets)
    - **When saved**: At key stages: detect*fail, sign_ok, login_required, cf_blocked_final, sign_ok_after_cf, sign_ok_after_click, final*<signal>
    - **File location**: `debug-snapshots/<SiteName>_<Stage>_<timestamp>.json`
    - **How to enable**: `.\signin-batch.ps1 -SaveDebugSnapshot` or pass `-SaveDebugSnapshot $true -DebugDir <path>` to `Invoke-WebSignIn`
    - **Purpose**: Replace blind guessing about "what was on the page" with concrete evidence. Enables AI-driven diagnosis without needing to re-run.

32. **CF verify button auto-click (v4.8)**: `Invoke-CfVerifyClick` function automatically attempts to click CF challenge buttons during retry loops:
    - **What it clicks**: turnstile widgets, captcha checkboxes, challenge-stage elements, iframes containing cloudflare/turnstile/captcha
    - **Text matching**: "请验证您是真人", "验证您是真人", "我不是机器人", "Verify you are human", "I am human", "I'm not a robot", "Not a robot"
    - **When it runs**: At the start of each CF_CHALLENGE retry iteration
    - **Limitation**: CF Managed Challenge (automatic, no visible button) cannot be clicked through — this only helps with Turnstile widget style challenges that require a click to start
    - **For Managed Challenge**: The user must manually pass CF once to establish a trusted browser session/CF cookie. After that, webbridge can use the authenticated session.

33. **AI Debug Feedback Loop (v4.8) — MANDATORY METHODOLOGY**: When a site fails sign-in, AI must follow this structured feedback loop using debug snapshots. Do NOT skip steps.

    **Phase 1 — Evidence Collection (must do before hypothesizing)**
    1. Locate the debug snapshot: `debug-snapshots/<SiteName>_*_<latest_timestamp>.json`
    2. Read ALL fields: url, title, bodyText, bodyHtml, cfIframes, signTexts
    3. Check `signin-log.json` for the exact failure status and signal
    4. Check `iterations.json` for any prior attempts/fixes for this site

    **Phase 2 — Diagnosis (3+ hypotheses, ranked)**
    Generate at least 3 falsifiable hypotheses for why the sign-in failed. Rank them by likelihood.
    Example hypotheses:
    - H1: CF Managed Challenge — browser fingerprint detected as automated (evidence: title="请稍候…", body contains "正在进行安全验证")
    - H2: Login session expired (evidence: body contains "请登录"/"未登录")
    - H3: Sign-in button pattern mismatch (evidence: page has sign-in text but our detect JS doesn't match)

    **Phase 3 — Targeted Test (one variable at a time)**
    For the top hypothesis, design a targeted test using webbridge:
    - If CF challenge: Increase WaitMs, add more retries, try page reload, check if manual pass helps
    - If login issue: Verify by navigating to homepage and checking for username
    - If pattern mismatch: Extract page text, find actual sign-in text, update detect JS
    - If missing button: Inspect HTML for actual button tag/class, update click JS

    **Phase 4 — Fix & Verify**
    1. Update the relevant config in `signin-web.ps1` (detect JS, click JS, WaitMs, CfRetryCount, etc.)
    2. Run `Invoke-WebSignIn -SiteName "<Name>" -SaveDebugSnapshot $true -DebugDir "<path>"` to verify
    3. Save the debug snapshot from the successful run as evidence
    4. If the fix works → solidify: update baseline, update skill doc, add lesson learned

    **Phase 5 — Solidification (must do after every successful fix)**
    After a site starts working:
    1. Update `baseline.json` if it's a new success
    2. Add a numbered lesson to this skill doc (like #31, #32, etc.)
    3. Update `README.md` if the feature affects user-facing documentation
    4. Update `CHANGELOG.md`
    5. Commit and push the changes

    **Anti-patterns to avoid**:
    - ❌ Guessing at the cause without reading debug snapshots
    - ❌ Changing multiple variables at once (e.g., both WaitMs and detect JS)
    - ❌ Declaring a site "impossible" after one attempt
    - ❌ Moving to manual without going through the full feedback loop first
    - ❌ Fixing and then forgetting to document the lesson

    **Rule**: If you can't explain WHY the fix worked (based on snapshot evidence), you haven't finished debugging. The fix might be a fluke.

34. **CF Managed Challenge vs Turnstile Widget (v4.8)**: Two different CF challenge types, two different approaches:
    - **CF Turnstile Widget**: Visible checkbox/widget, requires click to start. `Invoke-CfVerifyClick` can help. Often passes automatically after click.
    - **CF Managed Challenge**: No visible button, automatic browser fingerprinting in background. `Invoke-CfVerifyClick` does nothing. May pass automatically if browser looks "human enough"; if not, requires user to manually pass once to establish trust.
    - **How to tell**: Check bodyHtml for `cType: 'managed'` (Managed) vs turnstile iframe with checkbox (Widget). Check page title: "请稍候…" = Managed; "Just a moment" with checkbox = Widget.
    - **For Managed Challenge failures**: The best strategy is (1) increase wait time + retries + page reloads, (2) if still failing, user manually passes once in the same browser profile, (3) subsequent runs should work via preserved cookies/session.

35. **False-pass defense: state-transition verification + keyword tightening (v4.9)**: Some sites reported SIGN_OK but had not actually signed in — the detect JS matched button text like "签到得魔力" (a clickable button, not a success state).
    - **Root cause**: `签到得` is a substring of the button label "签到得魔力" (sign-in to get magic), which means NEED_SIGN, not SIGN_OK. The detect JS `t.indexOf('签到得')>-1 → SIGN_OK` was a false positive that fired on page load before any click.
    - **Fix 1 — keyword tightening**: Removed `签到得` from SIGN_OK detection in `signin-web.ps1` (PigGo/GGPT/HDDolby/HDHome/TJUPT, 5 sites). Removed overly broad `已完成` and `Daily Bonus` from `Test-SignIn` in `signin-batch.ps1` — "已完成" appears in many non-signin contexts, "Daily Bonus" is often a menu/title.
    - **Fix 2 — state-transition verification**: `Test-WebBridgeSignIn` now distinguishes:
      - **No ClickEval** (visit-only sites like BTSchool): first SIGN_OK → `SIGN_OK` (real success, visit IS the sign-in)
      - **With ClickEval** (click-to-sign sites): first SIGN_OK → `ALREADY_SIGNED` (already done today, not this run's success)
      - Click → recheck SIGN_OK → `SIGN_OK` (this run's actual success)
    - **New signal**: `ALREADY_SIGNED` maps to status `ALREADY_DONE`, counted in `ok_sites` (signed, just not by this run), not retryable.
    - **Lesson**: Detect JS must be mutually exclusive — the same text cannot mean both "can sign" and "already signed". When a button label contains a sign-in keyword, it's almost certainly NEED_SIGN, not SIGN_OK. Always require the NEED_SIGN → click → SIGN_OK state transition for click-based sites.

36. **Tab lifecycle management: close_tab prevents accumulation (v4.9)**: Retries and multi-site runs accumulated browser tabs — "previous tab still open when next one opens" — because every `navigate` used `newTab=$true` and nothing closed tabs until the final `close_session`.
    - **Webbridge API**: `close_tab` action (confirmed via probe: returns `{closed:false, reason:"session has no tab"}` when empty) and `list_tabs` are supported by the daemon.
    - **Fix**: `Test-WebBridgeSignIn` now wraps its body in `try/finally`:
      - **Start**: `close_tab` to clean any residual tab from the previous site or retry attempt
      - **End (finally)**: `close_tab` to close this site's tab immediately
    - **Result**: Each site keeps exactly 1 tab during its sign-in; retries close the old tab before opening a new one. No accumulation across the whole batch.
    - **Lesson**: Any function that opens a browser tab must own its full lifecycle (open → use → close). `try/finally` is the reliable pattern — it closes the tab even on early return or exception. Never rely on a distant `close_session` to clean up mid-run tabs.

37. **Click JS selector hardening: precise match + leaf-node filter (v4.9.1)**: HDDolby stuck in a 3x retry loop (`NEED_SIGN → click → recheck still NEED_SIGN`). The Click JS used `v.indexOf('签到')>-1` as fallback, which is too broad — it matched a navigation `<a>` element whose `textContent` was `"欢迎回来, Schalkiiii ( UID: 40534 ) [退出]    签到..."` (the full header container text included the sign-in keyword further down). The script clicked the wrong element (user-info link), so the sign-in button was never actually pressed.
    - **Root cause**: `textContent` on a parent element includes all descendant text. A query like `querySelectorAll('a,span,b,font,button')` can match containers whose text happens to include "签到" somewhere in their subtree, even though the visible label is "欢迎回来...".
    - **Fix — three-layer defense**:
      1. **Exact match** (priority 1): `v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'` — equal to known button labels only.
      2. **Prefix + length** (priority 2): `v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)` — starts with "签到得" and short enough to be a button (not a 200-char container).
      3. **Leaf-node filter**: `if(el.children.length>1) continue` — skip elements with multiple children (containers); only click leaf nodes.
    - **Also fixed**: HDDolby Detect JS keyword `签到得魔力` didn't match the site's actual `签到得鲸币`. Added `签到得鲸币` to the NEED_SIGN check.
    - **Batch hardened**: same template applied to PigGo/OurBits/GGPT/HDHome/TJUPT (5 sites via replace_all) + HDBao (preserving its `input[value*="签到"]` priority match) + HHCLUB (new config).
    - **Lesson**: Never use bare `indexOf('签到')` as a click selector — it's a substring that appears in navigation, user info, and footer text across NexusPHP sites. Always require exact equality or a strict prefix + length cap, and filter to leaf nodes. The `textContent` of a container includes all descendants, so a "签到" match doesn't mean the element IS the sign-in button.

38. **webbridge routing gate: note must contain "webbridge" (v4.9.1)**: HHCLUB (a baseline site) returned `=> ERROR` with no `[WebBridge]` log output. Root cause: `signin-batch.ps1` line 499 gates webbridge routing on `if ($site.note -match "webbridge")`. HHCLUB's note was `"改用browser-open"` (the word "webbridge" absent), so it fell through to the opencli `Browser-SignIn` branch, which failed.
    - **Impact**: Any `browser-open` site whose note lacks the literal "webbridge" silently uses the wrong backend. New auto-synced sites get note `"auto: 书签同步新增"` and never route to webbridge — 11 such sites (42w/h-e/zxiaoruan/pp/littlesheep/onrender/anyrouter/huan666/xt-url/pbh-btn/invites) all ERROR.
    - **Fix for HHCLUB**: added config in `signin-web.ps1` + changed note to include "webbridge".
    - **Lesson**: Routing decisions must not depend on a substring in a free-text note field — it's brittle and invisible. Either (a) use an explicit `backend` field (`webbridge`/`opencli`), or (b) default `browser-open` to webbridge when daemon is available. The note-gate is a hidden coupling that bites when notes are auto-generated or hand-edited.

39. **Single backend simplification: opencli fully replaced by kimi webbridge (v4.10)**: Lesson #38's note-gate bug was a symptom of a deeper problem — maintaining two backends (opencli + webbridge) created dual code paths, routing complexity, and silent failures when the opencli daemon was down (17 sites NO_ARTICLE regression on 2026-07-02). The fix wasn't another patch on the routing gate; it was eliminating the dual-backend architecture entirely.
    - **Migration**: 5-phase plan — (1) add visit-only mode to webbridge, (2) simplify switch from 5 branches to 2 (manual + default→webbridge), (3) add 33 site configs using two reusable JS templates (`$NexusPHPSignInDetect` / `$SPASignInDetect`), (4) unify all non-manual strategies to `webbridge`, (5) update docs.
    - **Key design decisions**:
      - **Two reusable JS templates** instead of 33 copy-pasted configs: NexusPHP attendance.php sites share `$NexusPHPSignInDetect` (Click=$null, visit=sign-in); SPA console sites share `$SPASignInDetect` (login state = success). Reduces maintenance burden from 33 configs to 2 templates.
      - **visit-only mode** (Detect=$null): returns `VISITED` after navigate+wait, supporting "pure visit" sites (M-Team, SpeedApp) without false SIGN_OK signals.
      - **ALREADY_SIGNED vs SIGN_OK distinction preserved**: sites with ClickEval → first SIGN_OK = ALREADY_SIGNED (already signed today); sites without ClickEval → first SIGN_OK = real success (visit triggered the sign-in).
    - **Result**: 997→633 lines (signin-batch.ps1), 17→50 site configs (signin-web.ps1), 5→2 switch branches, 0 opencli dependencies. All 48 non-manual sites covered.
    - **Lesson**: When a routing gate causes silent failures (lesson #38), the root fix is to eliminate the routing decision entirely, not patch the gate. Dual-backend architectures create hidden coupling — the moment one backend fails, the routing logic becomes a liability. Single-backend + template-based config is simpler, more robust, and easier to maintain. The cost of migration (5 phases, 33 new configs) was far less than the ongoing cost of maintaining dual paths.

40. **Display name vs primary key separation (v4.11.0)**: The `name` field in site config is a primary key with 5 dependencies (WebSignInConfigs lookup, baseline.json comparison, fail_sites dedup, signin-single lookup, debug snapshot filename) — it cannot be renamed casually. Added `display_name` as a pure presentation layer, falling back to `name` when absent.
    - **Background**: Sync-Bookmarks generates `name` from URL domain's penultimate segment (e.g. `42w`/`pp`/`audiences`), which is cryptic and unreadable in Feishu push messages.
    - **Design**: `display_name` participates in no matching logic; it's only used for Feishu card push and log display. Sync-Bookmarks auto-extracts bookmark name as `display_name` when adding new sites.
    - **Lesson**: When a primary key field has many dependencies, adding a new display field is safer than renaming the primary key. Fallback logic (`if ($dn) { $dn } else { $name }`) ensures backward compatibility.

41. **Captcha-extension polling scheme (v4.12.0)**: When the user's browser has a captcha auto-fill extension, use `setInterval` async polling in Click JS to wait for the extension to fill the captcha before submitting.
    - **Background**: vclib/521 (NexusPHP sites) require image captcha (`<input name="imagestring">` + `<img src="image.php?action=regimage">`). v4.10.1 marked them as manual. User reported browser extension can auto-fill captchas.
    - **Scheme**: Because webbridge evaluate is synchronous and doesn't support Promise/awaitPromise, Click JS uses `setInterval` to check `input.value` every 1 second. evaluate returns `CLICK_SCHEDULED` immediately; setInterval runs async in the browser during PostClickMs.
    - **Tuning**: v4.12.1 expanded polling window from 12s to 28s, PostClickMs from 15s to 30s (extension may need longer to recognize NexusPHP image captchas).
    - **Limitation**: 521 testing showed the extension did not fill imagestring within 28s. The extension may not be enabled on pt.521.best domain, or may not support NexusPHP image captcha format. Requires user confirmation of extension config.
    - **Lesson**: Async polling bypasses evaluate's synchronous limitation, but requires the extension to actually work on the target domain. Design should assume extensions may have domain whitelists/format restrictions, and provide fast-fail + manual fallback.

42. **CF managed challenge and remote-login 2FA detection (v4.12.0)**: Detect JS should identify "non-sign-in-page" abnormal states to prevent Click JS from misoperating on error pages.
    - **CF managed challenge**: title="请稍候…" + bodyText contains "正在进行安全验证". Detect `.cf-turnstile` / `iframe[src*="challenges.cloudflare.com"]` / `[name="cf-turnstile-response"]` elements. Returns `CF_CHALLENGE` signal, classified into capSites.
    - **Remote-login 2FA**: URL redirects to `take2fa.php`, bodyText contains "异地登录" (remote login) / "两步验证" (2FA). Returns `LOGIN_REQUIRED` signal, triggers Feishu alert for manual handling.
    - **Lesson**: Detect JS should identify not only "sign-in status" but also "page abnormal states" (CF block / 2FA / login expired / server error). Otherwise Click JS misfires on navigation elements on abnormal pages, producing hard-to-debug side effects.

43. **CF Turnstile closed Shadow DOM requires CDP piercing (v4.12.6)**: CF Turnstile uses `attachShadow({mode:'closed'})` to encapsulate the iframe; JS `evaluate` can never see the internal checkbox. Must use CDP (Chrome DevTools Protocol) to pierce through.
    - **Root cause**: closed shadow DOM is a browser security boundary — `document.querySelector` returns null, `element.shadowRoot` is also null. The old `Invoke-CfVerifyClick` always returned `cdp:no-widget` because it tried DOM lookup.
    - **Fix**: `Invoke-CfVerifyClick` fully rewritten as CDP scheme:
      1. `DOM.describeNode(pierce=true)` pierces closed shadow DOM to locate CF iframe node
      2. `Input.dispatchMouseEvent` simulates 3-step click: `mouseMoved` → `mousePressed` → `mouseReleased`
      3. Click coordinates take iframe left side ~24px (checkbox actual position, not center)
    - **Auxiliary**: After navigate, call `Page.bringToFront` to focus the tab (CF Turnstile requires page focus to render iframe)
    - **Lesson**: Browser extension `evaluate` is constrained by same-origin policy and shadow DOM boundaries. Closed shadow DOM must use CDP's `pierce=true` — this is the only user-mode way to bypass the shadow DOM boundary.

44. **NexusPHPSignInDetect cfTokenPassed fix (v4.12.6)**: After CF passes, `.cf-turnstile` div remains in DOM and `attendance-captcha-table` label contains "安全验证" text — old logic misidentified as CF_CHALLENGE → infinite retry.
    - **Root cause**: CF token passage does not remove the widget; it keeps the div and clears the token. Old Detect returned CF_CHALLENGE on `.cf-turnstile` presence, without distinguishing "widget exists but token already passed" state.
    - **Fix**: Check `input[name="cf-turnstile-response"]` token fill state:
      - Token empty + CF widget present → return `CF_CHALLENGE` (truly not passed)
      - Token filled → set `cfTokenPassed=true`, skip CF text detection below
    - **CF retry loop fix**: `Test-CfTurnstilePassed` returning `no-cf` also triggers re-detection (widget removed, token cleared state); old logic only re-detected on `passed:`, missing this case.
    - **Lesson**: CF Turnstile post-pass page state has three variants: widget+token (passed:), widget removed (no-cf), widget+token cleared (pending). Detect must distinguish all three, not just check widget presence.

45. **Yemapt ALTCHA proof-of-work adaptation (v4.12.6)**: Yemapt uses ALTCHA verification (proof-of-work based); must handle ALTCHA checkbox before clicking "立即签到" sign-in button, otherwise NEED_SIGN.
    - **Root cause**: ALTCHA is a PoW-based verification; after the user clicks the checkbox, the widget asynchronously computes PoW (~5-10 seconds). Only after computation completes is verification considered passed. Old Click JS directly clicked the sign-in button → ALTCHA unverified → server rejected.
    - **Identification**: ALTCHA widget class is `altcha-checkbox-wrap` / `altcha-widget`; checkbox is `input[type="checkbox"]` or `[role="checkbox"]`.
    - **Fix**: Click JS rewritten as two-phase flow:
      1. Check ALTCHA checkbox exists and unverified → click checkbox
      2. `setInterval` polls PoW completion every 1 second (check `altchaCheckbox.checked` or `.altcha-verified` class, max 12 seconds) → auto-click sign-in button
    - **Tuning**: `PostClickMs` increased from 8000 to 15000 (ALTCHA polling + sign-in button wait).
    - **Lesson**: Async verification mechanisms (ALTCHA/reCAPTCHA v3) need setInterval polling in Click JS for verification state, not assuming immediate pass after click. `PostClickMs` must exceed max verification time + sign-in button click wait.

46. **NexusPHPCfSignInClick universal Click template (v4.12.5)**: NexusPHP + CF Turnstile sites need to submit attendance form after CF passes; new universal Click JS template reduces duplication.
    - **Background**: DepthStudio/xloli/audiences are all NexusPHP attendance.php + CF Turnstile. After CF passes, token auto-fills `cf-turnstile-response` hidden input, but submit button must be clicked to submit the form.
    - **Template flow**: Check token filled → find `form[action*="attendance"]` → find `input[type=submit][value*="签到"]` → `submit.click()`.
    - **Failure signals**: `CF_NOT_PASSED` (token not filled) / `NO_FORM` (form not found) / `NO_SUBMIT` (submit button not found).
    - **Lesson**: NexusPHP attendance.php sites have highly consistent form structures, so a universal Click template can be extracted. The post-CF sign-in flow = submit attendance form, identical to "click button" logic for non-CF sites, just with an extra token check.

47. **CF Turnstile detects CDP automation (v4.12.6 known limitation)**: CDP `Input.dispatchMouseEvent` simulated clicks are detected by CF Turnstile; token is not filled.
    - **Symptom**: DepthStudio/xloli CDP click succeeds (`cdp:clicked:(730,457)`), but CF state stays `pending:cf-text` (earlier tests showed `passed:...`).
    - **Root cause**: CF Turnstile detects mouse event `isTrusted` flag, event sequence completeness, mouse trajectory randomness, etc. CDP `Input.dispatchMouseEvent` generates events with `isTrusted=false`, identified as automation by CF.
    - **Not fixed**: Need user confirmation whether to revert to manual. Possible alternatives: (a) `Input.synthesizePinchGesture` / `Input.emulateTouchFromMouseEvent`; (b) `Input.insertText` + focus switch; (c) directly invoke CF callback functions (requires reverse engineering).
    - **Lesson**: CDP is not omnipotent; CF Turnstile is one of the hardest anti-automation mechanisms to bypass today. Real browser clicks (manual) and CDP clicks are fundamentally different — `isTrusted` flag cannot be forged. When automation detection is too strong, decisively switch to manual to avoid wasting debug time.

48. **webbridge daemon 30s page load timeout (v4.12.6 known limitation)**: webbridge daemon has an internal 30s page load timeout, not controlled by `NavTimeoutSec`, causing NAV_FAIL on multiple sites.
    - **Symptom**: Moment/audiences/invites navigate reports `extension_error: navigate: page load timeout (30s)`; retry 2 times still fails.
    - **Root cause**: webbridge daemon's navigate command internally hardcodes 30s timeout; `NavTimeoutSec` parameter only controls PowerShell `Invoke-RestMethod` timeout, not daemon internals.
    - **Affected sites**: Sites with slow server response (Moment/ptlao) or CF-slowed loading (audiences).
    - **Not fixed**: Requires modifying webbridge daemon source (kimi-webbridge.exe), or waiting for upstream update. Current mitigation: per-site `WaitMs` config + retry logic.
    - **Lesson**: Third-party tool internal limits (like hardcoded timeouts) are common automation bottlenecks. When debugging, distinguish "script logic issues" (fixable) from "tool limitation issues" (only workaround or wait for upstream) — the former can be fixed, the latter cannot.

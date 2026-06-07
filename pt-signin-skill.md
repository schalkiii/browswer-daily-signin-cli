---
name: pt-signin
description: |
  Automated PT (Private Tracker) and forum site sign-in using opencli web read and browser commands.
  Covers NexusPHP attendance.php sites, Cloudflare Turnstile bypass, slider captcha API bypass,
  click-to-sign pages, and manual-only sites. Use when user asks to sign in to PT sites, checkin to
  tracker/forum sites, or automate daily attendance for private trackers.
updated: 2026-06-07 (v4.1 — 批量迁移web-read失败站点到webbridge: GGPT/HDDolby/HDHome/TJUPT/BTSchool/远景论坛/52pojie, 全站点Detect JS添加document.body null保护)
---

# PT Site Sign-in Automation

## Quick Start

```powershell
cd d:\workspace\ptsignin

# Full batch: 49 automated + 2 manual sites (~15-20min)
.\signin-batch.ps1
```

## Coverage

| Category                       | Count  | Description                              |
| ------------------------------ | ------ | ---------------------------------------- |
| web-read (NexusPHP)            | 19     | Attendance on page visit                 |
| browser-open (webbridge)       | 9      | kimi real browser, CF/WAF bypass         |
| browser-open (opencli)         | 1      | JS sign-in, CF challenge                 |
| browser-eval-click (click+det) | 2      | Click button + re-detect (forum checkin) |
| browser-visit (visit only)     | 7      | Pure visit, no sign-in detection         |
| browser-eval (API bypass)      | —      | Slider captcha bypass (as needed)        |
| manual (captcha / policy)      | 2      | Requires human interaction               |
| **Total**                      | **40** | All bookmark sites attempted             |

**Key Rule: Attempt ALL sites in the bookmark folder, not just previously successful ones.**
Use the baseline (`baseline.json`) as a reference for which sites _should_ succeed — regressions are real bugs. Sites not in baseline are exploratory opportunities.

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
| `iterations.json`       | Self-iteration log                                               | Yes        |
| `signin-log.json`       | Per-run result log                                               | Yes        |
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

**Why this works**: PowerShell's `Out-String` and redirect operators corrupt UTF-8 Chinese characters into mojibake. By evaluating the check inside the browser via `opencli browser eval`, the comparison uses the browser's native UTF-8 handling and returns ASCII string signals ("SIGN_OK", "CF_CHALLENGE", etc.) that PowerShell can correctly regex-match without corruption.

### Signal Semantics

| Signal           | Meaning                                  | Action                       |
| ---------------- | ---------------------------------------- | ---------------------------- |
| `SIGN_OK`        | Sign-in succeeded or already done today  | Report SUCCESS               |
| `CF_CHALLENGE`   | Cloudflare Turnstile/JS challenge page   | Wait 8s, retry eval          |
| `WAITING`        | Page says "please wait" (loading)        | Allow more time              |
| `SLIDER`         | Slider captcha detected                  | Need API bypass (Category D) |
| `LOGIN_REQUIRED` | Not logged in, shows login page          | Skip, needs manual re-login  |
| `LOGGED_IN`      | Logged in but no sign-in action detected | Flag for investigation       |
| `UNKNOWN`        | None of the above patterns matched       | Retry after 8s               |

### Strategy Matrix

| Strategy                   | Command                               | Base Wait | CF Wait | Retry Policy          | Count |
| -------------------------- | ------------------------------------- | --------- | ------- | --------------------- | ----- |
| `web-read`                 | `opencli web read --url`              | 3s        | —       | None                  | 19    |
| `browser-open` (webbridge) | `Invoke-WebSignIn` via kimi webbridge | 8-15s     | —       | None (perfect bypass) | 9     |
| `browser-open` (opencli)   | `opencli browser open` + eval         | 8s        | 12s     | 8s (UNKNOWN/CF)       | 1     |
| `browser-eval-click`       | Open + eval click + detect            | 6s+5s     | —       | 8s (UNKNOWN)          | 2     |
| `browser-visit`            | Open + detect + close                 | 8s        | —       | —                     | 7     |
| `browser-eval`             | Open + bypass API + eval              | 5s+10s    | —       | Auto token refresh    | —     |
| `manual`                   | N/A                                   | —         | —       | —                     | 2     |

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
    # Flow: navigate → wait → detect → [click] → re-check → close
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
6. **CRITICAL**: Do NOT filter sites by baseline. Attempt ALL 51 sites.

### Phase 2: Execution

7. Run `.\signin-batch.ps1` — processes all 51 sites sequentially
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
11. **Baseline is a reference, never a filter**: Never skip sites because they are not in the baseline. Attempt ALL 51 sites every run. The baseline exists to detect regressions, not to reduce the test set.
12. **Incremental baseline growth is the goal**: Each new site that succeeds for the first time is a victory. The baseline should grow monotonically — celebrate each addition and record it in `baseline.json`.
13. **Regression is the highest-priority bug**: If a site in the baseline fails, it means something broke (CF upgrade, token expiry, login session lost). These must be diagnosed and fixed before the next run. Report `[REGR]` prominently in Feishu.
14. **Exploratory failures are normal**: New sites not yet in the baseline will likely fail on first attempt. These are discovery opportunities, not bugs. Report them as `FAIL (N new)` to distinguish from regressions.

15. **iterations.json structure silently corrupts**: PowerShell's `ConvertTo-Json` is highly prone to warping a flat array into a nested structure when appending mixed-type entries. The v3.7.1 fix addresses this from both the code side (null-safe iteration + `[int]` cast) and the data side (periodic flattening). Never trust PowerShell-emitted JSON to remain flat — verify top-level keys after every append.

16. **Failure sites must be taxonomized for systematic improvement**: v3.7.1 failures fall into five categories — (a) server down/connection closed, (b) 404/site gone, (c) CF/WAF blocked, (d) login required/session expired, (e) page empty/no content. Each category maps to a different action: a→skip & wait for recovery, b→flag as potentially offline, c→increase wait to 12s/reuse trust tokens, d→investigate cookie expiry, e→switch to browser-open strategy. Categorized reporting in Feishu provides actionable data.

17. **webbridge beats opencli browser extension (v3.9)**: kimi webbridge controls the user's real browser — CF/WAF is perfectly bypassed (zero challenges), and sites never detect an anomalous environment. For any site where the opencli browser extension is CF-blocked or returns UNKNOWN, prefer switching to webbridge. Each site needs individual debug-verification of its detect/click JS code, then hardening into `signin-web.ps1` to ensure stable replayability. The debug flow for new webbridge sites: navigate → wait → detect → [click] → re-check → close_session. `Invoke-WebBridgeCommand` must use explicit named parameters (`-Action`, `-CmdArgs`, `-Session`) — positional arguments cause parameter type conflicts (`$Args` collides with PowerShell's automatic variable).

18. **Always guard document.body access in detect JS (v4.0.1)**: `document.body` can be null when the page is still loading, is an interstitial page, or has an error. The JS expression `document.body.innerText||''` throws `TypeError: Cannot read properties of null` when body is null. Fix: `var t = document.body ? document.body.innerText : '';`. This applies to both detect and click JS functions. Returning `BODY_NULL` from detect JS is a valid signal that should be handled without crashing.

19. **BODY_NULL is a terminal signal**: When a page has no body element after the configured WaitMs, it's not a timing issue — the page is likely in an error state, a redirect, or a pre-render state that won't resolve. Return `BODY_NULL` immediately without attempting click. The webbridge switch in `signin-batch.ps1` reports it as `PAGE_ERROR` for diagnosis.

20. **web-read → webbridge migration is the preferred fix for CF-blocked sites (v4.0.1)**: When a web-read site starts returning CF_DETECTED and the fallback browser-open also fails, the correct fix is to switch the site to webbridge strategy. This requires: (a) adding a `$WebSignInConfigs` entry in `signin-web.ps1` with detect/click JS, (b) changing strategy to `browser-open` in `sites.json` with `"webbridge"` in the note field, and (c) removing any `eval` field from the site config. The webbridge detect JS should follow the same pattern as other PT attendance pages: check CF/slider first, then sign-in status, then login status.

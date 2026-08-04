---
name: pt-signin
description: |
  Automated PT (Private Tracker) and forum site sign-in using kimi webbridge (single backend).
  Covers NexusPHP attendance.php sites, Cloudflare Turnstile bypass, click-to-sign pages,
  SPA console sites, and manual-only sites. Use when user asks to sign in to PT sites, checkin to
  tracker/forum sites, or automate daily attendance for private trackers.
updated: 2026-08-04
---

# PT Site Sign-in Automation

## Quick Start

```powershell
cd d:\workspace\browswer-daily-signin-cli

# Full batch: all webbridge sites + manual sites
.\signin-batch.ps1

# Single-site debug
.\signin-single.ps1 -Site <site-name>
```

## Design Overview

The system drives the extension inside the user's already-logged-in browser through the local **kimi WebBridge daemon** to complete multi-site sign-ins. All navigation, tab-closing, CF bypass, click, and retry logic lives in `kimi-webbridge.ps1`; per-site detection JS (`DetectEval`), click JS (`ClickEval`), and wait parameters live in `$WebSignInConfigs` inside `signin-web.ps1`; batch orchestration (per-site invocation, result aggregation, Feishu push, baseline tracking) lives in `signin-batch.ps1`.

**Core invariant — single session, single tab**: all sites share one daemon session `daily-signin`, and that session holds at most one tab at any moment. This is the key invariant that prevents tab leaks and `has no tab` storms (see "Navigation & Tab Lifecycle").

---

## Site Categories & Strategy

Each site in `sites.json` declares a `strategy` that decides how the batch treats it:

| `strategy` value | Behavior                                                                       | Success signal       | Automatic? |
| ---------------- | ------------------------------------------------------------------------------ | -------------------- | ---------- |
| `webbridge`      | Open page → detect sign-in state → click/bypass if needed                      | `SIGN_OK` / `ALREADY_SIGNED` | ✅ Yes     |
| `visit-only`     | Open page only, **no detect / no click** (keep-alive sites, e.g. Kufirc / AsianDVDClub) | `VISITED`            | ❌ Visit only |
| `web-read`       | Legacy alias, currently equivalent to `webbridge` (unified WebBridge detection flow) | `SIGN_OK` / `ALREADY_SIGNED` | ✅ Yes     |
| `manual`         | Not auto-processed; skipped and recorded into the Feishu "needs human" list (captcha / policy sites) | — (SKIPPED)          | ❌ Human   |

> To make a site "open but don't sign in": set `strategy` to `visit-only` (no `$WebSignInConfigs` change needed; visit-only is auto-detected from an empty `DetectEval`).

**Key Rule: Attempt ALL sites in the bookmark folder, not just previously successful ones.**
Use the baseline (`baseline.json`) as a reference for which sites _should_ succeed — regressions are real bugs. Sites not in baseline are exploratory opportunities.

### sites.json Field Definitions

| Field           | Required | Description                                                                             |
| --------------- | -------- | --------------------------------------------------------------------------------------- |
| `name`          | Yes      | Site primary key (5 deps: WebSignInConfigs/baseline/fail_sites/single/snapshot)         |
| `url`           | Yes      | Sign-in page URL                                                                        |
| `strategy`      | Yes      | `webbridge` / `visit-only` / `web-read` / `manual`                                      |
| `display_name`  | No       | Display name (Feishu push/logs), falls back to `name`. Auto-extracted by Sync-Bookmarks |
| `note`          | No       | Sync status / change notes                                                              |

### $WebSignInConfigs Field Definitions (signin-web.ps1)

`$WebSignInConfigs[<name>]` supplies per-site execution parameters consumed by `Test-WebBridgeSignIn`:

| Field                 | Description                                                                          |
| --------------------- | ------------------------------------------------------------------------------------ |
| `Url`                 | Sign-in page URL (matches `url` in sites.json)                                       |
| `Detect`              | JS detecting sign-in state (`DetectEval`). Empty ⇒ site treated as visit-only        |
| `Click`               | JS clicking the sign-in button (`ClickEval`). Empty ⇒ detect only, no click          |
| `WaitMs`              | Fixed wait (ms) after navigate for the first round                                   |
| `PostClickMs`         | Fixed wait (ms) after click                                                          |
| `LoadWaitSec`         | Max seconds to dynamically poll for page readiness (default 45, see global params)   |
| `ReadyEval`           | Custom page-ready JS (replaces default body-length + shield-keyword check)           |
| `ForceLayoutViewport` | Coordinate-click sites (CF Turnstile / ALTCHA / SLIDER) set `$true` to enable layout viewport |
| `NavTimeoutSec`       | Per-site navigation timeout seconds (default 120)                                    |
| `CfRetryCount` / `CfRetryWaitMs` | CF bypass retry count / interval                                       |

---

## Module Breakdown

| File                    | Responsibility                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------ |
| `kimi-webbridge.ps1`    | WebBridge API wrapper: navigation, `list_tabs` probe helpers, tab cleanup, CF/ALTCHA/SLIDER handling, detect & click execution, retry orchestration |
| `signin-web.ps1`       | Site config `$WebSignInConfigs`, shared click JS, config-consistency check, single-site entry `Invoke-WebSignIn` |
| `signin-batch.ps1`     | Batch orchestration: per-site invocation, result classification, failure retry, Feishu push, baseline tracking, human-review list |
| `signin-single.ps1`    | Single-site debug tool (hardcoded `-NoFocus:$true` background execution)             |
| `scan-bookmarks.ps1`   | Bookmark scan → generate/update `sites.json`                                         |
| `push-cumulative.ps1`  | Cumulative failure summary push                                                      |
| `rerun-remaining.ps1`  | Re-run accumulated failed sites                                                      |
| `convert-log.py` / `gen-report.py` | Log conversion and report generation                          |

### Core Execution Chain

```
signin-batch.ps1 (orchestration)
  └─ Invoke-WebSignIn -SiteName <name>           # signin-web.ps1
       └─ Test-WebBridgeSignIn @params           # kimi-webbridge.ps1
            ├─ Ensure-WebBridgeHealthy          # daemon/extension connectivity self-check + heal
            ├─ Open-SiteTab                     # cleanup → navigate(domcontentloaded) → reuse/new single tab
            ├─ Wait-PostNavigate                # dynamic poll for readiness (skipped for visit-only)
            ├─ Detect (evaluate DetectEval)     # read sign-in state signal
            └─ Click (evaluate ClickEval)        # click if needed → re-detect
```

---

## Navigation & Tab Lifecycle (Key Invariant)

**Single session `daily-signin` + single tab** is the root invariant that prevents leaks.

- `Open-SiteTab` calls `Close-SiteTabs-Verified` before every navigation: a daemon-level hard close (`close_session`) + post-close `list_tabs` verification. If tabs still remain it prints `⚠️ close_session 后仍有 N 个 tab 残留` (warning) instead of silently accumulating.
- Hard close beats per-id `close_tab`: `close_tab` struggles to hit tabs in backgrounded/inactive windows (`window.active=False`), a former root cause of tab accumulation; the daemon-level `close_session` works even when the extension is flaky/disconnected.
- Cleaning on entry guarantees "close old tab then open new even on retry", keeping ≤ 1 tab per session at all times.
- **All sites must share the same session name**: if a site used its own session, `close_session` would only clean itself and the previous site's tab would never close → leak returns.

### Navigation Method

`Open-SiteTab` uses a single `navigate` (`newTab=true` + `waitUntil=domcontentloaded`) straight to the target, then proceeds to detect/click.

**Why `waitUntil=domcontentloaded`**: the extension enforces an independent **30s `load`-event timeout** per navigate; on timeout it returns `extension_error` and **destroys the tab with it**. CF shields / slow sub-resources / long connections / backgrounded windows don't fire `load` within 30s → each round `newTab` + no cleanup on failure accumulates many tabs, and after the tab is destroyed, `evaluate` floods `session has no tab`. Switching to `domcontentloaded` (waits only for DOMContentLoaded, which CF-shielded sites usually reach in seconds) stops the timeouts and the `has no tab` spam.

### visit-only Slow-site Exception

`visit-only` sites (empty `DetectEval`) only need the page *opened* to achieve their goal, but DOMContentLoaded may never fire (tab keeps spinning). Here `Open-SiteTab`'s `-VisitOnly` switch applies: even if `domcontentloaded` times out, as long as the command was submitted and `list_tabs` confirms a tab was created (still loading is fine), it is treated as success and **does not enter outer retries** (avoids repeated cleanup/reopen); `Wait-PostNavigate` is also skipped (no need to wait for DOM readiness). Non-visit-only sites are unchanged, still requiring `domcontentloaded` success.

### Connectivity Self-heal & Retries

- **Self-check**: `Test-WebBridgeSignIn` calls `Ensure-WebBridgeHealthy` before work; on daemon/extension disconnect it auto-restarts (at most once per run).
- **Extension cold start**: the first site may fail to navigate; when `list_tabs` shows the extension isn't ready, it retries every 5s up to 3 times.
- **Navigation-timeout retry**: on `domcontentloaded` failure (slow server / transient), it re-navigates after a 12s cleanup, up to 2 times; still failing ⇒ `NAV_FAIL`.
- **Batch failure retry**: the five states `CF_BLOCKED` / `SLIDER_FAIL` / `PAGE_ERROR` / `NO_DETECT` / `TIMEOUT` are each retried 2 more times by the batch layer (10s interval).

---

## Detection Strategy: In-browser JS Signals

Core idea: JS runs inside the browser → handles UTF-8 Chinese natively → returns an ASCII signal to PowerShell, avoiding PowerShell-side encoding issues.

Each site's `Detect` in `$WebSignInConfigs` is an IIFE returning a string signal:

- `SIGN_OK`: already signed in (matches "签到成功 / 签到已得 / 已签到 / 这是您的第 / 每日登录奖励已领取 / Already checked / 打卡成功 / 获得奖励 …")
- `NEED_SIGN`: not signed in, needs click
- `ALREADY_SIGNED`: already signed in today (state page shows directly, not from this click)
- `SIGN_FAIL`: still failed after click
- `CF_CHALLENGE`: page contains Cloudflare challenge (`cf-turnstile` / `challenges.cloudflare`)
- `SLIDER`: slider verification appeared
- `SERVER_ERROR`: chrome-error page / connection error (network/proxy/site-side, not a code defect)
- `LOGIN_REQUIRED`: not logged in

PowerShell maps signals to result states `SUCCESS` / `ALREADY_DONE` / `NO_DETECT` / `CF_BLOCKED` / `SLIDER_FAIL` / `PAGE_ERROR` / `NO_LOGIN` (the `switch -Wildcard` in `signin-batch.ps1`).

---

## Verification Bypass Mechanisms

### Cloudflare Turnstile

Some NexusPHP sites (the `NexusPHPCfSignInClick` family) need CF Turnstile cleared before sign-in:

1. `Wait-PostNavigate` polls; when `cf-turnstile` is not yet passed it enters CF handling;
2. `Page.bringToFront` gives the tab focus (CF iframe needs focus to render); `-NoFocus` may be temporarily disabled;
3. `Get-CfWidgetViewportRect` reads the widget viewport coords, and with `ForceLayoutViewport` enabled clicks it;
4. Polls `Test-CfTurnstilePassed` (`cf-turnstile` gone and page ready) to confirm;
5. After passing, submits the attendance form (`ClickEval` clicks sign-in), retrying up to `CfRetryCount`.

### ALTCHA / SLIDER

- **ALTCHA** (e.g. Yemapt): two-phase `ClickEval` — solve ALTCHA then click sign-in, verified by `Test-AltchaVerified`.
- **SLIDER**: coordinate-click the slider with `ForceLayoutViewport=$true`; failure ⇒ `SLIDER_FAIL` enters batch retry.

> Focus & `-NoFocus`: `navigate newTab=true` alone doesn't raise the window; the only focus grabber is `Page.bringToFront` (needed by CF). Background batch defaults to `-NoFocus:$true` globally (no focus grab); CF handling borrows focus transiently.

---

## JSON BOM Tolerance

PowerShell's `ConvertFrom-Json` fails on a UTF-8 BOM (`\uFEFF`). Strip the BOM before every JSON parse:

```powershell
$configRaw = Get-Content $ConfigFile -Raw -Encoding UTF8
$configRaw = $configRaw -replace '^\uFEFF', ''
$config = $configRaw | ConvertFrom-Json
```

This applies to all JSON read points (`sites.json`, `iterations.json`, etc.).

---

## Directory & File Cleanup Convention

Before each batch run, the working directory should contain **only** these files:

| File                    | Purpose                                              | Keep? |
| ----------------------- | ---------------------------------------------------- | ----- |
| `signin-batch.ps1`      | Main batch script                                    | Yes   |
| `signin-single.ps1`     | Single-site debug tool                               | Yes   |
| `signin-web.ps1`        | Site sign-in config module (webbridge site configs)  | Yes   |
| `kimi-webbridge.ps1`    | WebBridge API wrapper (HTTP control of kimi browser)  | Yes   |
| `scan-bookmarks.ps1`    | Bookmark scanner                                     | Yes   |
| `config.example.json`   | Config template (desensitized; copy to config.json)  | Yes   |
| `config.json`           | Local config (private webhook, .gitignore excluded)  | Local |
| `sites.json`            | Site config                                           | Yes   |
| `baseline.json`         | Known-successful sites                               | Yes   |
| `iterations.json`       | Self-iteration log (runtime, .gitignore excluded)     | Runtime |
| `signin-log.json`       | Per-run result log (runtime, .gitignore excluded)     | Runtime |
| `sync-log.json`         | Bookmark sync log (runtime, .gitignore excluded)      | Runtime |
| `CHANGELOG.md`          | Version change log                                   | Yes   |
| `README.md`             | Project description                                  | Yes   |
| `.gitignore`            | Git ignore rules                                     | Yes   |
| `pt-signin-skill.md`    | Skill doc (English)                                  | Yes   |
| `pt-signin-skill-cn.md` | Skill doc (Chinese)                                  | Yes   |

All debug/temp scripts (`debug-*.ps1`, `_tmp_*.ps1`, `fix-encoding.ps1`, `test-browser.ps1`, `check-syntax.ps1`) must be deleted after stabilization. The batch script auto-cleans `web-articles/` at the start of each run. `debug-snapshots/` and `debug-shots/` are runtime snapshot dirs (.gitignore excluded) and old snapshots should be cleaned periodically.

---

## Key Design Decisions Summary

- **Single backend**: all automatic sign-ins uniformly go through kimi WebBridge; no multi-backend branching.
- **Single session, single tab**: the root invariant preventing leaks and `has no tab` storms.
- **`domcontentloaded` navigation**: avoids the extension's 30s `load` hard-timeout tab destruction and retry avalanche.
- **visit-only slow sites don't retry**: a created tab is treated as success, avoiding repeated cleanup/reopen.
- **Background-first**: `-NoFocus:$true` globally avoids focus grab; CF handling borrows focus transiently.
- **No auto `manual`**: failed sites only go into the "needs human review" list; the user confirms before manually editing `sites.json`.
- **Pre-run config consistency**: `Test-SigninConfigConsistency` checks inconsistencies like "non-manual site missing `$WebSignInConfigs`" before running, avoiding silent skips.

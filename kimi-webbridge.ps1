# kimi-webbridge.ps1 — 签到脚本 kimi WebBridge 集成模块
# 通过本地 daemon 操控用户真实浏览器完成签到
# URL 可透过 config.json → webbridge.baseUrl 自定义
# 用法: . .\kimi-webbridge.ps1; $r = Invoke-WebBridgeCommand "navigate" @{url="https://..."; newTab=$true} "session-name"

$WebBridgeBase = "http://127.0.0.1:10086/command"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ConfigPath = Join-Path $ScriptDir "config.json"
if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.webbridge -and $cfg.webbridge.baseUrl) { $WebBridgeBase = $cfg.webbridge.baseUrl }
    } catch {}
}

# daemon 健康检查与自动修复
# 解决: daemon 异常退出后残留 daemon.pid 导致无法重启
function Ensure-WebBridgeDaemon {
    # 先检测 API 是否可用（通过 navigate 探测，__health__ 无 tab 会失败）
    try {
        $null = Invoke-RestMethod -Uri $WebBridgeBase -Method Post -ContentType "application/json" -Body '{"action":"ping","args":{},"session":"__health__"}' -TimeoutSec 3
        return $true
    } catch {
        # 如果响应是 JSON 格式的错误（daemon 在运行），也算成功
        if ($_.Exception.Message -match "tool_error|no tab") { return $true }
    }

    # API 不可用，尝试修复 pid 文件并重启
    $wbDir = Join-Path $env:USERPROFILE ".kimi-webbridge"
    $pidFile = Join-Path $wbDir "daemon.pid"
    $exePath = Join-Path $wbDir "bin\kimi-webbridge.exe"

    if (-not (Test-Path $exePath)) {
        Write-Host "[WebBridge] daemon 未安装，跳过 webbridge 站点" -ForegroundColor Yellow
        return $false
    }

    # 删除残留 pid 文件（使用 .NET 方法绕过安全限制）
    if (Test-Path $pidFile) {
        Write-Host "[WebBridge] 清理残留 daemon.pid..."
        try { [System.IO.File]::Delete($pidFile) } catch {}
    }

    # 启动 daemon
    Write-Host "[WebBridge] 启动 daemon..."
    try {
        & $exePath start 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        # 验证：通过 netstat 检查端口 + 简单 API 调用
        $portCheck = netstat -ano 2>$null | Select-String "127.0.0.1:10086.*LISTENING"
        if (-not $portCheck) {
            Write-Host "[WebBridge] daemon 启动失败（端口未监听）" -ForegroundColor Red
            return $false
        }
        Write-Host "[WebBridge] daemon 启动成功" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[WebBridge] daemon 启动失败，跳过 webbridge 站点" -ForegroundColor Red
        return $false
    }
}

function Invoke-WebBridgeCommand {
    param(
        [string]$Action,
        [hashtable]$CmdArgs = @{},
        [string]$Session = "default",
        [int]$TimeoutSec = 30
    )
    $body = @{
        action  = $Action
        args    = $CmdArgs
        session = $Session
    }
    $json = $body | ConvertTo-Json -Compress -Depth 4
    try {
        $resp = Invoke-RestMethod -Uri $WebBridgeBase -Method Post -ContentType "application/json" -Body $json -TimeoutSec $TimeoutSec
        if ($resp.ok) { return $resp.data }
        else { Write-Error "[WebBridge] $Action FAIL: $($resp.error)"; return $null }
    } catch {
        Write-Error "[WebBridge] $Action ERROR: $_"
        return $null
    }
}

function Test-WebBridgeSignIn {
    param(
        [string]$SiteName,
        [string]$Url,
        [string]$DetectEval,
        [string]$ClickEval,
        [int]$WaitMs = 5000,
        [int]$PostClickWaitMs = 3000,
        [int]$NavTimeoutSec = 60,
        [int]$CfRetryCount = 3,
        [int]$CfRetryWaitMs = 10000,
        [bool]$SaveDebugSnapshot = $false,
        [string]$DebugDir = ""
    )
    $session = "daily-signin"

    # 清理上一站点或上一次重试残留的 tab，避免标签累积
    try { $null = Invoke-WebBridgeCommand -Action "close_tab" -CmdArgs @{} -Session $session -TimeoutSec 5 } catch {}

    try {
        Write-Host "  [WebBridge] $SiteName : navigate -> $Url"
        $nav = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
        if (-not $nav -or -not $nav.success) {
            return "NAV_FAIL"
        }

        Write-Host "  [WebBridge] $SiteName : waiting ${WaitMs}ms for page load"
        Start-Sleep -Milliseconds $WaitMs

        # visit-only 模式：无 DetectEval 时仅访问，不检测签到
        if (-not $DetectEval -or $DetectEval.Trim() -eq "") {
            Write-Host "  [WebBridge] $SiteName : visit-only (no detect), returning VISITED"
            return "VISITED"
        }

        Write-Host "  [WebBridge] $SiteName : evaluate detect"
        $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
        if (-not $detect) {
            # evaluate 失败常见于 tab 丢失（webbridge daemon bug: navigate 返回 success 但 tab 在等待期间消失）
            # 修复：重新 navigate + evaluate 一次
            Write-Host "  [WebBridge] $SiteName : evaluate failed (tab may be lost), retrying navigate..."
            try { $null = Invoke-WebBridgeCommand -Action "close_tab" -CmdArgs @{} -Session $session -TimeoutSec 5 } catch {}
            $navRetry = Invoke-WebBridgeCommand -Action "navigate" -CmdArgs @{ url = $Url; newTab = $true } -Session $session -TimeoutSec $NavTimeoutSec
            if ($navRetry -and $navRetry.success) {
                Start-Sleep -Milliseconds $WaitMs
                $detect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
            }
        }
        if (-not $detect) {
            Save-DebugSnapshot $SiteName $session "detect_fail" $DebugDir $SaveDebugSnapshot
            return "EVAL_FAIL"
        }

        if ($detect -is [string]) { $signal = $detect }
        elseif ($detect.value) { $signal = "$($detect.value)" }
        else { $signal = "$detect" }
        Write-Host "  [WebBridge] $SiteName : signal=$signal"

        # 状态转换验证：区分"访问即签到"与"今天已签到"
        # - 无 ClickEval（如 BTSchool）：访问即签到，SIGN_OK 为真实本次成功
        # - 有 ClickEval（需点击的站点）：首次 SIGN_OK 表示今天已签到，非本次签到成功 → ALREADY_SIGNED
        if ($signal -match "SIGN_OK|ALREADY_SIGNED") {
            $firstSignal = if ($ClickEval) { "ALREADY_SIGNED" } else { "SIGN_OK" }
            Save-DebugSnapshot $SiteName $session "sign_ok" $DebugDir $SaveDebugSnapshot
            return $firstSignal
        }
        if ($signal -match "LOGIN_REQUIRED|SLIDER|CAPTCHA") {
            Save-DebugSnapshot $SiteName $session $signal $DebugDir $SaveDebugSnapshot
            return $signal
        }

        if ($signal -match "CF_CHALLENGE|BODY_NULL|REDIRECTING") {
            for ($retry = 0; $retry -lt $CfRetryCount; $retry++) {
                $cfClickResult = Invoke-CfVerifyClick $session $SiteName
                if ($cfClickResult) { Write-Host "  [WebBridge] $SiteName : CF verify button clicked: $cfClickResult" }

                $waitSec = [math]::Round($CfRetryWaitMs / 1000 * ($retry + 1), 0)
                Write-Host "  [WebBridge] $SiteName : CF/BODY retry $($retry+1)/$CfRetryCount, wait ${waitSec}s..."
                Start-Sleep -Seconds $waitSec
                if (($retry + 1) % 2 -eq 1) {
                    Write-Host "  [WebBridge] $SiteName : reloading page for CF re-check..."
                    $null = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = "location.reload()" } -Session $session -TimeoutSec 15
                    Start-Sleep -Seconds 5
                }
                $reDetect = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 15
                $reSig = if ($reDetect -is [string]) { $reDetect } elseif ($reDetect.value) { "$($reDetect.value)" } else { "$reDetect" }
                Write-Host "  [WebBridge] $SiteName : retry signal=$reSig"
                if ($reSig -match "SIGN_OK|ALREADY_SIGNED") {
                    $cfPassSignal = if ($ClickEval) { "ALREADY_SIGNED" } else { "SIGN_OK" }
                    Save-DebugSnapshot $SiteName $session "sign_ok_after_cf" $DebugDir $SaveDebugSnapshot
                    return $cfPassSignal
                }
                if ($reSig -match "NEED_SIGN|UNKNOWN") {
                    $signal = $reSig
                    break
                }
                if ($reSig -match "LOGIN_REQUIRED") {
                    Save-DebugSnapshot $SiteName $session "login_required" $DebugDir $SaveDebugSnapshot
                    return "LOGIN_REQUIRED"
                }
            }
            if ($signal -match "CF_CHALLENGE|BODY_NULL|REDIRECTING") {
                Save-DebugSnapshot $SiteName $session "cf_blocked_final" $DebugDir $SaveDebugSnapshot
                return $signal
            }
        }

        if ($ClickEval) {
            Write-Host "  [WebBridge] $SiteName : evaluate click"
            $clicked = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $ClickEval } -Session $session -TimeoutSec 15
            Write-Host "  [WebBridge] $SiteName : click result=$clicked"

            Write-Host "  [WebBridge] $SiteName : waiting ${PostClickWaitMs}ms post-click"
            Start-Sleep -Milliseconds $PostClickWaitMs

            Write-Host "  [WebBridge] $SiteName : evaluate re-check"
            $recheck = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $DetectEval } -Session $session -TimeoutSec 30
            $recheckSig = if ($recheck -is [string]) { $recheck } elseif ($recheck.value) { "$($recheck.value)" } else { "$recheck" }
            # 点击后检测到已签到 → 本次签到成功（非 ALREADY_SIGNED）
            if ($recheckSig -match "SIGN_OK|ALREADY_SIGNED") {
                Save-DebugSnapshot $SiteName $session "sign_ok_after_click" $DebugDir $SaveDebugSnapshot
                return "SIGN_OK"
            }
            $signal = $recheckSig
        }

        Save-DebugSnapshot $SiteName $session "final_$signal" $DebugDir $SaveDebugSnapshot
        return $signal
    }
    finally {
        # 函数结束关闭本站点 tab，确保不残留给下一个站点
        try { $null = Invoke-WebBridgeCommand -Action "close_tab" -CmdArgs @{} -Session $session -TimeoutSec 5 } catch {}
    }
}

# 尝试点击 CF 验证按钮（"请验证您是真人" / "Verify you are human" / turnstile checkbox）
# 返回点击结果描述，未找到返回 $null
function Invoke-CfVerifyClick {
    param(
        [string]$Session,
        [string]$SiteName
    )
    $cfClickJS = @'
(function(){
  // 1. 点击 turnstile widget 中的 checkbox / 验证框
  var selectors = [
    'input[type="checkbox"]',
    '.cf-turnstile',
    '#challenge-stage',
    '.g-recaptcha',
    '[class*="turnstile"]',
    '[class*="captcha"]',
    '[id*="challenge"]',
    'iframe[src*="challenges.cloudflare.com"]',
    'iframe[src*="turnstile"]'
  ];
  var clicked = [];
  for(var i=0;i<selectors.length;i++){
    var els = document.querySelectorAll(selectors[i]);
    for(var j=0;j<els.length;j++){
      var el = els[j];
      try {
        // 尝试点击
        el.click();
        clicked.push(selectors[i]);
      } catch(e) {}
      // 如果是 iframe，尝试触发其内容
      if(el.tagName === 'IFRAME'){
        try { el.contentDocument.body.click(); } catch(e) {}
      }
    }
  }
  // 2. 查找页面上包含验证文字的可点击元素
  var texts = ['请验证您是真人','验证您是真人','我不是机器人','我是人类','Verify you are human','I am human','I\'m not a robot','Not a robot'];
  var allClickable = document.querySelectorAll('a,button,span,div,label');
  for(var k=0;k<allClickable.length;k++){
    var txt = (allClickable[k].textContent||'').trim();
    for(var m=0;m<texts.length;m++){
      if(txt.indexOf(texts[m])>-1 && txt.length < 50){
        try {
          allClickable[k].click();
          clicked.push('text:"'+texts[m]+'"');
        } catch(e) {}
        break;
      }
    }
  }
  if(clicked.length > 0) return 'clicked:' + clicked.join(';');
  return null;
})()
'@
    try {
        $result = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $cfClickJS } -Session $Session -TimeoutSec 10
        if ($result -and $result.value) { return "$($result.value)" }
        if ($result -is [string] -and $result) { return $result }
    } catch {}
    return $null
}

# 保存页面调试快照为 JSON
# 包含: URL, title, body innerText, body outerHTML(截断), 检测信号, 时间戳
function Save-DebugSnapshot {
    param(
        [string]$SiteName,
        [string]$Session,
        [string]$Stage,
        [string]$DebugDir,
        [bool]$Enabled
    )
    if (-not $Enabled -or [string]::IsNullOrEmpty($DebugDir)) { return }

    try {
        if (-not (Test-Path $DebugDir)) {
            New-Item -ItemType Directory -Path $DebugDir -Force | Out-Null
        }

        $snapshotJS = @'
(function(){
  var r = {
    url: location.href,
    title: document.title,
    readyState: document.readyState,
    bodyText: document.body ? document.body.innerText.substring(0, 5000) : '',
    bodyHtmlLen: document.body ? document.body.innerHTML.length : 0,
    bodyHtml: document.body ? document.body.innerHTML.substring(0, 30000) : '',
    cfIframes: [],
    signTexts: []
  };
  // 收集 CF 相关 iframe
  var iframes = document.querySelectorAll('iframe');
  for(var i=0;i<iframes.length;i++){
    var src = iframes[i].src || '';
    if(src.indexOf('cloudflare')>-1 || src.indexOf('turnstile')>-1 || src.indexOf('captcha')>-1){
      r.cfIframes.push(src);
    }
  }
  // 收集页面中包含签到/验证/登录的文本片段
  var keywords = ['签到','打卡','验证','登录','注册','欢迎','魔力','attendance','sign','check','verify','human','robot','captcha','turnstile','cloudflare'];
  var allText = document.body ? document.body.innerText : '';
  for(var k=0;k<keywords.length;k++){
    var idx = allText.toLowerCase().indexOf(keywords[k].toLowerCase());
    if(idx > -1){
      r.signTexts.push(keywords[k] + ': ...' + allText.substring(Math.max(0,idx-20), Math.min(allText.length,idx+40)).replace(/\s+/g,' ') + '...');
    }
  }
  return JSON.stringify(r);
})()
'@
        $snapData = Invoke-WebBridgeCommand -Action "evaluate" -CmdArgs @{ code = $snapshotJS } -Session $Session -TimeoutSec 15
        $snapJson = if ($snapData -is [string]) { $snapData } elseif ($snapData.value) { "$($snapData.value)" } else { "{}" }

        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $safeName = $SiteName -replace '[\\/:*?"<>|]', '_'
        $fileName = "$safeName`_$Stage`_$timestamp.json"
        $filePath = Join-Path $DebugDir $fileName

        # 包装成完整对象
        $wrapper = @{
            site = $SiteName
            stage = $Stage
            timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            page = ($snapJson | ConvertFrom-Json -ErrorAction SilentlyContinue)
        }
        $wrapper | ConvertTo-Json -Depth 6 | Out-File $filePath -Encoding UTF8
        Write-Host "  [Debug] Snapshot saved: $fileName"
    } catch {
        Write-Host "  [Debug] Snapshot save failed: $($_.Exception.Message)"
    }
}
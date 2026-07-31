# signin-web.ps1 — 站点签到固化脚本模块
# 每个站点的签到流程通过 kimi webbridge 调试验证，确保可稳定重放
# 用法: . .\signin-web.ps1; $r = Invoke-WebSignIn "52pojie"

. "$PSScriptRoot\kimi-webbridge.ps1"

# === v4.10: 通用检测 JS 模板（减少重复，便于维护）===

# NexusPHP attendance.php 通用检测：访问即签到，无需点击
$NexusPHPSignInDetect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  // v4.13.0: 2FA / 异地登录（HDDolby 等）优先判定为登录失效
  if(location.pathname.indexOf('take2fa.php')>-1||t.indexOf('异地登录')>-1||t.indexOf('两步验证')>-1) return 'LOGIN_REQUIRED';
  // v4.12.9: 已签到状态优先于 CF 检测 —— 部分站点（xloli）attendance 页始终残留 .cf-turnstile
  // 空 token widget，若先判 CF 会把"今日签到，得到魔力加成"误判成 CF_CHALLENGE 导致无限重试。
  // v4.13.0: 统一为所有 NexusPHP 站点的唯一 Detect（合并 OurBits/GGPT/HDDolby/HDHome/TJUPT/HDBao/HHCLUB
  //   近重复的"CF 优先"实现），消除"各自手写 CF 优先 Detect 重新引入该误判"的回归风险。
  // 简体 + 繁体匹配（SBPT 等繁体站点使用 "簽到成功"）
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('簽到已得')>-1||t.indexOf('今日已簽到')>-1||t.indexOf('已簽到')>-1||t.indexOf('簽到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('今日签到')>-1||t.indexOf('得到魔力加成')>-1) return 'SIGN_OK';
  if(t.indexOf('已领取')>-1||t.indexOf('本次签到获得')>-1) return 'SIGN_OK';
  // v4.12.6: CF Turnstile 检测 — token 已填入时跳过 CF 文本检测
  // CF 通过后 .cf-turnstile div 仍在 DOM 中，attendance-captcha-table label 含"安全验证"文本
  // 旧逻辑误判：token 已填入但页面含"安全验证"文本 → 仍返回 CF_CHALLENGE → 无限重试
  var cfWidget = document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage');
  var cfTokenPassed = false;
  if(cfWidget){
    var tokenInput = document.querySelector('input[name="cf-turnstile-response"]');
    if(!tokenInput || !tokenInput.value || tokenInput.value.length < 10){
      // CF widget 存在且 token 未填入 = CF 未通过
      return 'CF_CHALLENGE';
    }
    // CF 已通过（token 已填入），跳过下方 CF 文本检测
    cfTokenPassed = true;
  }
  // 仅在 CF token 未通过时检查 CF 文本（避免"安全验证"label 误判）
  if(!cfTokenPassed){
    if(t.indexOf('正在检查')>-1||t.indexOf('Just a moment')>-1) return 'CF_CHALLENGE';
    // "安全验证"仅在无 CF widget 时才算 CF_CHALLENGE（有 widget 时是 label 文本）
    if(t.indexOf('安全验证')>-1 && !cfWidget) return 'CF_CHALLENGE';
  }
  // NEED_SIGN（含 签到得鲸币/魔力/憨豆/领取/立即签到/打卡，简繁体）
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到得鲸币')>-1||t.indexOf('签到得憨豆')>-1||t.indexOf('签到领取')>-1||t.indexOf('立即签到')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('簽到得魔力')>-1||t.indexOf('簽到得鯨幣')>-1||t.indexOf('簽到得鲸币')>-1||t.indexOf('簽到領取')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('必须登录')>-1) return 'LOGIN_REQUIRED';
  // chrome-error 页面（HTTP 500/502 等服务器错误）
  if(location.protocol==='chrome-error:'||t.indexOf('HTTP ERROR')>-1||t.indexOf('当前无法使用此页面')>-1) return 'SERVER_ERROR';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  var match = t.match(/签到.{0,20}/);
  if(match) return 'NEED_SIGN:'+match[0];
  return 'UNKNOWN';
})()
'@

# v4.12.5: NexusPHP attendance.php + CF Turnstile 站点的通用 Click JS
# CF 通过后，token 自动填入 cf-turnstile-response hidden input，需要提交 attendance 表单
# 流程：检查 token → 找到表单 → 点击 submit 按钮
$NexusPHPCfSignInClick = @'
(function(){
  // 1. 检查 CF Turnstile token 是否已填入
  var tokenInput = document.querySelector('input[name="cf-turnstile-response"]');
  if(tokenInput && (!tokenInput.value || tokenInput.value.length < 10)){
    return 'CF_NOT_PASSED';
  }
  // 2. 找到 attendance 表单
  var form = document.querySelector('form[action*="attendance"]') || document.querySelector('form');
  if(!form) return 'NO_FORM';
  // 3. 找到 submit 按钮
  var submit = form.querySelector('input[type=submit][value*="签到"]') ||
               form.querySelector('input[type=submit][value*="簽到"]') ||
               form.querySelector('input[type=submit]');
  if(!submit) return 'NO_SUBMIT';
  // 4. 点击 submit
  submit.click();
  return 'CLICKED';
})()
'@

# SPA 控制台/资料页通用检测：登录态保持即视为成功（API 控制台类站点）
$SPASignInDetect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('login')>-1) return 'LOGIN_REQUIRED';
  if(t.length>100) return 'SIGN_OK';
  return 'BODY_NULL';
})()
'@

$WebSignInConfigs = @{

    "52pojie" = @{
        Url = "https://www.52pojie.cn/forum.php"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var btn = document.querySelector('button.custom-function-button.check-in');
  if(btn){
    var txt = (btn.textContent||'').trim();
    if(txt.indexOf('今日已签到')>-1||txt.indexOf('已签到')>-1||txt.indexOf('签到完成')>-1) return 'SIGN_OK';
    if(txt==='每日签到') return 'NEED_SIGN';
  }
  var t = document.body.innerText||'';
  if(t.indexOf('今日已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('领取今日签到奖励')>-1||t.indexOf('签到完成')>-1) return 'SIGN_OK';
  if(t.indexOf('请登录')>-1||t.indexOf('必须登录')>-1) return 'LOGIN_REQUIRED';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var btn = document.querySelector('button.custom-function-button.check-in');
  if(btn){ btn.click(); return 'CLICKED'; }
  var all = document.querySelectorAll('a');
  for(var i=0;i<all.length;i++){
    if((all[i].textContent||'').trim()==='每日签到'){ all[i].click(); return 'CLICKED_A'; }
  }
  return 'NO_BTN';
})()
'@
    }

    "V2EX" = @{
        Url = "https://www.v2ex.com/mission/daily"
        WaitMs = 6000
        PostClickMs = 4000
        Detect = @'
(function(){
  var t = document.body.innerText||'';
  var title = document.title||'';
  // v4.12.0: CF managed challenge 拦截（title="请稍候…" + "正在进行安全验证"）
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage,[name="cf-turnstile-response"]')) return 'CF_CHALLENGE';
  if(title.indexOf('请稍候')>-1||t.indexOf('正在进行安全验证')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('每日登录奖励已领取')>-1||t.indexOf('已连续登录')>-1) return 'SIGN_OK';
  if(t.indexOf('未登录')>-1||t.indexOf('请登录')>-1) return 'LOGIN_REQUIRED';
  var btn = document.querySelector('input[value*="领取"]');
  if(btn) return 'NEED_SIGN';
  if(t.indexOf('领取')>-1&&t.indexOf('每日登录奖励')>-1) return 'NEED_SIGN';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var btn = document.querySelector('input[value*="领取"]');
  if(btn){ btn.click(); return 'CLICKED'; }
  var all = document.querySelectorAll('a,button,input[type="button"]');
  for(var i=0;i<all.length;i++){
    var v = (all[i].textContent||all[i].value||'').trim();
    if(v.indexOf('领取')>-1){
      all[i].click();
      return 'CLICKED:'+v.substring(0,30);
    }
  }
  return 'NO_BTN';
})()
'@
    }


    "NodeSeek" = @{
        Url = "https://www.nodeseek.com/board"
        WaitMs = 8000
        PostClickMs = 5000
        Detect = @'
(function(){
  var t = document.body.innerText||'';
  if(t.indexOf('已签到')>-1||t.indexOf('今日已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('获得')>-1&&t.indexOf('鸡腿')>-1) return 'SIGN_OK';
  if(t.indexOf('今日还未签到')>-1||t.indexOf('试试手气')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('必须登录')>-1||t.indexOf('您还未登录')>-1) return 'LOGIN_REQUIRED';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  // v4.12.26: NodeSeek 自有"Oops! Nework Error"网络错误页曾被兜底 LOGIN_REQUIRED 误判为登出，
  //   导致误报回归（实际是站点/代理侧波动）。显式识别网络错误 → SERVER_ERROR（非登录失效）。
  if(t.indexOf('Network Error')>-1||t.indexOf('Nework Error')>-1||t.indexOf('Oops')>-1||t.indexOf('重新加载')>-1) return 'SERVER_ERROR';
  if(location.protocol==='chrome-error:'||t.indexOf('无法访问此页面')>-1||t.indexOf('ERR_')>-1) return 'SERVER_ERROR';
  var idx = t.indexOf('签到');
  if(idx>-1) return 'NEED_SIGN:'+t.substring(idx,idx+40).replace(/\s+/g,' ');
  // v4.12.26: 兜底改为 UNKNOWN（不再误判为 LOGIN_REQUIRED，避免触发"需重新登录"通知）。
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var btns = document.querySelectorAll('button,a,span');
  for(var i=0;i<btns.length;i++){
    var v = (btns[i].textContent||'').trim();
    if(v.indexOf('试试手气')>-1||v.indexOf('签到领鸡腿')>-1||v.indexOf('签到得')>-1){
      btns[i].click();
      return 'CLICKED:'+v.substring(0,40);
    }
  }
  return 'NO_BTN';
})()
'@
    }

    "HDKYL" = @{
        Url = "https://www.hdkyl.in/attendance.php"
        WaitMs = 15000
        PostClickMs = 5000
        # v4.13.5: HDKYL 过网站盾(WAF)需更长等待；v4.13.6 起自然分辨率已是全局默认，无需单独声明。
        #   LoadWaitSec: 导航后动态轮询"页面就绪"（body 文本足够长且无盾关键词）最多 60s，盾一解立即继续（全局默认 45s，此处加长）。
        LoadWaitSec = 60
        Detect = @'
(function(){
  // v4.13.6: 雷池盾重载瞬间 body 为 null（现场实测每 ~5s 循环 complete→loading），
  //   直接取 innerText 会 TypeError → EVAL_FAIL 误判。返回 REDIRECTING 进 CF 重试循环等待。
  if(!document.body) return 'REDIRECTING';
  var t = document.body.innerText||'';
  // v4.12.3: 检测 chrome-error 页面（服务器连接关闭 ERR_CONNECTION_CLOSED 等）
  if(location.protocol==='chrome-error:'||t.indexOf('无法访问此页面')>-1||t.indexOf('ERR_CONNECTION')>-1) return 'SERVER_ERROR';
  // v4.12.2: 添加"签到已得"关键词（HDKYL 已签到时显示"[签到已得110, 补签卡: 0]"）
  if(t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('签到已得')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('必须登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1||t.indexOf('雷池')>-1) return 'CF_CHALLENGE';
  if(t.length<20||document.title.indexOf('Redirecting')>-1) return 'REDIRECTING';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var all = document.querySelectorAll('a,span,b,font,button');
  for(var i=0;i<all.length;i++){
    var v = (all[i].textContent||'').trim();
    if(v.indexOf('签到得')>-1||v.indexOf('打卡')>-1||v==='签到'){
      all[i].click();
      return 'CLICKED:'+v.substring(0,40);
    }
  }
  return 'NO_BTN';
})()
'@
    }
    "invites" = @{
        Url = "https://www.invites.fun/?sort=newest"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('今日已签')>-1||t.indexOf('签到完成')>-1) return 'SIGN_OK';
  var btn = document.querySelector('button.CheckInButton--yellow');
  if(btn) return 'NEED_SIGN';
  var greenBtn = document.querySelector('button.CheckInButton--green');
  if(greenBtn) return 'SIGN_OK';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1) return 'LOGIN_REQUIRED';
  if(t.indexOf('登录')>-1&&t.indexOf('注册')>-1&&t.indexOf('签到')<0) return 'LOGIN_REQUIRED';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var btn = document.querySelector('button.CheckInButton--yellow');
  if(btn){ btn.click(); return 'CLICKED'; }
  var greenBtn = document.querySelector('button.CheckInButton--green');
  if(greenBtn){ return 'ALREADY_SIGNED'; }
  return 'NO_BTN';
})()
'@
    }
    "PigGo" = @{
        Url = "https://piggo.me/attendance.php?id=18989"
        # v4.12.11: 雷池(Safeline) WAF JS 挑战页 body 初始为空，挑战通过后才注入真实内容。
        #   加大 WaitMs（12s→30s）给 WAF 挑战更充裕的求解时间，避免 body 仍空被判 UNKNOWN。
        WaitMs = 30000
        PostClickMs = 5000
        # v4.12.6: 复用 NexusPHPSignInDetect（含 cfTokenPassed 修复，避免"安全验证"文本误判）
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  // 收紧匹配：精确等于按钮文本 + 叶子节点过滤，避免误点导航栏容器
  var candidates = document.querySelectorAll('a,button,b,font,span,input[type=submit]');
  for(var i=0;i<candidates.length;i++){
    var el = candidates[i];
    if(el.children.length>1) continue;
    var v = (el.textContent||el.value||'').trim();
    if(v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'){
      el.click(); return 'CLICKED_EXACT:'+v;
    }
  }
  for(var j=0;j<candidates.length;j++){
    var el2 = candidates[j];
    if(el2.children.length>1) continue;
    var v2 = (el2.textContent||el2.value||'').trim();
    if(v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)){
      el2.click(); return 'CLICKED_PREFIX:'+v2;
    }
  }
  return 'NO_BTN';
})()
'@
    }
    "OurBits" = @{
        Url = "https://ourbits.club/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        # v4.13.6: CF Turnstile 坐标点击站——必须导航后即固定 1280x800 视口（默认已改为自然分辨率）
        ForceLayoutViewport = $true
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  // 收紧匹配：精确等于按钮文本 + 叶子节点过滤，避免误点导航栏容器
  var candidates = document.querySelectorAll('a,button,b,font,span,input[type=submit]');
  for(var i=0;i<candidates.length;i++){
    var el = candidates[i];
    if(el.children.length>1) continue;
    var v = (el.textContent||el.value||'').trim();
    if(v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'){
      el.click(); return 'CLICKED_EXACT:'+v;
    }
  }
  for(var j=0;j<candidates.length;j++){
    var el2 = candidates[j];
    if(el2.children.length>1) continue;
    var v2 = (el2.textContent||el2.value||'').trim();
    if(v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)){
      el2.click(); return 'CLICKED_PREFIX:'+v2;
    }
  }
  return 'NO_BTN';
})()
'@
    }
    "GGPT" = @{
        Url = "https://www.gamegamept.com/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  // 收紧匹配：精确等于按钮文本 + 叶子节点过滤，避免误点导航栏容器
  var candidates = document.querySelectorAll('a,button,b,font,span,input[type=submit]');
  for(var i=0;i<candidates.length;i++){
    var el = candidates[i];
    if(el.children.length>1) continue;
    var v = (el.textContent||el.value||'').trim();
    if(v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'){
      el.click(); return 'CLICKED_EXACT:'+v;
    }
  }
  for(var j=0;j<candidates.length;j++){
    var el2 = candidates[j];
    if(el2.children.length>1) continue;
    var v2 = (el2.textContent||el2.value||'').trim();
    if(v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)){
      el2.click(); return 'CLICKED_PREFIX:'+v2;
    }
  }
  return 'NO_BTN';
})()
'@
    }

    "HDDolby" = @{
        Url = "https://www.hddolby.com/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  // 收紧匹配：精确等于按钮文本 + 叶子节点过滤，避免误点导航栏容器
  var candidates = document.querySelectorAll('a,button,b,font,span,input[type=submit]');
  for(var i=0;i<candidates.length;i++){
    var el = candidates[i];
    if(el.children.length>1) continue;
    var v = (el.textContent||el.value||'').trim();
    if(v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'){
      el.click(); return 'CLICKED_EXACT:'+v;
    }
  }
  for(var j=0;j<candidates.length;j++){
    var el2 = candidates[j];
    if(el2.children.length>1) continue;
    var v2 = (el2.textContent||el2.value||'').trim();
    if(v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)){
      el2.click(); return 'CLICKED_PREFIX:'+v2;
    }
  }
  return 'NO_BTN';
})()
'@
    }

    "HDHome" = @{
        Url = "https://hdhome.org/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  // 收紧匹配：精确等于按钮文本 + 叶子节点过滤，避免误点导航栏容器
  var candidates = document.querySelectorAll('a,button,b,font,span,input[type=submit]');
  for(var i=0;i<candidates.length;i++){
    var el = candidates[i];
    if(el.children.length>1) continue;
    var v = (el.textContent||el.value||'').trim();
    if(v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'){
      el.click(); return 'CLICKED_EXACT:'+v;
    }
  }
  for(var j=0;j<candidates.length;j++){
    var el2 = candidates[j];
    if(el2.children.length>1) continue;
    var v2 = (el2.textContent||el2.value||'').trim();
    if(v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)){
      el2.click(); return 'CLICKED_PREFIX:'+v2;
    }
  }
  return 'NO_BTN';
})()
'@
    }


    "BTSchool" = @{
        Url = "https://pt.btschool.club/index.php"
        WaitMs = 12000
        PostClickMs = 0
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(t.indexOf('欢迎回来')>-1||t.indexOf('歡迎回來')>-1) return 'SIGN_OK';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.indexOf('404')>-1&&t.length<200) return 'REDIRECTING';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  return 'UNKNOWN';
})()
'@
        Click = $null
    }

    "远景论坛" = @{
        Url = "https://bbs.pcbeta.com/forum-win11-1.html"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(t.indexOf('签到成功')>-1||t.indexOf('签到完成')>-1||t.indexOf('已签到')>-1||t.indexOf('签到领奖')>-1) return 'SIGN_OK';
  var b = document.querySelector('button.check-in');
  if(b){ return 'NEED_SIGN'; }
  var all = document.querySelectorAll('button');
  for(var i=0;i<all.length;i++){
    var v = all[i].textContent||'';
    if(v.indexOf('每日签到')>-1){ return 'NEED_SIGN'; }
  }
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var b = document.querySelector('button.check-in');
  if(b){ b.click(); return 'CLICKED'; }
  var all = document.querySelectorAll('button');
  for(var i=0;i<all.length;i++){
    var v = all[i].textContent||'';
    if(v.indexOf('每日签到')>-1){ all[i].click(); return 'CLICKED'; }
  }
  return 'NO_BTN';
})()
'@
    }

    "HDBao" = @{
        Url = "https://hdbao.cc/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  var btn = document.querySelector('input[value*="签到"]');
  if(btn){ btn.click(); return 'CLICKED_INPUT'; }
  var candidates = document.querySelectorAll('a,button,input[type="submit"]');
  for(var i=0;i<candidates.length;i++){
    var el = candidates[i];
    if(el.children.length>1) continue;
    var v = (el.textContent||el.value||'').trim();
    if(v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'){
      el.click(); return 'CLICKED_EXACT:'+v;
    }
  }
  for(var j=0;j<candidates.length;j++){
    var el2 = candidates[j];
    if(el2.children.length>1) continue;
    var v2 = (el2.textContent||el2.value||'').trim();
    if(v2.length<20 && (v2.indexOf('签到得')===0||v2.indexOf('打卡')===0)){
      el2.click(); return 'CLICKED_PREFIX:'+v2;
    }
  }
  return 'NO_BTN';
})()
'@
    }

    "HHCLUB" = @{
        Url = "https://hhanclub.net/attendance.php"
        WaitMs = 15000
        PostClickMs = 8000
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  // 收紧匹配：精确等于按钮文本 + 叶子节点过滤，避免误点导航栏容器
  // v4.10.1: 支持 "签到获得XX憨豆" / "[签到得憨豆]" 等多样化按钮文本
  var candidates = document.querySelectorAll('a,button,b,font,span,input[type=submit]');
  for(var i=0;i<candidates.length;i++){
    var el = candidates[i];
    if(el.children.length>1) continue;
    var v = (el.textContent||el.value||'').trim();
    // 去掉方括号包裹后匹配：[签到得憨豆] → 签到得憨豆
    var vu = v.replace(/^\[|\]$/g,'');
    if(v==='签到得鲸币'||v==='签到得魔力'||v==='签到'||v==='打卡'||vu==='签到得憨豆'||vu==='签到得鲸币'||vu==='签到得魔力'){
      el.click(); return 'CLICKED_EXACT:'+v;
    }
  }
  for(var j=0;j<candidates.length;j++){
    var el2 = candidates[j];
    if(el2.children.length>1) continue;
    var v2 = (el2.textContent||el2.value||'').trim();
    var v2u = v2.replace(/^\[|\]$/g,'');
    // 前缀匹配：签到得XX / 签到获得XX / 打卡XX（支持方括号包裹）
    if(v2u.length<20 && (v2u.indexOf('签到得')===0||v2u.indexOf('签到获得')===0||v2u.indexOf('打卡')===0)){
      el2.click(); return 'CLICKED_PREFIX:'+v2;
    }
  }
  return 'NO_BTN';
})()
'@
    }

    "Rousi" = @{
        Url = "https://rousi.pro/points"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(t.indexOf('签到成功')>-1||t.indexOf('已签到')>-1||t.indexOf('连续签到')>-1) return 'SIGN_OK';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1) return 'LOGIN_REQUIRED';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var all = document.querySelectorAll('a,button,.sign-btn,.checkin-btn');
  for(var i=0;i<all.length;i++){
    var v = (all[i].textContent||'').trim();
    if(v.indexOf('签到')>-1&&v.indexOf('数')===-1){
      all[i].click(); return 'CLICKED';
    }
  }
  return 'NO_BTN';
})()
'@
    }

    # === v4.10: NexusPHP attendance.php 站点（访问即签到，Click=$null）===
    # 这些站点通过 webbridge navigate 访问 attendance.php（HTTP GET 即签到）。
    # 状态转换：无 ClickEval → 首次 SIGN_OK 视为本次签到成功（非 ALREADY_SIGNED）。

    "BiliDownload" = @{
        Url = "https://bilibili.download/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "DepthStudio" = @{
        Url = "https://dstudio.me/attendance.php"
        # v4.12.5: CF Turnstile 站点（attendance 页含 .cf-turnstile 内联控件），需要 CF 验证通过后提交表单。
        # 验证：CF 托管挑战偶发（CF 反爬强度波动），宽松日可过，严格日 no-rect 失败属站点侧行为。
        # v4.12.11: 加大 CF 耐心（WaitMs 18s→24s，重试 4→6 次、单次 15s→20s）以应对严格日更长的
        #   全页 CF 插页；宽松日 CF 快速通过会在首次重试即跳出，不增加耗时。
        # v4.12.12: 单次 CF 重试等待 20s→45s（用户要求拉长，覆盖更硬的插页）。
        WaitMs = 24000
        PostClickMs = 8000
        CfRetryCount = 6
        CfRetryWaitMs = 45000
        # v4.13.6: CF Turnstile 坐标点击站——必须导航后即固定 1280x800 视口（默认已改为自然分辨率）
        ForceLayoutViewport = $true
        Detect = $NexusPHPSignInDetect
        Click = $NexusPHPCfSignInClick
    }
    "HDClone" = @{
        Url = "https://pt.hdclone.top/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "HDVideo" = @{
        Url = "https://hdvideo.top/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "HTCPT" = @{
        Url = "https://www.htpt.cc/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "Moment" = @{
        Url = "https://www.momentpt.top/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "SBPT" = @{
        Url = "https://sbpt.link/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "Tokyo" = @{
        Url = "https://www.tokyo-manga.top/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "xloli" = @{
        Url = "https://mua.xloli.cc/attendance.php"
        # v4.12.5: CF 站点需要更长等待 + 多次 CF 重试 + CF 通过后提交表单
        WaitMs = 18000
        PostClickMs = 8000
        CfRetryCount = 4
        CfRetryWaitMs = 15000
        Detect = $NexusPHPSignInDetect
        Click = $NexusPHPCfSignInClick
    }
    "UBits" = @{
        Url = "https://ubits.club/attendance.php"
        # v4.12.10: 从 manual 策略移出，改为自动签到（用户确认可签）。
        # ubits.club 为 NexusPHP attendance 站，含 CF Turnstile，走标准 CF 验证流程
        # （依赖 v4.12.8 视口修复使坐标点击命中；CF 宽松日可过）。
        WaitMs = 18000
        PostClickMs = 8000
        CfRetryCount = 4
        CfRetryWaitMs = 15000
        Detect = $NexusPHPSignInDetect
        Click = $NexusPHPCfSignInClick
    }
    "YHPP" = @{
        Url = "https://www.yhpp.cc/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "musopia" = @{
        Url = "https://www.musopia.vip/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "ptlao" = @{
        Url = "https://ptlao.top/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }
    "vclib" = @{
        Url = "https://pt.vclib.online/attendance.php"
        WaitMs = 15000
        PostClickMs = 30000
        Detect = $NexusPHPSignInDetect
        # v4.12.0: 用户浏览器配备验证码自动输入扩展，Click JS 用 setInterval 轮询 imagestring
        # 字段，待扩展自动填入后点击"立即签到"提交按钮；evaluate 同步返回 CLICK_SCHEDULED，
        # PostClickMs 期间 setInterval 异步执行
        # v4.12.1: 轮询窗口从 12 秒扩到 28 秒，PostClickMs 从 15 秒扩到 30 秒，给扩展更长的识别时间
        Click = @'
(function(){
  var form = document.querySelector('form[action*="attendance"]');
  if(!form) return 'NO_FORM';
  var input = form.querySelector('input[name="imagestring"]');
  if(!input) return 'NO_INPUT';
  var submit = form.querySelector('input[type=submit][value*="签到"]') || form.querySelector('input[type=submit]');
  if(!submit) return 'NO_SUBMIT';
  // 立即检查 imagestring 是否已被扩展填入
  if(input.value && input.value.length > 0){
    submit.click();
    return 'CLICKED_NOW:'+input.value;
  }
  // 未填入，启动 setInterval 轮询（异步），最多等 28 秒
  var elapsed = 0;
  var timer = setInterval(function(){
    elapsed += 1000;
    if(input.value && input.value.length > 0){
      clearInterval(timer);
      submit.click();
    } else if(elapsed >= 28000){
      clearInterval(timer);
    }
  }, 1000);
  return 'CLICK_SCHEDULED';
})()
'@
    }
    "521" = @{
        Url = "https://pt.521.best/attendance.php"
        WaitMs = 15000
        PostClickMs = 30000
        Detect = $NexusPHPSignInDetect
        Click = @'
(function(){
  var form = document.querySelector('form[action*="attendance"]');
  if(!form) return 'NO_FORM';
  var input = form.querySelector('input[name="imagestring"]');
  if(!input) return 'NO_INPUT';
  var submit = form.querySelector('input[type=submit][value*="签到"]') || form.querySelector('input[type=submit]');
  if(!submit) return 'NO_SUBMIT';
  if(input.value && input.value.length > 0){
    submit.click();
    return 'CLICKED_NOW:'+input.value;
  }
  // v4.12.1: 扩展填入验证码可能需要较长时间，轮询窗口扩到 28 秒
  var elapsed = 0;
  var timer = setInterval(function(){
    elapsed += 1000;
    if(input.value && input.value.length > 0){
      clearInterval(timer);
      submit.click();
    } else if(elapsed >= 28000){
      clearInterval(timer);
    }
  }, 1000);
  return 'CLICK_SCHEDULED';
})()
'@
    }
    "audiences" = @{
        Url = "https://audiences.me/attendance.php"
        # v4.12.5: CF 站点需要更长等待 + 多次 CF 重试 + CF 通过后提交表单
        # v4.12.11: 加大 CF 耐心（WaitMs 18s→24s，重试 4→6 次、单次 15s→20s），同 DepthStudio
        # v4.12.12: 单次 CF 重试等待 20s→45s（用户要求拉长，覆盖更硬的插页）。
        WaitMs = 24000
        PostClickMs = 8000
        CfRetryCount = 6
        CfRetryWaitMs = 45000
        # v4.13.6: CF Turnstile 坐标点击站——必须导航后即固定 1280x800 视口（默认已改为自然分辨率）
        ForceLayoutViewport = $true
        Detect = $NexusPHPSignInDetect
        Click = $NexusPHPCfSignInClick
    }

    # v4.12.4: Yemapt 改回 webbridge（SPA + ALTCHA + 点击签到）
    # 07-01 曾因导航超时+tab 丢失回退 manual，v4.12.3 修复 extension 冷启动 + Clear-WebBridgeTabs 后重试
    # v4.12.6: 添加 ALTCHA checkbox 异步处理（PoW 计算最多 12 秒）
    "Yemapt" = @{
        Url = "https://www.yemapt.org/#/consumer/checkIn"
        WaitMs = 18000
        PostClickMs = 15000
        CfRetryCount = 4
        CfRetryWaitMs = 15000
        # v4.13.6: ALTCHA 坐标点击站——rect 由 ClickEval 在【点击前】算出，必须导航后即固定 1280x800
        #   视口（懒启用来不及：启用发生在 rect 计算之后会导致坐标系不一致）
        ForceLayoutViewport = $true
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  // CF Turnstile 检测（CF iframe 优先匹配）
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],iframe[src*="turnstile"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('Just a moment')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  // 登录态
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||(t.indexOf('登录')>-1&&t.indexOf('注册')>-1)) return 'LOGIN_REQUIRED';
  // 已签到明确标志
  if(t.indexOf('已签到')>-1||t.indexOf('今日已签')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  // 尚未签到 / 待验证 → 需要点击
  if(t.indexOf('尚未签到')>-1||t.indexOf('请先进行验证')>-1) return 'NEED_SIGN';
  // 页面已无"尚未签到"且含签到相关词 → 视为已签（避免复检误判 NEED_SIGN）
  if(t.indexOf('签到')>-1||t.indexOf('打卡')>-1) return 'SIGN_OK';
  if(t.length<50) return 'BODY_NULL';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  // v4.12.7: Yemapt 使用 ALTCHA（<altcha-widget> web component，proof-of-work）
  // 诊断证实：真实复选框在 closed Shadow DOM 内，JS .click() 与宿主点击都无法触发验证；
  // 改为返回 widget 视口坐标，交由 PowerShell 用 CDP 受信任鼠标点击（真实坐标可命中 shadow 内复选框），
  // 再用异步轮询检测验证完成（aria-checked / JWT 隐藏字段）后点击「立即签到」
  function collect(){
    var docs = [document];
    var frames = document.querySelectorAll('iframe');
    for(var f=0; f<frames.length; f++){
      try { var fd = frames[f].contentDocument; if(fd) docs.push(fd); } catch(e){}
    }
    var signBtn=null, widget=null, field=null;
    for(var d=0; d<docs.length; d++){
      var doc = docs[d];
      if(!widget){
        var w = doc.querySelector('altcha-widget, .altcha-checkbox-wrap, [class*="altcha"]');
        if(w) widget = w;
      }
      // ALTCHA 验证完成后会把 JWT（eyJ 开头）写入隐藏字段，name 多为 altcha
      var af = doc.querySelector('input[name="altcha"], input[name*="altcha"], input[value^="eyJ"]');
      if(af && af.value && af.value.length > 10) field = af;
      if(!signBtn){
        var btns = doc.querySelectorAll('button, [role="button"], a');
        for(var i=0;i<btns.length;i++){
          var v = (btns[i].textContent||'').trim();
          if(v==='立即签到'||v==='签到'||v==='今日签到'||v==='每日签到'||(v.indexOf('签到')>-1 && v.length<24)){ signBtn = btns[i]; break; }
        }
      }
    }
    // 验证完成判定：隐藏字段已填，或 widget 标记 aria-checked=true / verified class
    var verified = !!field;
    if(widget){
      try {
        if(widget.getAttribute && widget.getAttribute('aria-checked')==='true') verified = true;
        if(widget.className && ((''+widget.className).indexOf('verified')>-1)) verified = true;
      } catch(e){}
    }
    return {signBtn:signBtn, widget:widget, field:field, verified:verified};
  }
  function fireClick(el){
    try { el.click(); } catch(e){}
    try { el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window})); } catch(e2){}
  }
  var found = collect();
  // 已验证 → 直接点签到
  if(found.verified){
    if(found.signBtn){ found.signBtn.click(); return 'ALTCHA_DONE_CLICKED'; }
    return 'ALTCHA_DONE_NO_BTN';
  }
  // ALTCHA 复选框在 closed Shadow DOM 内，JS .click() 无法触发；返回 widget 视口坐标，
  // 交由 PowerShell 用 CDP 受信任鼠标点击（真实坐标点击可命中 shadow 内复选框）
  // v4.12.8: 诊断确认 ALTCHA 复选框位于 widget 左上区域（约左 24px、顶部 30% 处），
  //          而非几何中心；返回完整 rect 供 PowerShell 多候选点重试。
  if(found.widget){
    var r = found.widget.getBoundingClientRect();
    var cx = Math.round(r.x + Math.min(26, r.width * 0.05));
    var cy = Math.round(r.y + r.height * 0.30);
    var start = Date.now();
    var poll = setInterval(function(){
      var f2 = collect();
      if(f2.verified || (Date.now()-start) > 18000){
        clearInterval(poll);
        if(f2.signBtn){ f2.signBtn.click(); window.__yemapt = 'CLICKED'; }
        else { window.__yemapt = 'NO_BTN'; }
      }
    }, 1000);
    return 'ALTCHA_RECT:' + cx + ',' + cy + ',' + Math.round(r.width) + ',' + Math.round(r.height);
  }
  // 无 ALTCHA → 直接点签到
  if(found.signBtn){ found.signBtn.click(); return 'CLICKED'; }
  return 'NO_BTN';
})()
'@
    }

    # 13City: v4.10.1 修正 URL（原 usercp.php 是聚合签到页，改为单站点 attendance.php）
    "13City" = @{
        Url = "https://13city.org/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }

    # v4.12.22: daxiangjiao 补配置（原 web-read 策略但 $WebSignInConfigs 缺条目 → NO_CONFIG 被跳过）
    #   实为 NexusPHP attendance 站（"DaXiangJiao :: 签到"），走标准"访问即签到"流程。
    "daxiangjiao" = @{
        Url = "https://pt.daxiangjiao.org/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }

    # v4.12.26: cdy（传道院）补配置（原 web-read 策略但 $WebSignInConfigs 缺条目 → NO_CONFIG 被跳过）。
    #   pt.cdy.pics/attendance.php 为 NexusPHP 通用签到页。Click 用 $NexusPHPCfSignInClick：
    #   既能兼容"访问即签到"（Detect 直接 SIGN_OK/ALREADY_SIGNED），也能在需要提交表单时点击 submit，
    #   比 Click=$null 更稳妥（避免 NEED_SIGN 无点击 → NO_DETECT）。
    "cdy" = @{
        Url = "https://pt.cdy.pics/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $NexusPHPCfSignInClick
    }

    # === v4.10: browser-visit 站点迁移（visit-only，无 Detect/Click）===
    # kimi-webbridge.ps1 的 visit-only 分支：navigate + wait + close_tab，返回 "VISITED"。

    # v4.12.26: CHY（公益订阅）/ 蜂巢（pting）实际都有「签到/领取」按钮，需真正点击。
    #   CHY: 主页 <a class="btn btn-primary" href="/claim">领取今日 5GB</a>；点击跳 /?msg= 并显示 .banner。
    #        banner 含「领取成功」→ SIGN_OK；含「今日已领取过奖励」→ ALREADY_SIGNED；按钮常驻，首页无 banner 即 NEED_SIGN。
    #   蜂巢: Flarum 论坛，<button id="checkInButton">签到</button>；点击后按钮消失（被连续签到天数取代）→ 按钮存在=未签(NEED_SIGN)，消失=已签(ALREADY_SIGNED)。
    "chybenzun" = @{
        Url = "https://dy.chybenzun.top/"
        WaitMs = 8000
        PostClickMs = 5000
        Detect = @'
(function(){
  var full = document.body.innerText || '';
  var b = document.querySelector('.banner');
  var banner = b ? (b.innerText || '').trim() : '';
  if (banner.indexOf('领取成功') > -1 || full.indexOf('领取成功') > -1) return 'SIGN_OK';
  if (banner.indexOf('今日已领取') > -1 || banner.indexOf('已领取') > -1 || full.indexOf('今日已领取过奖励') > -1) return 'ALREADY_SIGNED';
  if (full.indexOf('领取今日 5GB') > -1) return 'NEED_SIGN';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var els = document.querySelectorAll('a');
  for (var i = 0; i < els.length; i++) {
    if ((els[i].innerText || '').indexOf('领取今日 5GB') > -1) { els[i].click(); return 'CLICKED'; }
  }
  return 'NO_BTN';
})()
'@
    }
    "pting" = @{
        Url = "https://pting.club/?sort=newest"
        WaitMs = 12000
        PostClickMs = 3000
        Detect = @'
(function(){
  var b = document.getElementById('checkInButton');
  if (b) return 'NEED_SIGN';
  var full = document.body.innerText || '';
  if (full.indexOf('已签到') > -1) return 'ALREADY_SIGNED';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var b = document.getElementById('checkInButton');
  if (b) { b.click(); return 'CLICKED'; }
  return 'NO_BTN';
})()
'@
    }

    # v4.13.3: pbh-btn（PBH-BTN 论坛）真实签到适配 —— 经 daemon 上线后现场 DOM 核验修正。
    #   与蜂巢(pting)同款 Flarum check-in 插件，但 **按钮无 id**：未签为
    #   <button class="Button CheckInButton--yellow hasIcon">签到</button>（可点），
    #   已签后变为 <button class="Button CheckInButton--green hasIcon disabled">已签到N天</button>。
    #   Flarum SPA 子资源可能长时间挂起而不触发 load：导航失败时 Open-SiteTab 会先校验
    #   location.href 是否其实已到达（DOM 常已可用），并按需重试，故不影响本站签到。
    "pbh-btn" = @{
        Url = "https://bbs.pbh-btn.com/"
        WaitMs = 15000
        PostClickMs = 3000
        Detect = @'
(function(){
  // 主检测：pbh-btn 无 id，按 class 取 check-in 按钮（黄=未签，绿=已签）
  var btn = document.querySelector('button.CheckInButton--yellow, button.CheckInButton--green');
  if (btn) {
    var txt = (btn.innerText || btn.textContent || '').trim();
    if (btn.classList.contains('disabled') || /已签到/.test(txt)) return 'ALREADY_SIGNED';
    return 'NEED_SIGN';
  }
  // 兜底：按文本「签到」找按钮（覆盖其他 class 变体）
  var els = document.querySelectorAll('button, a');
  for (var i = 0; i < els.length; i++) {
    var t = (els[i].innerText || els[i].textContent || '').trim();
    if (t === '签到' || t === '每日签到') return 'NEED_SIGN';
  }
  // 已签：页面出现连续签到天数
  var full = document.body.innerText || '';
  if (full.indexOf('已签到') > -1 || full.indexOf('连续签到') > -1 || full.indexOf('今日已签到') > -1) return 'ALREADY_SIGNED';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  // 仅点「未签」状态的按钮（黄且未 disabled、文本非已签），避免对已签按钮重复点击
  var btn = document.querySelector('button.CheckInButton--yellow, button.CheckInButton--green');
  if (btn && !btn.classList.contains('disabled') && !/已签到/.test((btn.innerText || btn.textContent || ''))) {
    btn.click(); return 'CLICKED';
  }
  var els = document.querySelectorAll('button, a');
  for (var i = 0; i < els.length; i++) {
    var t = (els[i].innerText || els[i].textContent || '').trim();
    if (t === '签到' || t === '每日签到') { els[i].click(); return 'CLICKED'; }
  }
  return 'NO_BTN';
})()
'@
    }

    "AsianDVDClub" = @{
        Url = "https://asiandvdclub.org/index.php"
        WaitMs = 8000
        Detect = $null
        Click = $null
    }
    "DigitalCore" = @{
        Url = "https://digitalcore.club/alltorrents?page=3&sort=up&fc=true#top"
        WaitMs = 8000
        Detect = $null
        Click = $null
    }
    "Kufirc" = @{
        Url = "https://kufirc.com/index.php"
        WaitMs = 8000
        Detect = $null
        Click = $null
    }
    "M-Team" = @{
        Url = "https://kp.m-team.cc/index"
        WaitMs = 8000
        Detect = $null
        Click = $null
    }
    "NewInsane" = @{
        Url = "https://newinsane.info/browse.php"
        WaitMs = 8000
        Detect = $null
        Click = $null
    }
    "SpeedApp" = @{
        Url = "https://speedapp.io/adult"
        WaitMs = 8000
        Detect = $null
        Click = $null
    }
    "UsefulTrash" = @{
        Url = "https://usefultrash.net/browse.php"
        WaitMs = 8000
        Detect = $null
        Click = $null
    }

    # === v4.10: browser-open 新站点迁移（SPA 控制台/资料页，通用模板）===
    # 这些站点是书签同步新增，签到结构未知。先用 SPA 通用模板（登录态保持即视为成功），
    # 根据 signin-log.json 结果再迭代调整。

    "onrender" = @{
        Url = "https://new-api-bxhm.onrender.com/console/personal"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
    "huan666" = @{
        Url = "https://ai.huan666.de/console/personal"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
}

# v4.13.0: 配置一致性校验
# 排查根因：书签同步向 sites.json 新增 strategy=web-read/browser-open 站点时，若忘记补 $WebSignInConfigs 条目，
#   Invoke-WebSignIn 返回 NO_CONFIG 并被 signin-batch 静默归类为 SKIPPED，导致新站点从不签到且无醒目提示。
# 本函数在批处理/单站运行前校验：对"非 manual 站点缺配置"给醒目 WARNING；对孤儿配置 / visit-only 误配给 INFO。
function Test-SigninConfigConsistency {
    param(
        [Parameter(Mandatory=$true)]
        $Config
    )
    $issues = @()
    if (-not $Config -or -not $Config.sites) { return $issues }
    $cfgNames = @($WebSignInConfigs.Keys)
    $siteNames = @($Config.sites | ForEach-Object { $_.name })
    foreach ($s in $Config.sites) {
        $hasCfg = $cfgNames -contains $s.name
        if ($s.strategy -eq 'manual') {
            if ($hasCfg) {
                $issues += @{ site = $s.name; severity = 'INFO'; message = "manual 站点但存在 `$WebSignInConfigs 条目（不会被自动执行，可清理）" }
            }
            continue
        }
        if (-not $hasCfg) {
            $issues += @{ site = $s.name; severity = 'WARN'; message = "strategy='$($s.strategy)' 但缺少 `$WebSignInConfigs 条目 → 将被 NO_CONFIG 静默跳过" }
            continue
        }
        # 配置存在：校验 strategy 与配置形态是否一致
        $c = $WebSignInConfigs[$s.name]
        if ($s.strategy -eq 'visit-only' -and ($null -ne $c.Detect -or $null -ne $c.Click)) {
            $issues += @{ site = $s.name; severity = 'INFO'; message = "visit-only 但配置含 Detect/Click（将仍执行检测，非纯保活）" }
        }
    }
    # 孤儿配置：$WebSignInConfigs 中存在但 sites.json 无对应站点 → 永不被触发
    foreach ($cn in $cfgNames) {
        if ($siteNames -notcontains $cn) {
            $issues += @{ site = $cn; severity = 'INFO'; message = "`$WebSignInConfigs 条目无对应 sites.json 站点（孤儿配置，永不被触发）" }
        }
    }
    return $issues
}

function Invoke-WebSignIn {
    param(
        [string]$SiteName,
        [bool]$SaveDebugSnapshot = $false,
        [string]$DebugDir = "",
        # v4.12.25: 默认后台（不弹前台）。前台(opt-in) 仅 CF Turnstile 站偶尔需要焦点才渲染，
        #   但用户明确优先级是"不弹前台"，故默认 $true；若要前台调试 CF，显式传 -NoFocus:$false。
        [bool]$NoFocus = $true
    )
    $cfg = $WebSignInConfigs[$SiteName]
    if (-not $cfg) {
        Write-Output "  [WebSignIn] $SiteName : no config, skip"
        return "NO_CONFIG"
    }

    $params = @{
        SiteName = $SiteName
        Url = $cfg.Url
        DetectEval = $cfg.Detect
        ClickEval = $cfg.Click
        WaitMs = $cfg.WaitMs
        PostClickWaitMs = $cfg.PostClickMs
        SaveDebugSnapshot = $SaveDebugSnapshot
        DebugDir = $DebugDir
        NoFocus = $NoFocus
    }
    if ($cfg.NavTimeoutSec) { $params.NavTimeoutSec = $cfg.NavTimeoutSec }
    if ($cfg.CfRetryCount) { $params.CfRetryCount = $cfg.CfRetryCount }
    if ($cfg.CfRetryWaitMs) { $params.CfRetryWaitMs = $cfg.CfRetryWaitMs }
    # v4.13.6: LoadWaitSec 全局默认 45s（在 Test-WebBridgeSignIn 参数默认值中）；
    #   用 ContainsKey 判断，允许站点显式设 LoadWaitSec=0 退回固定 WaitMs（if($cfg.LoadWaitSec) 会把 0 当假漏传）。
    if ($cfg.ContainsKey('LoadWaitSec')) { $params.LoadWaitSec = $cfg.LoadWaitSec }
    if ($cfg.ReadyEval) { $params.ReadyEval = $cfg.ReadyEval }
    # v4.13.6: 默认自然分辨率；仅坐标点击站（CF Turnstile/ALTCHA/SLIDER）声明 ForceLayoutViewport=$true
    if ($cfg.ForceLayoutViewport) { $params.ForceLayoutViewport = $cfg.ForceLayoutViewport }
    return Test-WebBridgeSignIn @params
}
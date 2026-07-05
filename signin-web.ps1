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
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1||t.indexOf('Just a moment')>-1) return 'CF_CHALLENGE';
  // 简体 + 繁体匹配（SBPT 等繁体站点使用 "簽到成功"）
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('簽到已得')>-1||t.indexOf('今日已簽到')>-1||t.indexOf('已簽到')>-1||t.indexOf('簽到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到得鲸币')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('簽到得魔力')>-1||t.indexOf('簽到得鯨幣')>-1||t.indexOf('簽到得鲸币')>-1||t.indexOf('簽到領取')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('必须登录')>-1) return 'LOGIN_REQUIRED';
  // chrome-error 页面（HTTP 500/502 等服务器错误）
  if(location.protocol==='chrome-error:'||t.indexOf('HTTP ERROR')>-1||t.indexOf('当前无法使用此页面')>-1) return 'SERVER_ERROR';
  if(t.length<20) return 'BODY_NULL';
  return 'UNKNOWN';
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

    "FreeFarm" = @{
        Url = "https://pt.0ff.cc/attendance.php"
        WaitMs = 15000
        PostClickMs = 5000
        Detect = @'
(function(){
  var t = document.body.innerText||'';
  var title = document.title||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],iframe[src*="turnstile"],#challenge-stage,#cf-challenge,div[class*="challenge"]')) return 'SLIDER';
  if(t.indexOf('正在检查')>-1||t.indexOf('Just a moment')>-1||t.indexOf('安全验证')>-1||t.indexOf('DDoS')>-1||t.indexOf('turnstile')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('验证您是真人')>-1||t.indexOf('确认您是真人')>-1||t.indexOf('滑动滑块')>-1) return 'SLIDER';
  if(title.indexOf('滑动认证')>-1||title.indexOf('安全验证')>-1) return 'SLIDER';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1) return 'SIGN_OK';
  var idx = t.indexOf('签到得魔力');
  if(idx>-1) return 'NEED_SIGN';
  if(t.indexOf('请先登录')>-1||t.indexOf('未登录')>-1||t.indexOf('客户端')>-1&&t.indexOf('登录')>-1) return 'LOGIN_REQUIRED';
  var match = t.match(/签到.{0,20}/);
  return 'UNKNOWN:'+(match?match[0]:'no_match')+'; title='+title.substring(0,50);
})()
'@
        Click = @'
(function(){
  var bolds = document.querySelectorAll('b');
  for(var i=0;i<bolds.length;i++){
    var v = (bolds[i].textContent||'').trim();
    if(v.indexOf('签到得魔力')>-1){ bolds[i].click(); return 'CLICKED_B:'+v; }
  }
  var fonts = document.querySelectorAll('font');
  for(var j=0;j<fonts.length;j++){
    var fv = (fonts[j].textContent||'').trim();
    if(fv.indexOf('签到得魔力')>-1){ fonts[j].click(); return 'CLICKED_FONT:'+fv; }
  }
  var links = document.querySelectorAll('a');
  for(var k=0;k<links.length;k++){
    var lv = (links[k].textContent||'').trim();
    if(lv==='签到得魔力'||lv.indexOf('签到得')===0){ links[k].click(); return 'CLICKED_A:'+lv; }
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
  var idx = t.indexOf('签到');
  if(idx>-1) return 'NEED_SIGN:'+t.substring(idx,idx+40).replace(/\s+/g,' ');
  return 'LOGIN_REQUIRED';
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
        Detect = @'
(function(){
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
        WaitMs = 12000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1||t.indexOf('雷池')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  return 'UNKNOWN';
})()
'@
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
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  var match = t.match(/签到.{0,20}/);
  if(match) return 'NEED_SIGN:'+match[0];
  return 'UNKNOWN';
})()
'@
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
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  var match = t.match(/签到.{0,20}/);
  if(match) return 'NEED_SIGN:'+match[0];
  return 'UNKNOWN';
})()
'@
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
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  // v4.12.0: 异地登录触发 2FA 验证（URL 跳转到 take2fa.php），需人工输入两步验证码
  if(location.pathname.indexOf('take2fa.php')>-1||t.indexOf('异地登录')>-1||t.indexOf('两步验证')>-1) return 'LOGIN_REQUIRED';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到得鲸币')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  var match = t.match(/签到.{0,20}/);
  if(match) return 'NEED_SIGN:'+match[0];
  return 'UNKNOWN';
})()
'@
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
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  var match = t.match(/签到.{0,20}/);
  if(match) return 'NEED_SIGN:'+match[0];
  return 'UNKNOWN';
})()
'@
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

    "TJUPT" = @{
        Url = "https://www.tjupt.org/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  var match = t.match(/签到.{0,20}/);
  if(match) return 'NEED_SIGN:'+match[0];
  return 'UNKNOWN';
})()
'@
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
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('立即签到')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1) return 'LOGIN_REQUIRED';
  return 'UNKNOWN';
})()
'@
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
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1||t.indexOf('Just a moment')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('已领取')>-1||t.indexOf('本次签到获得')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到得鲸币')>-1||t.indexOf('签到得憨豆')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
  var match = t.match(/签到.{0,20}/);
  if(match) return 'NEED_SIGN:'+match[0];
  return 'UNKNOWN';
})()
'@
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
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
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
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
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
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }

    # 13City: v4.10.1 修正 URL（原 usercp.php 是聚合签到页，改为单站点 attendance.php）
    "13City" = @{
        Url = "https://13city.org/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = $NexusPHPSignInDetect
        Click = $null
    }

    # === v4.10: browser-visit 站点迁移（visit-only，无 Detect/Click）===
    # kimi-webbridge.ps1 的 visit-only 分支：navigate + wait + close_tab，返回 "VISITED"。

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

    "42w" = @{
        Url = "https://api.42w.shop/console/personal"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
    "h-e" = @{
        Url = "https://elysiver.h-e.top/console/personal"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
    "zxiaoruan" = @{
        Url = "https://gyapi.zxiaoruan.cn/profile"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
    "pp" = @{
        Url = "https://ioll.pp.ua/console/personal"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
    "littlesheep" = @{
        Url = "https://ai.littlesheep.cc/profile"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
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
    "xt-url" = @{
        Url = "https://checkin.new-api.xt-url.com/"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
    "pbh-btn" = @{
        Url = "https://bbs.pbh-btn.com/"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
    "anyrouter" = @{
        Url = "https://anyrouter.top/console"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = $SPASignInDetect
        Click = $null
    }
}

function Invoke-WebSignIn {
    param(
        [string]$SiteName,
        [bool]$SaveDebugSnapshot = $false,
        [string]$DebugDir = ""
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
    }
    if ($cfg.NavTimeoutSec) { $params.NavTimeoutSec = $cfg.NavTimeoutSec }
    if ($cfg.CfRetryCount) { $params.CfRetryCount = $cfg.CfRetryCount }
    if ($cfg.CfRetryWaitMs) { $params.CfRetryWaitMs = $cfg.CfRetryWaitMs }
    return Test-WebBridgeSignIn @params
}
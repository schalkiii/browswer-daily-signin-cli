# signin-web.ps1 — 站点签到固化脚本模块
# 每个站点的签到流程通过 kimi webbridge 调试验证，确保可稳定重放
# 用法: . .\signin-web.ps1; $r = Invoke-WebSignIn "52pojie"

. "$PSScriptRoot\kimi-webbridge.ps1"

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
        Url = "https://hdfans.org"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = @'
(function(){
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],iframe[src*="turnstile"],#challenge-stage,#cf-challenge,div[class*="challenge"]')) return 'SLIDER';
  if(t.indexOf('正在检查')>-1||t.indexOf('Just a moment')>-1||t.indexOf('安全验证')>-1||t.indexOf('DDoS')>-1||t.indexOf('turnstile')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('验证您是真人')>-1||t.indexOf('确认您是真人')>-1||t.indexOf('滑动滑块')>-1) return 'SLIDER';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1) return 'SIGN_OK';
  var idx = t.indexOf('签到得魔力');
  if(idx>-1) return 'NEED_SIGN';
  if(t.indexOf('请先登录')>-1||t.indexOf('未登录')>-1||t.indexOf('客户端')>-1&&t.indexOf('登录')>-1) return 'LOGIN_REQUIRED';
  var match = t.match(/签到.{0,20}/);
  return 'UNKNOWN:'+(match?match[0]:'no_match');
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
        Url = "https://www.nodeseek.com"
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
  if(t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1) return 'SIGN_OK';
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
    "InvitesFun" = @{
        Url = "https://www.invites.fun/?sort=newest"
        WaitMs = 10000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('今日已签')>-1||t.indexOf('签到完成')>-1) return 'SIGN_OK';
  if(t.indexOf('签到')>-1||t.indexOf('Sign')>-1||t.indexOf('Check')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1) return 'LOGIN_REQUIRED';
  return 'UNKNOWN';
})()
'@
        Click = @'
(function(){
  var all = document.querySelectorAll('a,button,.btn,[class*=sign]');
  for(var i=0;i<all.length;i++){
    var v = all[i].textContent||'';
    if(v.indexOf('签到')>-1||v.indexOf('Sign')>-1||v.indexOf('Check')>-1){
      all[i].click(); return 'CLICKED'
    }
  }
  var header = document.querySelector('.header,header,#header,.navbar');
  if(header){
    var links = header.querySelectorAll('a');
    for(var j=0;j<links.length;j++){
      var t2 = links[j].textContent||'';
      if(t2.indexOf('签到')>-1||t2.indexOf('Sign')>-1){
        links[j].click(); return 'CLICKED'
      }
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
  var all = document.querySelectorAll('a,span,b,font,button,input[type=submit]');
  for(var i=0;i<all.length;i++){
    var v = (all[i].textContent||all[i].value||'').trim();
    if(v.indexOf('签到得魔力')>-1||v.indexOf('签到')>-1||v.indexOf('打卡')>-1){
      all[i].click(); return 'CLICKED:'+v.substring(0,40);
    }
  }
  return 'NO_BTN';
})()
'@
    }
    "UBits" = @{
        Url = "https://ubits.club/attendance.php"
        WaitMs = 15000
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
  var all = document.querySelectorAll('a,span,b,font,button,input[type=submit]');
  for(var i=0;i<all.length;i++){
    var v = (all[i].textContent||all[i].value||'').trim();
    if(v.indexOf('签到得魔力')>-1||v.indexOf('签到')>-1||v.indexOf('打卡')>-1){
      all[i].click(); return 'CLICKED:'+v.substring(0,40);
    }
  }
  return 'NO_BTN';
})()
'@
    }
}

function Invoke-WebSignIn {
    param(
        [string]$SiteName
    )
    $cfg = $WebSignInConfigs[$SiteName]
    if (-not $cfg) {
        Write-Output "  [WebSignIn] $SiteName : no config, skip"
        return "NO_CONFIG"
    }

    return Test-WebBridgeSignIn -SiteName $SiteName -Url $cfg.Url -DetectEval $cfg.Detect -ClickEval $cfg.Click -WaitMs $cfg.WaitMs -PostClickWaitMs $cfg.PostClickMs
}
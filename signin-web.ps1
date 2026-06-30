# signin-web.ps1 — 站点签到固化脚本模块
# 每个站点的签到流程通过 kimi webbridge 调试验证，确保可稳定重放
# 用法: . .\signin-web.ps1; $r = Invoke-WebSignIn "52pojie"

. "$PSScriptRoot\kimi-webbridge.ps1"

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
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('签到得')>-1) return 'SIGN_OK';
  if(t.indexOf('签到得魔力')>-1||t.indexOf('签到领取')>-1||t.indexOf('打卡')>-1) return 'NEED_SIGN';
  if(t.indexOf('请登录')>-1||t.indexOf('未登录')>-1||t.indexOf('登入')>-1&&t.indexOf('注册')>-1) return 'LOGIN_REQUIRED';
  if(t.length<20||(document.title||'').indexOf('Redirecting')>-1) return 'REDIRECTING';
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
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('签到得')>-1) return 'SIGN_OK';
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

    "HDDolby" = @{
        Url = "https://www.hddolby.com/attendance.php"
        WaitMs = 12000
        PostClickMs = 5000
        Detect = @'
(function(){
  if(!document.body) return 'BODY_NULL';
  var t = document.body.innerText||'';
  if(!!document.querySelector('.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#challenge-stage')) return 'CF_CHALLENGE';
  if(t.indexOf('正在检查')>-1||t.indexOf('安全验证')>-1) return 'CF_CHALLENGE';
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('签到得')>-1) return 'SIGN_OK';
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
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('签到得')>-1) return 'SIGN_OK';
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
  if(t.indexOf('签到已得')>-1||t.indexOf('今日已签到')>-1||t.indexOf('已签到')>-1||t.indexOf('签到成功')>-1||t.indexOf('签到得')>-1) return 'SIGN_OK';
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
  var all = document.querySelectorAll('a,button,input[type="submit"]');
  for(var i=0;i<all.length;i++){
    var v = (all[i].textContent||all[i].value||'').trim();
    if(v.indexOf('签到')>-1||v.indexOf('打卡')>-1){
      all[i].click(); return 'CLICKED:'+v.substring(0,40);
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
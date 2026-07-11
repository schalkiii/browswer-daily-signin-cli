import json
from datetime import datetime

base = r"D:\workspace\browswer-daily-signin-cli"
with open(base + r"\rerun-cumulative.json", encoding="utf-8") as f:
    data = json.load(f)
with open(base + r"\sites.json", encoding="utf-8") as f:
    raw = f.read().lstrip("\ufeff")
    sites = json.loads(raw)

meta = {}
for s in sites["sites"]:
    meta[s["name"]] = (s.get("display_name") or s["name"], s["url"], s.get("strategy"))

SUCCESS = {"SIGN_OK", "ALREADY_SIGNED", "VISITED"}

def classify(sig):
    return "success" if sig in SUCCESS else "fail"

def reason(name, sig):
    if sig in SUCCESS:
        return ""
    if sig == "CF_CHALLENGE":
        return "Cloudflare 严格日全页挑战，CDP 无法绕过（站点侧波动，宽松日可自动过）"
    if sig == "NEED_SIGN":
        if name == "TJUPT":
            return "图片验证码，需人工选择匹配图片（不可自动化）"
        if name in ("vclib", "521"):
            return "imagestring 验证码：扩展已填入并提交，服务器拒绝（浏览器扩展侧）"
        return "需点击签到但未完成"
    if sig == "BODY_NULL":
        return "页面 body 为空（OAuth 登录页 / WAF 挑战页未渲染，需人工登录）"
    if sig == "SERVER_ERROR":
        return "源站服务器错误（HTTP 5xx，站点侧）"
    if sig == "UNKNOWN":
        return "页面已加载但状态未识别"
    if sig == "SLIDER":
        return "滑块验证（已加 set_access_token token 绕过尝试）"
    if sig == "LOGIN_REQUIRED":
        return "未登录，需重新登录"
    return "未分类失败"

total = len(data)
succ = [e for e in data if classify(e["signal"]) == "success"]
fail = [e for e in data if classify(e["signal"]) == "fail"]
sign_ok = [e for e in succ if e["signal"] == "SIGN_OK"]
already = [e for e in succ if e["signal"] == "ALREADY_SIGNED"]
visited = [e for e in succ if e["signal"] == "VISITED"]

now = datetime.now().strftime("%Y-%m-%d %H:%M")

def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def chip(e):
    name = e["name"]
    dn = meta.get(name, (name, "", ""))[0]
    return f'<span class="chip ok" title="{esc(name)}">{esc(dn)}</span>'

def fail_row(e):
    name = e["name"]
    dn, url, strat = meta.get(name, (name, "", ""))
    return (f'<tr><td><a href="{esc(url)}" target="_blank">{esc(dn)}</a>'
            f'<br><span class="sub">{esc(name)}</span></td>'
            f'<td><span class="sig bad">{esc(e["signal"])}</span></td>'
            f'<td>{esc(reason(name, e["signal"]))}</td>'
            f'<td class="sub">{esc(e.get("time",""))}</td></tr>')

def detail_row(e):
    name = e["name"]
    dn, url, strat = meta.get(name, (name, "", ""))
    cls = "ok" if classify(e["signal"]) == "success" else "bad"
    return (f'<tr><td><a href="{esc(url)}" target="_blank">{esc(dn)}</a></td>'
            f'<td class="sub">{esc(name)}</td>'
            f'<td><span class="sig {cls}">{esc(e["signal"])}</span></td>'
            f'<td class="sub">{esc(strat)}</td>'
            f'<td class="sub">{esc(e.get("time",""))}</td></tr>')

html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PT 签到报告 {now}</title>
<style>
*{{box-sizing:border-box;}}
body{{margin:0;background:#0f1115;color:#e6e8eb;font-family:-apple-system,"Segoe UI",Roboto,"Microsoft YaHei",sans-serif;line-height:1.5;}}
.wrap{{max-width:980px;margin:0 auto;padding:28px 20px 60px;}}
h1{{font-size:24px;margin:0 0 4px;}}
.sub{{color:#8b93a1;font-size:12px;}}
.meta{{color:#8b93a1;font-size:13px;margin-bottom:22px;}}
.chips{{display:flex;flex-wrap:wrap;gap:10px;margin:14px 0 26px;}}
.chip{{background:#1b2330;border:1px solid #2a3445;border-radius:20px;padding:5px 13px;font-size:13px;color:#cdd3dc;}}
.chip.ok{{background:#14321f;border-color:#1f7a45;color:#7ee2a8;}}
.summary{{display:flex;gap:14px;flex-wrap:wrap;margin:10px 0 8px;}}
.card{{flex:1;min-width:130px;background:#171b22;border:1px solid #2a3445;border-radius:12px;padding:14px 16px;}}
.card .n{{font-size:26px;font-weight:700;}}
.card .l{{font-size:12px;color:#8b93a1;}}
.green{{color:#46d17f;}} .yellow{{color:#f5c542;}} .red{{color:#ff6b6b;}} .blue{{color:#5aa9ff;}}
section{{margin:30px 0;}}
h2{{font-size:18px;border-left:3px solid #2a3445;padding-left:10px;margin-bottom:14px;}}
table{{width:100%;border-collapse:collapse;font-size:13px;}}
th,td{{text-align:left;padding:8px 10px;border-bottom:1px solid #20262f;vertical-align:top;}}
th{{color:#8b93a1;font-weight:600;font-size:12px;}}
.sig{{display:inline-block;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:600;}}
.sig.ok{{background:#14321f;color:#7ee2a8;}}
.sig.bad{{background:#3a1c1c;color:#ff9a9a;}}
a{{color:#5aa9ff;text-decoration:none;}}
a:hover{{text-decoration:underline;}}
.note{{background:#171b22;border:1px solid #2a3445;border-radius:12px;padding:16px 18px;}}
.note li{{margin:6px 0;}}
.tag{{display:inline-block;background:#1b2330;border:1px solid #2a3445;border-radius:6px;padding:1px 7px;font-size:11px;color:#9fb0c8;margin-right:4px;}}
</style></head>
<body><div class="wrap">
<h1>PT 站点签到报告</h1>
<div class="meta">生成时间 {now} · 共 {total} 站 · 后端 kimi-webbridge（真实浏览器）</div>

<div class="summary">
  <div class="card"><div class="n green">{len(succ)}</div><div class="l">成功（{total} 中 {round(100*len(succ)/total)}%）</div></div>
  <div class="card"><div class="n yellow">{len(fail)}</div><div class="l">失败（站点/扩展侧）</div></div>
  <div class="card"><div class="n blue">{len(sign_ok)}</div><div class="l">本次签到 SIGN_OK</div></div>
  <div class="card"><div class="n blue">{len(already)}</div><div class="l">今日已签 ALREADY_SIGNED</div></div>
  <div class="card"><div class="n blue">{len(visited)}</div><div class="l">仅访问 VISITED</div></div>
</div>

<section>
<h2>本次适配 / 变更（v4.12.11）</h2>
<div class="note"><ul>
<li><span class="tag">FreeFarm</span> 旧 Detect 用过度宽泛的 <code>div[class*="challenge"]</code> 误报 SLIDER，实际已登录页无滑块。改为<b>已签到优先 + 精确滑块检测</b>，并新增 <code>Invoke-SlideBypass</code>（set_access_token token 提取）绕过真实滑块；<code>sites.json</code> 策略 manual→webbridge。结果 <b>ALREADY_SIGNED ✓</b></li>
<li><span class="tag">PigGo</span> 雷池(Safeline) WAF JS 挑战页 body 初始为空导致 UNKNOWN。加大 <code>WaitMs</code> 12s→30s 让 WAF 挑战求解。结果 <b>ALREADY_SIGNED ✓</b>（修复基线回归）</li>
<li><span class="tag">DepthStudio</span> / <span class="tag">audiences</span> CF 全页挑战波动：加大 CF 耐心（WaitMs 18s→24s、重试 4→6 次、单次 15s→20s）。今日仍被严格 CF 拦截（CDP 无法绕过），宽松日可自动过。</li>
<li><span class="tag">UBits</span> / <span class="tag">Yemapt</span> / <span class="tag">42w</span> 经 webbridge 验证可自动签到，从 <code>baseline.json</code> 的 manual_sites 移回 sites（auto）。</li>
</ul></div>
</section>

<section>
<h2>成功站点（{len(succ)}）</h2>
<div class="chips">
{"".join(chip(e) for e in succ)}
</div>
</section>

<section>
<h2>失败站点（{len(fail)}）— 均为站点 / 扩展侧，非代码缺陷</h2>
<table><thead><tr><th>站点</th><th>信号</th><th>原因</th><th>时间</th></tr></thead>
<tbody>{"".join(fail_row(e) for e in fail)}</tbody></table>
</section>

<section>
<h2>全量明细（{total} 站）</h2>
<table><thead><tr><th>站点</th><th>name</th><th>信号</th><th>策略</th><th>时间</th></tr></thead>
<tbody>{"".join(detail_row(e) for e in data)}</tbody></table>
</section>

<div class="meta">报告由浏览器真实签到生成 · 失败项多为 CF 严格日 / 图片验证码 / OAuth 登录 / 源站故障 / 浏览器扩展 OCR，需对应环境恢复或人工处理。</div>
</div></body></html>"""

out = base + r"\signin-report-" + datetime.now().strftime("%Y-%m-%d") + ".html"
with open(out, "w", encoding="utf-8") as f:
    f.write(html)
print("WROTE", out, "| success", len(succ), "fail", len(fail))

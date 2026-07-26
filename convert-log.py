#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
convert-log.py — 把 signin-batch.ps1 产出的 signin-log.json 转换成
rerun-cumulative.json（{name, signal, time} 列表），供 gen-report.py 与
push-cumulative.ps1 直接复用，无需改动那两个脚本。

用法:
    python convert-log.py                # 默认读 signin-log.json -> rerun-cumulative.json
    python convert-log.py -i X.json -o Y.json
"""
import json
import argparse
from pathlib import Path

BASE = Path(r"D:\workspace\browswer-daily-signin-cli")

SUCCESS = {"SIGN_OK", "ALREADY_SIGNED", "VISITED"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--in", dest="inp", default=str(BASE / "signin-log.json"),
                    help="signin-batch.ps1 产出的 log（默认 signin-log.json）")
    ap.add_argument("-o", "--out", dest="outp", default=str(BASE / "rerun-cumulative.json"),
                    help="输出文件（默认 rerun-cumulative.json）")
    args = ap.parse_args()

    src = Path(args.inp)
    if not src.exists():
        raise SystemExit(f"找不到输入文件: {src}")
    raw = json.loads(src.read_text(encoding="utf-8"))

    # signin-log.json 结构: {..., "results": [ {index,name,url,strategy,status,signal,elapsed}, ... ]}
    results = raw.get("results") or []
    if not results:
        raise SystemExit("signin-log.json 中 results 为空（可能 batch 被回收，未落盘）")

    out = []
    seen = {}
    for r in results:
        name = r.get("name")
        if not name:
            continue
        sig = r.get("signal") or r.get("status") or ""
        # 时间：batch 结果里没有 time 字段，尝试从 elapsed/其它推导；缺失则留空
        t = r.get("time", "")
        seen[name] = {"name": name, "signal": sig, "time": t}

    out = list(seen.values())

    # 按 sites.json 顺序输出（若存在），否则保持原序
    sites_path = BASE / "sites.json"
    if sites_path.exists():
        try:
            sites = json.loads(sites_path.read_text(encoding="utf-8").lstrip("﻿"))
            order = [s["name"] for s in sites.get("sites", [])]
            out.sort(key=lambda e: order.index(e["name"]) if e["name"] in order else 999)
        except Exception:
            pass

    Path(args.outp).write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")

    ok = sum(1 for e in out if e["signal"] in SUCCESS)
    print(f"转换完成: {args.outp}")
    print(f"  站点总数 {len(out)} | 成功 {ok} | 失败 {len(out) - ok}")


if __name__ == "__main__":
    main()

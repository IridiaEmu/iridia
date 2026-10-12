#!/usr/bin/env python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Compare benchmark runs by label prefix:
#   scripts/bench_compare.py benchmarks/raw base opt1 [opt2 ...]
# Files are "<prefix>-<program>-<run>-game-<timestamp>.json" (label = "<prefix>-<program>-<run>").
# Prints per-program mean maxSpeed / speed / 1% low, the run-to-run spread, and % change vs the first prefix.

import glob
import json
import os
import statistics as st
import sys

raw_dir, prefixes = sys.argv[1], sys.argv[2:]
data = {}  # prefix -> program -> [reports]
for p in prefixes:
    for f in glob.glob(os.path.join(raw_dir, f"{p}-*.json")):
        r = json.load(open(f))
        label = r["label"]
        if not label.startswith(p + "-"):
            continue
        prog = label[len(p) + 1:].rsplit("-", 1)[0]
        data.setdefault(p, {}).setdefault(prog, []).append(r)

programs = sorted({prog for d in data.values() for prog in d})
base = prefixes[0]
print(f"{'program':22s} {'build':8s} {'runs':>4s} {'maxSpeed':>9s} {'spread':>7s} {'vs ' + base:>9s} {'speed':>6s} {'1%low ms':>9s} thermal")
for prog in programs:
    b = data.get(base, {}).get(prog)
    bmean = st.mean(r["maxSpeed"]["mean"] for r in b) if b else None
    for p in prefixes:
        rs = data.get(p, {}).get(prog)
        if not rs:
            continue
        ms = [r["maxSpeed"]["mean"] for r in rs]
        m = st.mean(ms)
        spread = 100 * (max(ms) - min(ms)) / m if m else 0
        delta = f"{100 * (m - bmean) / bmean:+.1f}%" if bmean and p != base else ""
        low = st.mean(r.get("onePercentLowFrameTimeMs", 0) for r in rs)
        th = ",".join(sorted({r["thermalStateEnd"] for r in rs}))
        print(f"{prog:22s} {p:8s} {len(rs):4d} {m:9.3f} {spread:6.1f}% {delta:>9s} {st.mean(r['speed']['mean'] for r in rs):6.3f} {low:9.2f} {th}")

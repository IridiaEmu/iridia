#!/usr/bin/env python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Summarize an xctrace "time-profile" export for one process.
#
#   xcrun xctrace export --input X.trace \
#     --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > X.xml
#   scripts/profile_summary.py X.xml --process iCube --top 25 \
#     --sym PVlibDolphin-ios=path/to/PVlibDolphin-ios --sym iCube=path/to/iCube
#
# Sections: CPU per thread; binaries; top functions by self time; by inclusive time; and
# "attributed": each sample charged to the nearest frame from one of the --sym binaries
# (our code), so time spent in un-symbolicated system libraries shows up under the
# function of ours that called them. --sym binaries are symbolicated with atos using
# each image's load address from the trace (UUIDs must match the device build).

import argparse
import re
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter

ap = argparse.ArgumentParser()
ap.add_argument("xml")
ap.add_argument("--process", default="iCube")
ap.add_argument("--top", type=int, default=25)
ap.add_argument("--sym", action="append", default=[], help="binary-name=path (repeatable)")
ap.add_argument("--thread", default=None, help="only samples whose thread name contains this")
ap.add_argument("--callers-of", default=None, help="show the caller chains of frames whose name contains this")
args = ap.parse_args()

sym_paths = dict(s.split("=", 1) for s in args.sym)

by_id = {}


def index(el):
    if el.get("id") is not None:
        by_id[el.get("id")] = el
    for c in el:
        index(c)


def R(el):
    if el is None:
        return None
    ref = el.get("ref")
    return by_id.get(ref, el) if ref is not None else el


root = ET.parse(args.xml).getroot()
index(root)

rows = []  # (weight, thread, [(name, binary, addr)])
load_addr = {}
for row in root.iter("row"):
    proc = R(row.find("process"))
    if proc is None or args.process not in proc.get("fmt", ""):
        continue
    thr = R(row.find("thread"))
    tname = (thr.get("fmt", "?") if thr is not None else "?").split(" (0x")[0]
    if args.thread and args.thread not in tname:
        continue
    w_el = R(row.find("weight"))
    w = int(w_el.text) if w_el is not None and w_el.text else 1_000_000
    bt = R(row.find("backtrace") if row.find("backtrace") is not None else row.find("tagged-backtrace"))
    frames = []
    if bt is not None:
        for fr in bt.iter("frame"):
            fr = R(fr)
            b = R(fr.find("binary"))
            bname = b.get("name", "?") if b is not None else "?"
            if b is not None and b.get("load-addr"):
                load_addr[bname] = b.get("load-addr")
            frames.append([fr.get("name") or fr.get("addr", "?"), bname, fr.get("addr")])
    rows.append((w, tname, frames))

# Symbolicate our binaries with atos (batched per binary).
for bname, path in sym_paths.items():
    if bname not in load_addr:
        continue
    addrs = sorted({f[2] for _, _, fs in rows for f in fs if f[1] == bname and f[2]})
    if not addrs:
        continue
    out = subprocess.run(
        ["xcrun", "atos", "-o", path, "-arch", "arm64", "-l", load_addr[bname], *addrs],
        capture_output=True, text=True).stdout.splitlines()
    names = {}
    for a, line in zip(addrs, out):
        # "Func(args) (in Binary) (File.cpp:123)" -> "Func(args)"
        n = re.sub(r" \(in [^)]+\)( \(.*\))?$", "", line.strip())
        n = re.sub(r" \+ \d+$", "", n)  # group by function, not by instruction offset
        names[a] = re.sub(r"\(.*\)", "()", n) if n else a
    for _, _, fs in rows:
        for f in fs:
            if f[1] == bname and f[2] in names:
                f[0] = names[f[2]]

total = sum(w for w, _, _ in rows)
pct = lambda v: 100.0 * v / total if total else 0.0
threads, selfc, incl, bins, attr = Counter(), Counter(), Counter(), Counter(), Counter()
ours = set(sym_paths)
for w, t, fs in rows:
    threads[t] += w
    if not fs:
        continue
    selfc[f"{fs[0][0]}  [{fs[0][1]}]"] += w
    bins[fs[0][1]] += w
    seen = set()
    for n, b, _ in fs:
        k = f"{n}  [{b}]"
        if k not in seen:
            incl[k] += w
            seen.add(k)
    owner = next((f for f in fs if f[1] in ours), None)
    if owner is not None:
        via = "" if owner is fs[0] else f"  (via {fs[0][1]})"
        attr[f"{owner[0]}  [{owner[1]}]{via}"] += w

if args.callers_of:
    chains = Counter()
    for w, t, fs in rows:
        for i, (n, b, _) in enumerate(fs):
            if args.callers_of in n:
                chain = " <- ".join(f[0].split("(")[0] for f in fs[i:i + 5])
                chains[chain] += w
                break
    tot = sum(chains.values())
    print(f"== callers of {args.callers_of!r}: {tot/1e9:.2f} s ==")
    for k, v in chains.most_common(args.top):
        print(f"  {100*v/tot if tot else 0:5.1f}%  {k[:220]}")
    raise SystemExit(0)

print(f"process {args.process!r}" + (f" thread~{args.thread!r}" if args.thread else "") + f": {total/1e9:.2f} s CPU sampled")
for title, c, n in [("CPU by thread", threads, 12), ("self time by binary", bins, 10),
                    (f"top {args.top} by self time", selfc, args.top),
                    (f"top {args.top} attributed to our code", attr, args.top),
                    (f"top {args.top} by inclusive time", incl, args.top)]:
    print(f"\n== {title} ==")
    for k, v in c.most_common(n):
        print(f"  {pct(v):5.1f}%  {k[:170]}")

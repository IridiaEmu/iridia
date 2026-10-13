#!/usr/bin/env python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Symbolize a GCEmuProfiler dump (Benchmarks/profile-<label>.txt from the device).
#   scripts/symbolize_profile.py profile.txt --image PVlibDolphin-ios=path/to/PVlibDolphin-ios [--top 40]
# Prints the hottest functions by samples (pc), then by "called from" (lr) for leaf helpers.
import argparse, collections, re, subprocess

ap = argparse.ArgumentParser()
ap.add_argument("dump")
ap.add_argument("--image", action="append", default=[], help="name=path (repeatable)")
ap.add_argument("--top", type=int, default=40)
args = ap.parse_args()
paths = dict(i.split("=", 1) for i in args.image)

rows, total = [], 0
for line in open(args.dump):
    if line.startswith("# samples"):
        total = int(line.split()[2]); continue
    kind, image, off, n = line.split()
    rows.append((kind, image, int(off, 16), int(n)))

def symbolize(image, offsets):
    if image not in paths or not offsets:
        return {o: f"{image}+0x{o:x}" for o in offsets}
    out = subprocess.run(["xcrun", "atos", "-o", paths[image], "-l", "0x0"] + [hex(o) for o in offsets],
                         capture_output=True, text=True).stdout.splitlines()
    names = {}
    for o, name in zip(offsets, out):
        name = re.sub(r" \(in [^)]*\)", "", name)
        name = re.sub(r" \([^()]*:\d+\)$", "", name)          # drop file:line
        names[o] = re.sub(r"\(.*\)$", "()", name)[:110]       # drop argument lists
    return names

for kind, title in (("pc", "where the CPU thread was"), ("lr", "returning into (callers of leaf code)")):
    by_image = collections.defaultdict(list)
    for k, image, off, n in rows:
        if k == kind: by_image[image].append(off)
    names = {}
    for image, offs in by_image.items():
        for o, nm in symbolize(image, sorted(set(offs))).items(): names[(image, o)] = nm
    agg = collections.Counter()
    for k, image, off, n in rows:
        if k == kind: agg[names[(image, off)]] += n
    print(f"\n== {title} ({total} samples) ==")
    for name, n in agg.most_common(args.top):
        print(f"{100.0 * n / max(total, 1):6.2f}%  {name}")

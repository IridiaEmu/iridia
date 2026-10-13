#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Interleaved A/B of any Dolphin config keys (Dolphin.ini or GFX.ini), on the installed app.
#   scripts/ini_ab.sh <rounds> <cooldown-s> "labelA:" "labelB:GFX/Settings/InternalResolution=3,GFX/Hacks/X=True" ...
# Each round runs every variant once, in order. The original INI files are always restored.
# Optional env: PLAY_ID (default GZ2E01), BENCH_EXTRA (default "-gcemuBenchState GZ2E01.s01"),
# BENCH_SECS / BENCH_WARMUP (default 20 / 15). Results go to benchmarks/raw/; summary printed at the end.

set -uo pipefail
ROUNDS="$1"; COOL="$2"; shift 2
BUNDLE="${GCEMU_BUNDLE:-com.yl4f87nwp8.gcemu.iCube}"
UDIR="${GCEMU_USERDIR:-Library/Application Support/Iridia}"
PLAY_ID="${PLAY_ID:-GZ2E01}"
read -r -a EXTRA <<< "${BENCH_EXTRA--gcemuBenchState GZ2E01.s01}"
SECS="${BENCH_SECS:-20}"; WARMUP="${BENCH_WARMUP:-15}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/benchmarks/raw"; mkdir -p "$OUT"
WORK="$(mktemp -d)"
TAG="ab$(date +%H%M%S)"
# The device must be named: GCEMU_DEVICE=<UDID> (a paired phone can show up over Wi-Fi, so never guess).
UDID="${GCEMU_DEVICE:-}"
[[ -n "$UDID" ]] || { echo "set GCEMU_DEVICE=<UDID>; devices:" >&2; xcrun devicectl list devices 2>/dev/null | grep physical >&2; exit 2; }
dc() { xcrun devicectl device copy "$@" --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" >/dev/null 2>&1; }
for f in Dolphin GFX; do
  dc from --source "$UDIR/Config/$f.ini" --destination "$WORK/$f.orig" || { echo "can't read $f.ini" >&2; exit 2; }
done
trap 'for f in Dolphin GFX; do dc to --source "$WORK/$f.orig" --destination "$UDIR/Config/$f.ini"; done; rm -rf "$WORK"' EXIT

make_ini() {  # $1 = file (Dolphin|GFX), $2 = out file, $3 = comma-separated File/Section/Key=Value list
  python3 -I - "$WORK/$1.orig" "$2" "$1" "$3" <<'EOF'
import sys
src, dst, fname, spec = sys.argv[1:5]
want = {}
for a in filter(None, spec.split(",")):
    path, val = a.split("=", 1); f, sec, key = path.split("/")
    if f == fname: want.setdefault(sec, {})[key] = val
out, section = [], None
lines = open(src).read().splitlines()
for line in lines:
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        section = s[1:-1]; out.append(line)
        out += [f"{k} = {v}" for k, v in want.get(section, {}).items()]
        continue
    if "=" in s and s.split("=", 1)[0].strip() in want.get(section, {}): continue
    out.append(line)
present = {l.strip()[1:-1] for l in lines if l.strip().startswith("[")}
for sec, kv in want.items():
    if sec not in present: out += [f"[{sec}]"] + [f"{k} = {v}" for k, v in kv.items()]
open(dst, "w").write("\n".join(out) + "\n")
EOF
}

i=0
for v in "$@"; do
  for f in Dolphin GFX; do make_ini "$f" "$WORK/$f.v$i" "${v#*:}"; done; i=$((i+1))
done

for r in $(seq 1 "$ROUNDS"); do
  i=0
  for v in "$@"; do
    label="$TAG-${v%%:*}"
    for f in Dolphin GFX; do dc to --source "$WORK/$f.v$i" --destination "$UDIR/Config/$f.ini"; done
    sleep "$COOL"
    xcrun devicectl device process launch --device "$UDID" --terminate-existing \
      --payload-url "dolphinios://play?id=$PLAY_ID" "$BUNDLE" \
      -- -gcemuBench "$SECS" -gcemuBenchWarmup "$WARMUP" -gcemuBenchLabel "$label-$r" -iridiaUnlocked YES \
      ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null 2>&1
    sleep $(( SECS + WARMUP + 15 ))
    echo "round $r: ${v%%:*}"
    i=$((i+1))
  done
done

xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --subdirectory "$UDIR/Benchmarks" 2>/dev/null | grep -oE "$TAG-[^ ]+\.json" | sort -u | while read -r f; do
  dc from --source "$UDIR/Benchmarks/$f" --destination "$OUT/$f"
done

python3 -I - "$OUT" "$TAG" "$@" <<'EOF'
import json, os, sys, statistics as st
out, tag, variants = sys.argv[1], sys.argv[2], [v.split(":", 1)[0] for v in sys.argv[3:]]
print(f"{'variant':<14} {'runs':>4} {'speed':>6} {'headroom':>8} {'ft p50':>7} {'ft p99':>7} {'1% low':>7} {'hitches':>7} {'cpu%':>5} {'therm'}")
for v in variants:
    rs = [json.load(open(os.path.join(out, f))) for f in sorted(os.listdir(out)) if f.startswith(f"{tag}-{v}-")]
    if not rs: print(f"{v:<14} no reports"); continue
    m = lambda g: st.mean(g(r) for r in rs)
    print(f"{v:<14} {len(rs):>4} {m(lambda r: r['speed']['p50']):>6.3f} {m(lambda r: r['maxSpeed']['p50']):>8.2f}"
          f" {m(lambda r: r['frameTimeMs']['p50']):>7.1f} {m(lambda r: r['frameTimeMs'].get('p99', 0)):>7.1f}"
          f" {m(lambda r: r['onePercentLowFrameTimeMs']):>7.1f} {m(lambda r: r.get('hitches', -1)):>7.1f} {m(lambda r: r.get('cpuPercent', -1)):>5.0f}"
          f" {','.join(r['thermalStateEnd'] for r in rs)}")
EOF

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Interleaved A/B of Dolphin [Core] settings (cancels thermal drift).
#   scripts/cir_ab_interleaved.sh <program-id> <rounds> <cooldown-s> "labelA:" "labelB:Key=V,Key2=V" ...
# Each round runs every variant once, in order, with <cooldown-s> seconds of idle before
# each run. The original Dolphin.ini is always restored. Compare with bench_compare.py.

set -uo pipefail
PROG="$1"; ROUNDS="$2"; COOL="$3"; shift 3
BUNDLE="${GCEMU_BUNDLE:-com.yl4f87nwp8.gcemu.iCube}"
# App user folder inside the container (hidden from Files; see UserFolderUtil.swift).
UDIR="${GCEMU_USERDIR:-Library/Application Support/Iridia}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/benchmarks/raw"
WORK="$(mktemp -d)"
UDID=$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
[[ -n "$UDID" ]] || { echo "no device connected" >&2; exit 2; }
dc() { xcrun devicectl device copy "$@" --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" >/dev/null 2>&1; }
dc from --source "$UDIR/Config/Dolphin.ini" --destination "$WORK/orig.ini" || { echo "can't read Dolphin.ini" >&2; exit 2; }
trap 'dc to --source "$WORK/orig.ini" --destination "$UDIR/Config/Dolphin.ini"; rm -rf "$WORK"' EXIT

make_ini() {  # $1 = out file, $2 = comma-separated Key=Value list (may be empty)
  python3 -I - "$WORK/orig.ini" "$1" "$2" <<'EOF'
import sys
src, dst, spec = sys.argv[1], sys.argv[2], sys.argv[3]
keys = dict(a.split("=", 1) for a in spec.split(",") if a)
lines, out, section = open(src).read().splitlines(), [], None
for line in lines:
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        section = s; out.append(line)
        if s == "[Core]": out += [f"{k} = {v}" for k, v in keys.items()]
        continue
    if section == "[Core]" and "=" in s and s.split("=", 1)[0].strip() in keys: continue
    out.append(line)
if "[Core]" not in (l.strip() for l in lines): out += ["[Core]"] + [f"{k} = {v}" for k, v in keys.items()]
open(dst, "w").write("\n".join(out) + "\n")
EOF
}

i=0
for v in "$@"; do make_ini "$WORK/v$i.ini" "${v#*:}"; i=$((i+1)); done

for r in $(seq 1 "$ROUNDS"); do
  i=0
  for v in "$@"; do
    label="${v%%:*}"
    dc to --source "$WORK/v$i.ini" --destination "$UDIR/Config/Dolphin.ini"
    sleep "$COOL"
    xcrun devicectl device process launch --device "$UDID" --terminate-existing \
      --payload-url "dolphinios://play?id=ID-$PROG" "$BUNDLE" \
      -- -gcemuBench 15 -gcemuBenchWarmup 5 -gcemuBenchLabel "$label-$PROG-$r" >/dev/null 2>&1
    sleep 28
    echo "round $r: $label"
    i=$((i+1))
  done
done

xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --subdirectory "$UDIR/Benchmarks" 2>/dev/null | grep -oE "[A-Za-z0-9]+-$PROG-[0-9]+-[^ ]+\.json" | while read -r f; do
  [[ -e "$OUT/$f" ]] || dc from --source "$UDIR/Benchmarks/$f" --destination "$OUT/$f"
done

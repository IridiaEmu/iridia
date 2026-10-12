#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# A/B Dolphin [Core] settings on the device with benchmark mode.
#   scripts/cir_ab.sh <label> <program-id> <runs> [Key=Value ...]
# e.g. scripts/cir_ab.sh fprf iridiabench-x16 3 CIRDeadFprfElim=True
# Sets the keys in Documents/Config/Dolphin.ini [Core], runs <runs> benchmarks
# (labels "<label>-<program>-<n>"), copies results to benchmarks/raw/, and always
# restores the original Dolphin.ini afterwards.

set -uo pipefail
LABEL="$1"; PROG="$2"; RUNS="$3"; shift 3
BUNDLE="${GCEMU_BUNDLE:-com.yl4f87nwp8.gcemu.iCube}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/benchmarks/raw"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UDID=$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
[[ -n "$UDID" ]] || { echo "no device connected" >&2; exit 2; }
dc() { xcrun devicectl device copy "$@" --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" >/dev/null 2>&1; }

dc from --source Documents/Config/Dolphin.ini --destination "$WORK/orig.ini" || { echo "can't read Dolphin.ini" >&2; exit 2; }
restore() { dc to --source "$WORK/orig.ini" --destination Documents/Config/Dolphin.ini; }
trap 'restore; rm -rf "$WORK"' EXIT

# Insert/override keys right after the [Core] header.
python3 -I - "$WORK/orig.ini" "$WORK/test.ini" "$@" <<'EOF'
import sys
src, dst, kv = sys.argv[1], sys.argv[2], sys.argv[3:]
keys = dict(a.split("=", 1) for a in kv)
lines, out, section = open(src).read().splitlines(), [], None
for line in lines:
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        section = s
        out.append(line)
        if s == "[Core]":
            out += [f"{k} = {v}" for k, v in keys.items()]
        continue
    if section == "[Core]" and "=" in s and s.split("=", 1)[0].strip() in keys:
        continue  # replaced above
    out.append(line)
if "[Core]" not in (l.strip() for l in lines):
    out += ["[Core]"] + [f"{k} = {v}" for k, v in keys.items()]
open(dst, "w").write("\n".join(out) + "\n")
EOF
dc to --source "$WORK/test.ini" --destination Documents/Config/Dolphin.ini

for n in $(seq 1 "$RUNS"); do
  xcrun devicectl device process launch --device "$UDID" --terminate-existing \
    --payload-url "dolphinios://play?id=ID-$PROG" "$BUNDLE" \
    -- -gcemuBench 15 -gcemuBenchWarmup 5 -gcemuBenchLabel "$LABEL-$PROG-$n" >/dev/null 2>&1
  sleep 30
done

xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --subdirectory Documents/Benchmarks 2>/dev/null | grep -oE "$LABEL-$PROG-[0-9]+-[^ ]+\.json" | while read -r f; do
  dc from --source "Documents/Benchmarks/$f" --destination "$OUT/$f"
done
echo "done: $LABEL ($*)"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Device smoke test: boots each program on the connected iPhone in benchmark mode and checks that it
# renders frames at full speed. Uses the app that is already installed.
#   scripts/smoke_test.sh [program-stem ...]        (default: the homebrew set below)
# Disc games: SMOKE_DISC="GZ2E01:GZ2E01.s01" (game ID, optional save state) adds one disc run.
# Results go to benchmarks/smoke/<run>/; exit status 1 if any program fails.

set -uo pipefail
BUNDLE="${GCEMU_BUNDLE:-com.yl4f87nwp8.gcemu.iCube}"
UDIR="${GCEMU_USERDIR:-Library/Application Support/Iridia}"
SECS="${SMOKE_SECS:-8}"; WARMUP="${SMOKE_WARMUP:-4}"; COOL="${SMOKE_COOL:-5}"
MIN_SPEED="${SMOKE_MIN_SPEED:-0.95}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="smoke-$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/benchmarks/smoke/$RUN"; mkdir -p "$OUT"
# The device must be named: GCEMU_DEVICE=<UDID> (a paired phone can show up over Wi-Fi, so never guess).
UDID="${GCEMU_DEVICE:-}"
[[ -n "$UDID" ]] || { echo "set GCEMU_DEVICE=<UDID>; devices:" >&2; xcrun devicectl list devices 2>/dev/null | grep physical >&2; exit 2; }

PROGS=("$@")
[[ ${#PROGS[@]} -gt 0 ]] || PROGS=(gx-triangle gx-gxSprites gx-neheGX-lesson06 fb-consoletest modplay iridiabench-x1)
NO_VIDEO=" modplay "  # audio-only programs: they never present a frame, so only speed is checked

# Headroom (maxSpeed) depends on the internal resolution, so print it with the results.
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source "$UDIR/Config/GFX.ini" --destination "$OUT/GFX.ini" >/dev/null 2>&1
echo "internal resolution: $(grep -E '^InternalResolution' "$OUT/GFX.ini" 2>/dev/null | grep -oE '[0-9]+' || echo '?')x"

launch() {  # $1 play id, $2 label, $3.. extra args
  local id="$1" label="$2"; shift 2
  xcrun devicectl device process launch --device "$UDID" --terminate-existing \
    --payload-url "dolphinios://play?id=$id" "$BUNDLE" \
    -- -gcemuBench "$SECS" -gcemuBenchWarmup "$WARMUP" -gcemuBenchLabel "$label" -iridiaUnlocked YES "$@" >/dev/null 2>&1
  sleep $(( SECS + WARMUP + 12 ))
  local f
  f=$(xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --subdirectory "$UDIR/Benchmarks" 2>/dev/null | grep -oE "$label-[^ ]+\.json" | tail -1)
  if [[ -z "$f" ]]; then echo "FAIL  $label  (no benchmark report: did not boot or crashed)"; return 1; fi
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$UDIR/Benchmarks/$f" --destination "$OUT/$f" >/dev/null 2>&1
  local video=1; [[ "$NO_VIDEO" == *" ${label#"$RUN"-} "* ]] && video=0
  python3 -I - "$OUT/$f" "$MIN_SPEED" "$label" "$video" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); floor = float(sys.argv[2]); label = sys.argv[3]; video = sys.argv[4] == "1"
speeds = [s["speed"] for s in d.get("samples", [])]
speed = sorted(speeds)[len(speeds) // 2] if speeds else 0.0
ok = (d.get("frames", 0) > 0 or not video) and speed >= floor
print(f"{'PASS' if ok else 'FAIL'}  {label}  frames={d.get('frames', 0)} speed={speed:.2f}x "
      f"fps={d['fps']['mean']:.1f} maxSpeed={d['maxSpeed']['p50']:.2f}x")
sys.exit(0 if ok else 1)
PY
}

fails=0
for p in "${PROGS[@]}"; do
  launch "ID-$p" "$RUN-$p" || fails=$((fails + 1)); sleep "$COOL"
done
if [[ -n "${SMOKE_DISC:-}" ]]; then
  gid="${SMOKE_DISC%%:*}"; state="${SMOKE_DISC#*:}"; extra=()
  [[ "$state" != "$SMOKE_DISC" && -n "$state" ]] && extra=(-gcemuBenchState "$state")
  launch "$gid" "$RUN-$gid" ${extra[@]+"${extra[@]}"} || fails=$((fails + 1))
fi
xcrun devicectl device process terminate --device "$UDID" --pid 0 >/dev/null 2>&1 || true
echo "$fails failure(s); reports in benchmarks/smoke/$RUN"
[[ $fails -eq 0 ]]

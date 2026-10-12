#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Interleaved A/B of two app builds (same bundle id, so app data is kept between installs).
#   scripts/build_ab.sh <A.app> <labelA> <B.app> <labelB> <program-id> <rounds> <cooldown-s>
# Each round: install A, cool down, run; install B, cool down, run. Results go to benchmarks/raw/.

set -uo pipefail
A_APP="$1"; A_LABEL="$2"; B_APP="$3"; B_LABEL="$4"; PROG="$5"; ROUNDS="$6"; COOL="$7"
BUNDLE="${GCEMU_BUNDLE:-com.yl4f87nwp8.gcemu.iCube}"
# App user folder inside the container (hidden from Files; see UserFolderUtil.swift).
UDIR="${GCEMU_USERDIR:-Library/Application Support/Iridia}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID=$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
[[ -n "$UDID" ]] || { echo "no device connected" >&2; exit 2; }

for app in "$A_APP" "$B_APP"; do
  "$ROOT/scripts/verify_no_jit.sh" --dev "$app" >/dev/null || { echo "verify_no_jit failed for $app" >&2; exit 1; }
done

run() {  # $1 app, $2 label, $3 round
  xcrun devicectl device install app --device "$UDID" "$1" >/dev/null 2>&1 || { echo "install failed: $1" >&2; exit 1; }
  sleep "$COOL"
  xcrun devicectl device process launch --device "$UDID" --terminate-existing \
    --payload-url "dolphinios://play?id=ID-$PROG" "$BUNDLE" \
    -- -gcemuBench 15 -gcemuBenchWarmup 5 -gcemuBenchLabel "$2-$PROG-$3" >/dev/null 2>&1
  sleep 28
  echo "round $3: $2"
}

for r in $(seq 1 "$ROUNDS"); do
  run "$A_APP" "$A_LABEL" "$r"
  run "$B_APP" "$B_LABEL" "$r"
done

xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --subdirectory "$UDIR/Benchmarks" 2>/dev/null | grep -oE "($A_LABEL|$B_LABEL)-$PROG-[0-9]+-[^ ]+\.json" | while read -r f; do
  [[ -e "$ROOT/benchmarks/raw/$f" ]] || xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source "$UDIR/Benchmarks/$f" --destination "$ROOT/benchmarks/raw/$f" >/dev/null 2>&1
done

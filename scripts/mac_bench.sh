#!/bin/bash
# gc-emu: Mac test runner benchmark (build-mac/Binaries/dolphin-emu-nogui, headless, no JIT).
#   scripts/mac_bench.sh <file> [seconds=20] [warmup=6] [extra dolphin -C/-v options...]
# Prints the median maxSpeed (headroom) and speed over the seconds after the warm-up.
# Env: MAC_BENCH_BIN (runner binary), MAC_BENCH_USER (user folder, default build-mac/user-test), MAC_BENCH_VIDEO (default Metal).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
file="$1"; secs="${2:-20}"; warm="${3:-6}"; shift; shift || true; shift || true
user="${MAC_BENCH_USER:-$here/build-mac/user-test}"
video="${MAC_BENCH_VIDEO:-Metal}"
log="$(mktemp -t macbench)"
# IridiaBench builds export their frame counter; find it in the .elf next to the build.
elf="$(dirname "$file")/build-$(basename "$file" .dol)/$(basename "$file" .dol).elf"
counter=""
check=""
if [ -f "$elf" ]; then
  counter="$(/opt/devkitpro/devkitPPC/bin/powerpc-eabi-nm "$elf" | awk '$3=="iridia_bench_frames"{print $1}')"
  check="$(/opt/devkitpro/devkitPPC/bin/powerpc-eabi-nm "$elf" | awk '$3=="iridia_bench_check"{print $1}')"
fi
IRIDIA_NOGUI_COUNTER="$counter" IRIDIA_NOGUI_CHECK="$check" IRIDIA_NOGUI_STATS=1 IRIDIA_NOGUI_SECONDS="$secs" "${MAC_BENCH_BIN:-$here/build-mac/Binaries/dolphin-emu-nogui}" \
  -p headless -u "$user" -v "$video" -C Dolphin.Core.CPUCore=5 "$@" -e "$file" >"$log" 2>&1
python3 - "$log" "$warm" "$(basename "$file")" <<'PY'
import re, statistics, sys
log, warm, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
text = open(log).read()
checks = re.findall(r"check=(\w+)", text)
check = checks[-1] if checks and checks[-1] != "00000000" else "-"
rows = [tuple(float(x) for x in m.groups()[:6]) for m in
        re.finditer(r"t=(\d+) fps=([\d.]+) vps=([\d.]+) speed=([\d.]+) max=([\d.]+) count=(\d+) check=(\w+)", open(log).read())]
rows = [r for r in rows if r[0] > warm]
if not rows:
    print(f"{name}: no stats (see {log})"); sys.exit(1)
frames = ""
if rows[-1][5] > 0 and len(rows) > 1:
    per_s = (rows[-1][5] - rows[0][5]) / (rows[-1][0] - rows[0][0])
    med_speed = statistics.median(r[3] for r in rows)
    ms = 1000.0 / statistics.median(r[4] for r in rows) / (per_s / med_speed)
    frames = f" frames/s {per_s:.2f} (per emulated s {per_s / med_speed:.2f}, host {ms:.2f} ms/frame)"
print(f"{name}: maxSpeed {statistics.median(r[4] for r in rows):.4f} speed {statistics.median(r[3] for r in rows):.4f}{frames} check {check} (n={len(rows)})")
PY

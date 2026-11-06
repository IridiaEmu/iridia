#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Checks that a Cemu binary can't generate code at run time (CEMU_NO_JIT build).
#   Externals/Cemu/ios/verify_no_jit.sh <path to the Cemu binary or IridiaCafeCore framework binary> [pid of a running Cemu to inspect]
# Static: no recompiler backend symbols, no xbyak (code emitter), no JIT/W^X APIs, no-JIT marker present.
# Runtime (with a pid): no anonymous executable memory (only code that came from mapped files).

set -uo pipefail
BIN="$1"; PID="${2:-}"
fail=0
check_absent() {  # $1 description, $2 regex over `nm -m` output
  local hits; hits=$(nm -m "$BIN" 2>/dev/null | grep -E "$2" | head -3)
  if [[ -n "$hits" ]]; then echo "FAIL  $1:"; echo "$hits" | sed 's/^/        /'; fail=1; else echo "ok    $1"; fi
}
check_absent "no ARM64 recompiler backend" "PPCRecompiler_generateAArch64Code|PPCRecompilerAArch64Gen|AArch64GenContext"
check_absent "no x86 recompiler backend" "PPCRecompiler_generateX64Code|PPCRecompilerX64Gen|x64GenContext"
check_absent "no xbyak code emitter" "Xbyak"
check_absent "no JIT write-protect API" "_pthread_jit_write_protect"
check_absent "no MAP_JIT helpers" "_pthread_jit_write_with_callback"
# the negative-control hook (maps an executable page on request) must be compiled out of every normal build
# (grep -c, not -q: with pipefail, -q exiting early makes strings fail with SIGPIPE and a hit reads as a miss)
if [[ $(strings "$BIN" | grep -c "IRIDIA_NOJIT_TEST_ALLOC") -gt 0 ]]; then echo "FAIL  no-JIT negative-control hook compiled in (IRIDIA_NOJIT_NEGATIVE_CONTROL build)"; fail=1; else echo "ok    no negative-control hook"; fi
if [[ $(strings "$BIN" | grep -c "No-JIT build: recompiler not available") -gt 0 ]]; then echo "ok    no-JIT marker present"; else echo "FAIL  no-JIT marker missing (not a CEMU_NO_JIT build?)"; fail=1; fi
if [[ -n "$PID" ]]; then
  # Executable regions that aren't backed by a file = code made at run time.
  # vmmap can hang on a busy process: give it 90 s, and count a timeout or error as a failure (never a pass).
  VM=$(mktemp); vmmap -wide "$PID" > "$VM" 2>/dev/null & VMPID=$!
  for _ in $(seq 1 90); do kill -0 $VMPID 2>/dev/null || break; sleep 1; done
  if kill -0 $VMPID 2>/dev/null; then kill $VMPID 2>/dev/null; echo "FAIL  vmmap timed out on pid $PID (runtime check not done)"; fail=1; fi
  wait $VMPID 2>/dev/null; vmrc=$?
  if [[ $vmrc -ne 0 || ! -s "$VM" ]] && [[ $fail -eq 0 ]]; then echo "FAIL  vmmap failed on pid $PID (runtime check not done)"; fail=1; fi
  anon=$(cat "$VM" | awk '/^==== Writable|^==== Non-writable/{s=1} s' | grep -E " r[w-]x/" | grep -vE "\.dylib|\.framework|/Cemu_release|dyld|__TEXT|commpage|/usr/lib|/System/" | head -5); rm -f "$VM"
  if [[ -n "$anon" ]]; then echo "FAIL  anonymous executable memory in pid $PID:"; echo "$anon" | sed 's/^/        /'; fail=1; else echo "ok    no anonymous executable memory in pid $PID"; fi
fi
[[ $fail -eq 0 ]] && echo "RESULT: PASS (no JIT)" || echo "RESULT: FAIL"
exit $fail

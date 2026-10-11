#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# verify_no_jit.sh: prove a built .app (or .ipa) contains no JIT.
#
#   scripts/verify_no_jit.sh path/to/App.app            # release / App Store check
#   scripts/verify_no_jit.sh --dev path/to/App.app      # allow get-task-allow (development signing)
#   scripts/verify_no_jit.sh path/to/App.ipa
#
# Checks every Mach-O in the bundle (app, frameworks, extensions):
#   1. Entitlements: no JIT / executable-memory / debugger / private entitlements.
#   2. Imported symbols: no W^X toggles, dual-mapping, ptrace or code-signing probes.
#   3. Defined symbols and strings: no JIT backends, code emitters, TXM/StikDebug paths.
#   4. The emulation core carries the GCEMU_NO_JIT build marker.
#   5. No JIT helper files (broker scripts, LLDB hooks) are bundled.
# Exit status 0 = clean. Any finding prints FAIL and exits 1.

set -uo pipefail

DEV=0
if [[ "${1:-}" == "--dev" ]]; then DEV=1; shift; fi
TARGET="${1:-}"
if [[ -z "$TARGET" || ! -e "$TARGET" ]]; then
  echo "usage: $0 [--dev] path/to/App.app|App.ipa" >&2
  exit 2
fi

WORK=""
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

if [[ "$TARGET" == *.ipa ]]; then
  WORK="$(mktemp -d)"
  unzip -q "$TARGET" -d "$WORK"
  APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
else
  APP="$TARGET"
fi
[[ -d "$APP" ]] || { echo "no .app found in $TARGET" >&2; exit 2; }

FAILS=0
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "  ok:   $*"; }

# --- Patterns ---------------------------------------------------------------

# Entitlements that enable JIT, executable memory, debugging or private APIs.
BAD_ENTITLEMENTS=(
  dynamic-codesigning
  com.apple.security.cs.allow-jit
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.disable-executable-page-protection
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.private.
  platform-application
  run-unsigned-code
)

# Imported functions only JIT / JIT-acquisition code needs.
# Not listed: vm_remap. MemArenaDarwin's "Remap" mode uses it for read/write views of emulated
# RAM (fastmem), which is data, never code. JIT dual-mapping is caught by name in step 3
# (AllocateWritableRegionAndGetDiff, LuckNoTXM), and writing then running code would need
# sys_icache_invalidate, which is checked here.
BAD_IMPORTS='^_(pthread_jit_write_protect_np|pthread_jit_write_with_callback_np|pthread_jit_write_freeze_callbacks_np|ptrace|csops|csops_audittoken|sys_icache_invalidate|sys_dcache_flush)$'

# Defined symbols (demangled) from JIT backends, emitters, executable memory, TXM/debugger paths.
BAD_SYMBOLS='JitArm64|Jit64|Arm64Gen::|ARM64XEmitter|ARM64CodeBlock|VertexLoaderARM64|VertexLoaderX64|AllocateExecutableMemory|AllocateWritableRegionAndGetDiff|JITPageWrite(Enable|Disable)|LuckTXM|LuckNoTXM|IsTXMAvailable|SetJitType|JitManager|StikDebug|JITMemoryTracker'

# Strings that only exist for JIT acquisition.
BAD_STRINGS='stikdebug://|StikDebug|jit-help|Waiting for JIT|Enable JIT via|TXM JIT|dolphin_jit_lldb|brk #0x69|JIT Recompiler for ARM64'

# --- Collect Mach-O files ---------------------------------------------------

MACHOS=()
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then MACHOS+=("$f"); fi
done < <(find "$APP" -type f -print0)

echo "verify_no_jit: $(basename "$APP")  ($([[ $DEV == 1 ]] && echo development || echo release) mode, ${#MACHOS[@]} Mach-O files)"

# --- 1. Entitlements --------------------------------------------------------
echo "[1] entitlements"
for f in "${MACHOS[@]}"; do
  rel="${f#$APP/}"
  ents="$(codesign -d --entitlements - --xml "$f" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
  [[ -z "$ents" ]] && continue
  for bad in "${BAD_ENTITLEMENTS[@]}"; do
    if grep -q "<key>${bad}" <<<"$ents"; then fail "$rel has entitlement ${bad}"; fi
  done
  if grep -q '<key>get-task-allow</key>' <<<"$ents" && grep -A1 '<key>get-task-allow</key>' <<<"$ents" | grep -q '<true/>'; then
    if [[ $DEV == 1 ]]; then echo "  note: $rel has get-task-allow (allowed with --dev only)"
    else fail "$rel has get-task-allow (debuggable; not allowed in release)"; fi
  fi
done
[[ $FAILS == 0 ]] && pass "no JIT, executable-memory, debugger or private entitlements"

# --- 2. Imported symbols ----------------------------------------------------
echo "[2] imported symbols"
before=$FAILS
for f in "${MACHOS[@]}"; do
  rel="${f#$APP/}"
  hits="$(nm -u "$f" 2>/dev/null | grep -E "$BAD_IMPORTS" | sort -u | tr '\n' ' ')"
  [[ -n "$hits" ]] && fail "$rel imports: $hits"
done
[[ $FAILS == "$before" ]] && pass "no W^X toggles, ptrace, csops or icache flushes"

# --- 3. Defined symbols and strings ----------------------------------------
echo "[3] defined symbols and strings"
before=$FAILS
for f in "${MACHOS[@]}"; do
  rel="${f#$APP/}"
  syms="$(nm -C -U "$f" 2>/dev/null | grep -E "$BAD_SYMBOLS" | awk '{$1=$2=""; print}' | sort -u | head -5 | tr '\n' ';')"
  [[ -n "$syms" ]] && fail "$rel defines JIT symbols: $syms"
  strs="$(strings -a "$f" 2>/dev/null | grep -E "$BAD_STRINGS" | sort -u | head -5 | tr '\n' ';')"
  [[ -n "$strs" ]] && fail "$rel contains JIT strings: $strs"
done
[[ $FAILS == "$before" ]] && pass "no JIT backends, emitters, TXM or StikDebug code"

# --- 4. Core build marker ---------------------------------------------------
echo "[4] core build marker"
if grep -rqa 'gcemu-no-jit-v1' "$APP" 2>/dev/null; then
  pass "emulation core was built with GCEMU_NO_JIT"
else
  fail "GCEMU_NO_JIT marker (gcemu-no-jit-v1) not found; the core may be a JIT build"
fi

# --- 5. Bundled helper files -----------------------------------------------
echo "[5] bundled files"
before=$FAILS
while IFS= read -r -d '' f; do
  fail "bundled JIT helper: ${f#$APP/}"
done < <(find "$APP" -type f \( -iname 'icube.js' -o -iname '*jit*.py' -o -iname '*lldbinit*' -o -iname '*stikdebug*' -o -iname 'universal.js' \) -print0)
[[ $FAILS == "$before" ]] && pass "no broker scripts or LLDB hooks"

echo
if [[ $FAILS == 0 ]]; then
  echo "RESULT: PASS (no JIT)"
  exit 0
else
  echo "RESULT: FAIL ($FAILS finding(s))"
  exit 1
fi

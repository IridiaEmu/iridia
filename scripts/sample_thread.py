#!/usr/bin/env python3
# gc-emu: summarize one thread of a macOS `sample` report.
#   scripts/sample_thread.py <report.txt> [thread name, default "CPU thread"] [top N]
# Prints the thread's self time by function, plus inclusive time for chosen subsystems.
import re, sys, collections
path = sys.argv[1]; want = sys.argv[2] if len(sys.argv) > 2 else "CPU thread"
top = int(sys.argv[3]) if len(sys.argv) > 3 else 25
lines = open(path, errors="replace").read().splitlines()
start = None
for i, l in enumerate(lines):
    if re.match(r"^\s+\d+ Thread_\d+.*" + re.escape(want), l):
        start = i; break
if start is None:
    sys.exit(f"thread {want!r} not found")
base = len(lines[start]) - len(lines[start].lstrip())
nodes = []  # (depth, count, name)
for l in lines[start + 1:]:
    m = re.match(r"^([\s+!:|]*)(\d+) (.*)$", l)
    if not m:
        break
    depth = len(m.group(1))
    if depth <= base:
        break
    name = re.sub(r"\s+\(in [^)]*\).*$", "", m.group(3)).strip()
    nodes.append((depth, int(m.group(2)), name))
total = int(re.match(r"^\s+(\d+)", lines[start]).group(1))
self_t = collections.Counter(); incl = collections.Counter()
for i, (d, c, n) in enumerate(nodes):
    child = 0
    for d2, c2, _ in nodes[i + 1:]:
        if d2 <= d: break
        if child == 0 or True:
            pass
    # children are the next nodes with the smallest depth greater than d
    j = i + 1; kids = 0; kd = None
    while j < len(nodes) and nodes[j][0] > d:
        if kd is None: kd = nodes[j][0]
        if nodes[j][0] == kd: kids += nodes[j][1]
        j += 1
    self_t[n] += c - kids
# inclusive: count each sample once per function (outermost occurrence on each path)
stack = []
for d, c, n in nodes:
    while stack and stack[-1][0] >= d: stack.pop()
    if not any(s[1] == n for s in stack):
        incl[n] += c
    stack.append((d, n))
busy = total - sum(v for k, v in self_t.items() if k.startswith(("__psynch", "__semwait", "__workq", "mach_msg", "swtch_pri", "__ulock")))
print(f"{want}: {total} samples, busy (not waiting) {busy} = {100*busy/total:.1f}%")
for n, c in self_t.most_common(top):
    print(f"  {100*c/total:5.1f}%  {n[:110]}")
groups = {"IOS HLE (IOS::HLE::*)": "IOS::HLE::", "Wii Remote emulation (WiimoteEmu)": "WiimoteEmu::",
          "Bluetooth emu (BluetoothEmuDevice)": "BluetoothEmu", "CoreTiming::Advance": "CoreTiming::CoreTimingManager::Advance",
          "CoreTiming::Idle": "CoreTiming::CoreTimingManager::Idle", "WiiIPC": "IOS::WiiIPC", "SystemTimers": "SystemTimers",
          "VideoInterface": "VideoInterface::", "DSP HLE": "DSP::HLE::", "ProcessorInterface": "ProcessorInterface"}
print("inclusive:")
for label, key in groups.items():
    v = sum(c for n, c in incl.items() if key in n)
    print(f"  {100*v/total:5.1f}%  {label}")

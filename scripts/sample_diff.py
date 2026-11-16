#!/usr/bin/env python3
# gc-emu: diff the self time of one thread between two macOS `sample` reports (same duration).
#   scripts/sample_diff.py <a.txt> <b.txt> [thread name] [top N]
import re, sys, collections
def selfcounts(path, want):
    lines = open(path, errors="replace").read().splitlines()
    start = next(i for i, l in enumerate(lines) if re.match(r"^\s+\d+ Thread_\d+.*" + re.escape(want), l))
    base = len(lines[start]) - len(lines[start].lstrip())
    nodes = []
    for l in lines[start + 1:]:
        m = re.match(r"^([\s+!:|]*)(\d+) (.*)$", l)
        if not m or len(m.group(1)) <= base: break
        nodes.append((len(m.group(1)), int(m.group(2)), re.sub(r"\s+\(in [^)]*\).*$", "", m.group(3)).strip()))
    out = collections.Counter()
    for i, (d, c, n) in enumerate(nodes):
        j = i + 1; kids = 0; kd = None
        while j < len(nodes) and nodes[j][0] > d:
            if kd is None: kd = nodes[j][0]
            if nodes[j][0] == kd: kids += nodes[j][1]
            j += 1
        out[n] += c - kids
    return out
want = sys.argv[3] if len(sys.argv) > 3 else "CPU thread"; top = int(sys.argv[4]) if len(sys.argv) > 4 else 30
a, b = selfcounts(sys.argv[1], want), selfcounts(sys.argv[2], want)
wait = ("__psynch", "__semwait", "__workq", "mach_msg", "swtch_pri", "__ulock")
busy = lambda c: sum(v for k, v in c.items() if not k.startswith(wait))
print(f"busy samples: a={busy(a)} b={busy(b)} diff={busy(b)-busy(a)}")
d = collections.Counter({k: b[k] - a[k] for k in set(a) | set(b) if not k.startswith(wait)})
for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:top]:
    print(f"  {v:+6d}  (a {a[k]:5d}  b {b[k]:5d})  {k[:100]}")

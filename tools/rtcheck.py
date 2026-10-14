"""Proves the audio thread is realtime-safe, on the built binary itself.

Walks the call graph from the IOProc (_eq_io) through every function it can reach and fails on
any call outside the allowlist: no allocation, locks, reference counting, Objective-C messaging,
Swift metadata or runtime helpers. Indirect calls (blr) fail too, since they can't be checked.
Run: python3 tools/rtcheck.py build/eq.app/Contents/MacOS/eq
"""
import re, subprocess, sys
from collections import Counter

ALLOWED = {"_bzero", "_memset", "___bzero"}   # plain libc stores
dis = subprocess.run(["otool", "-tV", sys.argv[1]], capture_output=True, text=True, check=True).stdout
funcs, cur = {}, None
for line in dis.split("\n"):
    if line.endswith(":") and not line.startswith(("\t", " ", "/")):
        cur = line[:-1]; funcs[cur] = []
    elif cur:
        funcs[cur].append(line)

seen, bad, local = set(), Counter(), Counter()
def walk(f):
    if f in seen: return
    seen.add(f)
    for line in funcs.get(f, []):
        m = re.search(r"\t(bl|b|blr|br)\t(\S+)(?:\s*;\s*(.*))?$", line)
        if not m: continue
        op, target, comment = m.groups()
        if op in ("blr", "br"): bad[f"indirect call in {f[:60]}"] += 1; continue
        name = (comment or target).strip().replace("symbol stub for: ", "")
        if name.startswith("0x"): continue                      # branch within the function
        if name in funcs: local[name] += 1; walk(name)
        elif name not in ALLOWED: bad[name] += 1

if "_eq_io" not in funcs: sys.exit("FAIL rtcheck: _eq_io not found")
walk("_eq_io")
print(f"audio thread reaches {len(seen)} functions: " + ", ".join(sorted(s[:40] for s in seen)))
for name, n in bad.items(): print(f"FAIL rtcheck: {n}× {name}")
print("PASS rtcheck: no allocation, locks, refcounting or runtime calls on the audio thread" if not bad else "")
sys.exit(1 if bad else 0)

#!/usr/bin/env python3
"""Compare framed (u32 LE length + bytes) expected vs observed records. Verification tooling only.
usage: cmp.py NAME EXPECTED OBSERVED [SHOW]  -> prints 'NAME records E observed G match M mismatch X'
exit 0 only when every expected record is matched byte for byte and counts agree."""
import sys
def recs(b):
    i, o = 0, []
    while i < len(b):
        n = int.from_bytes(b[i:i + 4], 'little'); o.append(b[i + 4:i + 4 + n]); i += 4 + n
    return o
name, ef, gf = sys.argv[1:4]
show = int(sys.argv[4]) if len(sys.argv) > 4 else 3
exp, got = recs(open(ef, 'rb').read()), recs(open(gf, 'rb').read())
ok = bad = 0
for k, e in enumerate(exp):
    g = got[k] if k < len(got) else None
    if g == e:
        ok += 1
    else:
        bad += 1
        if bad <= show:
            print('  mismatch record %d\n    expected %r\n    observed %r' % (k, e[:160], None if g is None else g[:160]))
print('%s records %d observed %d match %d mismatch %d' % (name, len(exp), len(got), ok, bad + max(0, len(got) - len(exp))))
sys.exit(0 if bad == 0 and len(got) == len(exp) else 1)

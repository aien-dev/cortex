#!/usr/bin/env python3
"""Generator (test input only) for the LIKE differential: the cortex-rs shape '%<query>%'
for real title words, plus '_' / '%' placements, ASCII and non-ASCII case variants,
invalid UTF-8, embedded NUL and the 50000-byte pattern limit. Records: u32 length + bytes.
Usage: gen_like.py DB OUT [N]"""
import random, re, sqlite3, struct, sys
db, out = sys.argv[1], sys.argv[2]
target = int(sys.argv[3]) if len(sys.argv) > 3 else 600
con = sqlite3.connect('file:%s?mode=ro' % db, uri=True)
titles = [r[0] for r in con.execute("SELECT canonical_name FROM entities ORDER BY rowid")]
rnd = random.Random(7)
words = [w for t in titles for w in re.split(r'\s+', t) if w]
na = [w for w in words if any(ord(c) > 127 for c in w)]
P = [b'', b'%', b'%%', b'_', b'%_%', b'___', b'%a%', b'%A%', b'%gb10%', b'%GB10%', b'%Gb_0%', b'%nvrm\\_alloc%',
     b'%nvrm_alloc%', b'%#225%', b'%caf\xc3\xa9%', b'%CAF\xc3\x89%', b'%\xc3\xa9%', b'%_\xc3\xa9%', b'%\xe2\x80\x94%',
     b'%\xff%', b'%\xc0%', b'%\x80%', b'%\xc3%', b'%a\x00b%', b'\x00', b'%\x00', b'%%%%%x%%%%', b'%_%_%_%',
     b'x%', b'%x', b'%e', b'E%', b'%' + b'a' * 49998, b'%' + b'a' * 49999, b'%' + b'a' * 50000 + b'%',
     b'%[a]%', b'%*%', b'%?%', b'%\\%', b'%\'%', b'%"%', b'%' + ('\U0001F600'.encode()) + b'%']
for t in titles[:150]:
    P.append(b'%' + t.strip().encode() + b'%')
while len(P) < target:
    k = rnd.randrange(8)
    wd = rnd.choice(words)
    if k == 0: s = '%' + wd + '%'
    elif k == 1: s = '%' + wd.upper() + '%'
    elif k == 2: s = '%' + wd.lower() + '%'
    elif k == 3: s = '%' + ''.join('_' if rnd.random() < 0.3 else c for c in wd) + '%'
    elif k == 4: s = '%' + rnd.choice(na) + '%' if na else '%é%'
    elif k == 5: s = '%' + wd[:rnd.randint(1, 3)] + '%' + rnd.choice(words)[:3] + '%'
    elif k == 6: s = wd + '%'
    else: s = '%' + wd.swapcase() + '%'
    P.append(s.encode())
with open(out, 'wb') as f:
    for p in P:
        f.write(struct.pack('<I', len(p)) + p)
print(len(P), 'patterns')

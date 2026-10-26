#!/usr/bin/env python3
"""Generator (test input only) for the tokenizer stress file: every Unicode scalar value
U+0080..U+10FFFF in three contexts (alone, after 'a', before 'a'), every lead byte with every
continuation-run length 0..6, surrogates/overlongs/out-of-range encodings, and random bytes.
Records: u32 length + bytes. Usage: gen_tokf.py OUT"""
import random, struct, sys
recs = []
def cp8(c):
    # encode any value < 2^21 with the generic UTF-8 bit layout (no validity checks)
    if c < 0x80: return bytes([c])
    if c < 0x800: return bytes([0xC0 | c >> 6, 0x80 | c & 63])
    if c < 0x10000: return bytes([0xE0 | c >> 12, 0x80 | c >> 6 & 63, 0x80 | c & 63])
    return bytes([0xF0 | c >> 18, 0x80 | c >> 12 & 63, 0x80 | c >> 6 & 63, 0x80 | c & 63])
chunk = []
for c in range(0x80, 0x110000):
    e = cp8(c)
    chunk.append(e + b' a' + e + b' ' + e + b'a ')
    if len(chunk) == 2048:
        recs.append(b''.join(chunk)); chunk = []
if chunk: recs.append(b''.join(chunk))
for lead in range(0x80, 0x100):
    rec = b''
    for n in range(7):
        rec += b'x' + bytes([lead]) + b'\x9f' * n + b'y ' + bytes([lead]) + b'\xbf' * n + b' '
    recs.append(rec)
rnd = random.Random(20261026)
for i in range(4000):
    n = rnd.randint(0, 300)
    recs.append(bytes(rnd.choice(b'aZ09_ .-\x00\x80\xbf\xc0\xc3\xcc\xe0\xe2\xed\xef\xf0\xf4\xf8\xff') for _ in range(n)))
recs.append(b'A' * 40000 + b' ' + ('\u00c9' * 20000).encode())   # token longer than 32768 bytes
recs.append(b'')
with open(sys.argv[1], 'wb') as f:
    for r in recs:
        f.write(struct.pack('<I', len(r)) + r)
print(len(recs), 'records')

#!/usr/bin/env python3
# realcheck.py DB - verification-only: independent minimal parser of a one-page table b-tree leaf
# (root page 2) that prints the serial type of column 0 of every row. Used to prove SQLite stores
# integral REAL values as integer serial types on disk (so the importer's int->f64 path is live).
import struct, sys
b = open(sys.argv[1], 'rb').read()
ps = struct.unpack('>H', b[16:18])[0]
ps = 65536 if ps == 1 else ps
pg = b[ps:2 * ps]
assert pg[0] == 13, 'root page 2 is not a table leaf'
def var(o):
    v = 0
    for i in range(9):
        c = pg[o + i]
        if i == 8:
            return (v << 8) | c, o + 9
        v = (v << 7) | (c & 127)
        if c < 128:
            return v, o + i + 1
n = struct.unpack('>H', pg[3:5])[0]
out = []
for i in range(n):
    c = struct.unpack('>H', pg[8 + 2 * i:10 + 2 * i])[0]
    _, o = var(c)
    rowid, o = var(o)
    _, o = var(o)          # record header size
    st, o = var(o)         # serial type of column 0
    out.append('%d:%d' % (rowid, st))
print(' '.join(out))

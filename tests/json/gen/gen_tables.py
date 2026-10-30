#!/usr/bin/env python3
"""Generate the data-table text literals embedded in om/f64.om and om/uni_rust.om.

Verification/generation tooling only (not in the product path).
  ryu tables : parsed from ryu-1.0.23/src/d2s_full_table.rs and re-derived with exact
               integer arithmetic (both must agree, else abort).
  POW10      : IEEE bits of the 309 serde_json POW10 literals 1e0..1e308 (Python float() is
               correctly rounded, as are Rust float literals).
  Unicode    : uni.txt written by ugen (tests/json/gen/ugen_main.rs) built with rustc 1.98.1;
               it queries str::to_lowercase / char::is_whitespace / <str as Debug> black-box.
Usage: gen_tables.py RYU_TABLE_RS UNI_TXT  -> prints the generated om text lines on stdout.
"""
import re, struct, sys

def ryu_tables(path):
    src = open(path).read()
    def grab(name):
        body = src.split('pub static %s' % name)[1].split('];')[0]
        return [(int(a), int(b)) for a, b in re.findall(r'\((\d+),\s*(\d+)\)', body)]
    inv, pos = grab('DOUBLE_POW5_INV_SPLIT'), grab('DOUBLE_POW5_SPLIT')
    assert len(inv) == 342 and len(pos) == 326
    for i, (lo, hi) in enumerate(pos):
        p = 5 ** i
        b = p.bit_length()
        v = p >> (b - 125) if b > 125 else p << (125 - b)
        assert (hi << 64 | lo) == v, ('pos', i)
    for i, (lo, hi) in enumerate(inv):
        p = 5 ** i
        b = p.bit_length()
        v = (1 << (b - 1 + 125)) // p + 1
        assert (hi << 64 | lo) == v, ('inv', i)
    return inv, pos

def pow10_bits():
    return [struct.unpack('<Q', struct.pack('<d', float('1e%d' % i)))[0] for i in range(309)]

def uni(path):
    lower, cls, dbg = [], {}, []
    for ln in open(path):
        p = ln.split()
        if p[0] == 'L':
            if len(p) == 3:
                lower.append((int(p[1]), int(p[2])))
            else:
                assert p[1:] == ['304', '105', '775'], p  # U+0130 -> "i\u0307", coded by hand
        elif p[0] == 'K':
            cls[int(p[1])] = p[2]
        elif p[0] == 'D':
            dbg.append(int(p[1]))
        elif p[0] == 'W':
            pass
    ranges, i = [], 0
    while i < len(lower):
        s, t = lower[i]; d = t - s; best, bs = 1, 1
        for st in (1, 2):
            n = 1
            while i + n < len(lower) and lower[i + n][0] == s + st * n and lower[i + n][1] - lower[i + n][0] == d:
                n += 1
            if n > best:
                best, bs = n, st
        ranges.append((s, best, d, bs)); i += best
    def iv(c):
        out = []
        for cp in sorted(k for k, v in cls.items() if v == c):
            if out and out[-1][1] == cp - 1: out[-1][1] = cp
            else: out.append([cp, cp])
        return out
    di = []
    for cp in dbg:
        if di and di[-1][1] == cp - 1: di[-1][1] = cp
        else: di.append([cp, cp])
    return ranges, iv('C'), iv('I'), di

def main():
    inv, pos = ryu_tables(sys.argv[1])
    flat = lambda xs: ' '.join(str(v) for t in xs for v in t)
    print('text jtpi "%s"' % flat(inv))
    print('text jtps "%s"' % flat(pos))
    print('text jtp10 "%s"' % ' '.join(str(b) for b in pow10_bits()))
    ranges, ci, ii, di = uni(sys.argv[2])
    print('text jtlr "%s"' % flat(ranges))
    print('text jtkc "%s"' % flat(ci))
    print('text jtki "%s"' % flat(ii))
    print('text jtdbg "%s"' % flat(di))
    print('note counts: inv %d pos %d pow10 309 lower-ranges %d cased %d ignorable %d debug-escaped %d' % (len(inv), len(pos), len(ranges), len(ci), len(ii), len(di)), file=sys.stderr)

main()

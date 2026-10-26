#!/usr/bin/env python3
# walfix.py - verification-only WAL oracle/fixture tool (Python 3, not on the product path).
# Independent re-implementation of SQLite 3.45 walIndexRecover/walDecodeFrame/walChecksumBytes.
#   walfix.py info WAL            -> "frames=N valid=V committed=M dbpages=P commits=a,b,..."
#   walfix.py flipck WAL K        -> flip one byte of frame K's checksum-1 field (1-based)
#   walfix.py be WAL              -> re-encode the valid prefix with big-endian checksums
#                                    (magic 0x377f0683), as a big-endian host would write it
#   walfix.py version WAL N       -> set the format version to N and re-seal the header checksum
import struct, sys

def cksum(be, data, s1, s2):
    fmt = '>%dI' if be else '<%dI'
    w = struct.unpack(fmt % (len(data) // 4), data)
    for i in range(0, len(w), 2):
        s1 = (s1 + w[i] + s2) & 0xFFFFFFFF
        s2 = (s2 + w[i + 1] + s1) & 0xFFFFFFFF
    return s1, s2

def scan(b):
    if len(b) <= 32:
        return dict(frames=0, valid=0, committed=0, dbpages=0, commits=[], ok=False)
    magic, ver, ps, ck, salt1, salt2, c1, c2 = struct.unpack('>8I', b[:32])
    if (magic & 0xFFFFFFFE) != 0x377f0682 or ps & (ps - 1) or ps > 65536 or ps < 512:
        return dict(frames=0, valid=0, committed=0, dbpages=0, commits=[], ok=False)
    be = magic & 1
    s = cksum(be, b[:24], 0, 0)
    if s != (c1, c2):
        return dict(frames=0, valid=0, committed=0, dbpages=0, commits=[], ok=False)
    n = (len(b) - 32) // (ps + 24)
    valid = mx = ndb = 0
    commits = []
    for i in range(n):
        o = 32 + i * (ps + 24)
        pg, nt, fs1, fs2, k1, k2 = struct.unpack('>6I', b[o:o + 24])
        if (fs1, fs2) != (salt1, salt2) or pg == 0:
            break
        s = cksum(be, b[o:o + 8], *s)
        s = cksum(be, b[o + 24:o + 24 + ps], *s)
        if s != (k1, k2):
            break
        valid = i + 1
        if nt:
            mx, ndb = i + 1, nt
            commits.append(i + 1)
    return dict(frames=n, valid=valid, committed=mx, dbpages=ndb, commits=commits, ok=True,
                ps=ps, ver=ver)

def main():
    cmd, path = sys.argv[1], sys.argv[2]
    b = bytearray(open(path, 'rb').read())
    if cmd == 'info':
        r = scan(bytes(b))
        print('frames=%d valid=%d committed=%d dbpages=%d commits=%s' % (
            r['frames'], r['valid'], r['committed'], r['dbpages'],
            ','.join(map(str, r['commits'])) or '-'))
        return
    if cmd == 'flipck':
        k = int(sys.argv[3]); ps = struct.unpack('>I', b[8:12])[0]
        o = 32 + (k - 1) * (ps + 24) + 16
        b[o] ^= 0x01
    elif cmd == 'be':
        r = scan(bytes(b)); ps = r['ps']
        struct.pack_into('>I', b, 0, 0x377f0683)
        s = cksum(1, bytes(b[:24]), 0, 0)
        struct.pack_into('>2I', b, 24, *s)
        for i in range(r['valid']):
            o = 32 + i * (ps + 24)
            s = cksum(1, bytes(b[o:o + 8]), *s)
            s = cksum(1, bytes(b[o + 24:o + 24 + ps]), *s)
            struct.pack_into('>2I', b, o + 16, *s)
    elif cmd == 'version':
        struct.pack_into('>I', b, 4, int(sys.argv[3]))
        be = struct.unpack('>I', b[:4])[0] & 1
        struct.pack_into('>2I', b, 24, *cksum(be, bytes(b[:24]), 0, 0))
    else:
        sys.exit('walfix: unknown command')
    open(path, 'wb').write(b)

main()

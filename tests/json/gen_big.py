#!/usr/bin/env python3
"""Large-document corpus for tests/json (each doc <= 4 MiB, the jes / request limit). Writes framed records."""
import random, sys
random.seed(7)
docs = []
docs.append(b'"' + b'a' * 3000000 + b'"')
docs.append(b'"' + ('\u00e9\\n\\u00e9x' * 300000).encode() + b'"')
docs.append(b'[' + b','.join(b'0' for _ in range(1500000)) + b']')
docs.append(b'[' + b','.join(b'0' for _ in range(1500000)) + b',]')
docs.append(b'{' + b','.join(b'"k%d":%d' % (random.randrange(10**6), i) for i in range(250000)) + b'}')
docs.append(b'{' + b','.join(b'"k%d":%d' % (random.randrange(1000), i) for i in range(300000)) + b'}')
docs.append(b' ' * 2000000 + b'\n' * 1500000 + b'[1,2')
docs.append(b'[' + b','.join(b'"%s"' % (b'x' * random.randrange(5)) for _ in range(800000)) + b']  x')
docs.append(b'{"' + b'k' * 1200000 + b'":1,"' + b'k' * 1200000 + b'":2}')
docs.append(b'"' + b'\\u0041' * 600000 + b'\xff"')
docs.append(b'[' * 127 + b']' * 127)
docs.append(b'{"a":' * 127 + b'1' + b'}' * 127)
assert all(len(d) <= 4194304 for d in docs)
sys.stdout.buffer.write(b''.join(len(d).to_bytes(4, 'little') + d for d in docs))

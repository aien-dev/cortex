#!/usr/bin/env python3
"""Generator (test input only) for the FTS differential: MATCH strings built from real
canonical_name titles of the aien-lessons / aien-sources spaces of the copy db, plus the
query shapes cortex-rs itself sends (raw text with '"' removed, the "quoted" phrase form,
the a AND b AND c fallback) and hand-written edge cases of the FTS5 grammar.
Output: records u32 length + bytes. Python's sqlite3 is used only to READ the titles.

Usage: gen_queries.py DB OUT [N]
"""
import random, re, sqlite3, struct, sys

db, out = sys.argv[1], sys.argv[2]
target = int(sys.argv[3]) if len(sys.argv) > 3 else 2400
con = sqlite3.connect('file:%s?mode=ro' % db, uri=True)
titles = [r[0] for r in con.execute(
    "SELECT canonical_name FROM entities WHERE space_slug IN ('aien-lessons','aien-sources') ORDER BY rowid")]
rnd = random.Random(20261026)
words = []
for t in titles:
    words += [w for w in re.split(r'[\s"]+', t) if w]
idents = [w for w in words if re.search(r'[_#0-9]', w)]
plain = [w for w in words if re.fullmatch(r'[A-Za-z]{3,}', w)]
nonascii = [w for w in words if any(ord(c) > 127 for c in w)]

def w():
    return rnd.choice(words)

def p():
    return rnd.choice(plain)

Q = []
edge = [
    '', ' ', '   ', '""', '"" ""', 'a ""', '"" a', 'memory OR ""', '"" OR memory', 'memory AND ""',
    'memory NOT ""', '"" NOT memory', '*', '*reads', '*id', '* reads', '*READS x', '*bogus', 'memory*',
    'mem*', 'm*', 'gb*', 'NEAR(memory model)', 'NEAR(memory model, 2)', 'NEAR(memory model, 0)',
    'NEAR(memory model,)', 'NEAR(memory)', 'NEAR(memory model, x)', 'NEAR(memory model, 99999999999)',
    'NEAR(memory model, 4294967295)', 'near(memory model)', 'NEAR (memory model)', 'NEAR(a b c, 5)',
    'canonical_name:memory', 'content:memory', 'CONTENT:memory', '"content":memory', 'id:memory',
    'space_slug:memory', 'nosuch:memory', '-canonical_name:memory', '-content:memory', '{canonical_name}:memory',
    '{canonical_name content}:memory', '-{canonical_name content}:memory', '{id space_slug}:memory',
    '{canonical_name}:(content:memory)', 'canonical_name:(memory OR model)', 'content:(memory model)',
    '{content}: NEAR(memory model)', '^memory', '^memory model', 'canonical_name:^memory', '^"memory model"',
    'memory + model', '"memory model"', '"memory" + "model"', 'memory + ""', 'memory* + ""', '"" + memory',
    'memory + ""*', 'a + b + c', '(memory)', '((memory))', '(memory OR model) AND gb10', 'memory OR model AND gb10',
    'memory AND model OR gb10', 'memory NOT model OR gb10', 'memory NOT (model OR gb10)', 'memory model OR gb10',
    'memory OR model gb10', '(memory', 'memory)', 'AND', 'OR', 'NOT', 'memory AND', 'AND memory', 'memory OR OR model',
    'memory and model', 'memory or model', 'memory not model', '"unterminated', 'mem"ory', "it's", 'a-b', 'a:b',
    'a,b', 'a.b', 'nvrm_alloc', 'NVRM_ALLOC', 'GB10', 'gb10', '#225', '225', 'sm_121', '18091', 'Qwen3.6-35B',
    'café', 'CAFÉ', 'naïve', 'Ünïcödé', 'Ⅻ', 'ﬁ', 'straße', '日本語', 'Ελληνικά', '😀', 'x\x1ay', '\x1a',
    'memory\x00model', 'memory\tmodel', 'memory\nmodel', 'memory\rmodel', '{', '}', '{}:memory', ':memory',
    'memory:', '^', '^^memory', '+memory', 'memory +', 'memory*model', 'memory**', 'NEAR(', 'NEAR()',
    '((((((((((((((((((((((((((((((((((((((((((((((((((memory))))))))))))))))))))))))))))))))))))))))))))))))))',
    '(' * 120 + 'memory' + ')' * 120, ' OR '.join(['memory'] * 300), ' AND '.join(plain[:40]),
    ' '.join(plain[:60]), 'NEAR(' + ' '.join(plain[:12]) + ', 30)',
]
Q += edge
# cortex-rs shapes from real titles
for t in titles[:400]:
    clean = t.strip().replace('"', '')
    Q.append(clean)
    Q.append('"%s"' % clean)
    terms = clean.split()
    if len(terms) > 1:
        Q.append(' AND '.join(terms))
while len(Q) < target:
    k = rnd.randrange(16)
    if k == 0: q = w()
    elif k == 1: q = rnd.choice(idents) if idents else w()
    elif k == 2: q = '"%s %s"' % (w(), w())
    elif k == 3: q = '%s AND %s' % (p(), p())
    elif k == 4: q = '%s OR %s' % (p(), p())
    elif k == 5: q = '%s NOT %s' % (p(), p())
    elif k == 6: q = p()[:rnd.randint(1, 4)] + '*'
    elif k == 7: q = 'NEAR(%s %s, %d)' % (p(), p(), rnd.randint(0, 12))
    elif k == 8: q = '%s:%s' % (rnd.choice(['canonical_name', 'content', '-content', '-canonical_name', '{content canonical_name}']), p())
    elif k == 9: q = '%s %s %s' % (p(), p(), p())
    elif k == 10: q = '(%s OR %s) %s' % (p(), p(), p())
    elif k == 11: q = rnd.choice(nonascii) if nonascii else 'café'
    elif k == 12: q = '^%s %s' % (p(), p())
    elif k == 13: q = '%s + %s*' % (p(), p()[:3])
    elif k == 14: q = rnd.choice(titles)
    else: q = ''.join(rnd.choice(' ()"*^+-:{},abcAND OR NOT') for _ in range(rnd.randint(1, 14)))
    Q.append(q)
with open(out, 'wb') as f:
    for q in Q:
        b = q.encode('utf-8')
        f.write(struct.pack('<I', len(b)) + b)
print(len(Q), 'queries')

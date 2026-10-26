#!/bin/sh
# tests/parity/gen.sh : build the parity corpus.
#   sh tests/parity/gen.sh DB OUT
# DB is a copy of the cortex-rs database (opened read-only). sqlite3 is used only to extract real
# values from it, as hex (DATA, below); the read-phase requests are built by gen.om (Omega), and the
# fixed cases (health/auth/CORS/routing, every error class, the write phase and the visitor-memory
# shapes) are the hand-written tests/parity/fixed.tsv, appended after them. Deterministic: the same DB
# gives the same corpus. Exit 0 only when every step succeeds.
set -u
DB=${1:?usage: gen.sh DB OUT}
OUT=${2:?usage: gen.sh DB OUT}
P=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$P/../.." && pwd)
W=$(dirname "$OUT")
OMC=$(sh "$R/tools/omc.sh") || exit 2
DATA=$W/gen.data
# Query terms: 40 FTS vocabulary terms spread over document frequency, 30 title words with their
# case, 15 identifier-like title words (digits, '_', '#', '-', '.'), 15 two-word title phrases.
# Entities: 50 per main space by rowid stride plus every row of the small spaces.
sqlite3 -readonly -batch -noheader "$DB" > "$DATA" <<'SQL' || exit 2
CREATE VIRTUAL TABLE temp.v USING fts5vocab(main, entities_fts, 'row');
CREATE TEMP TABLE w AS
WITH RECURSIVE s(rid, pos, w, rest) AS (
  SELECT rowid, 0, '', canonical_name || ' ' FROM entities WHERE retracted = 0
  UNION ALL
  SELECT rid, pos + 1, substr(rest, 1, instr(rest, ' ') - 1), substr(rest, instr(rest, ' ') + 1)
  FROM s WHERE rest <> '')
SELECT rid, pos, w FROM s WHERE w <> '';
WITH t AS (SELECT term, row_number() OVER (ORDER BY doc DESC, term) AS rn,
                  count(*) OVER () AS n FROM temp.v WHERE term GLOB '[a-z0-9]*')
SELECT 'T' || char(9) || hex(term) FROM t WHERE (rn - 1) % (n / 40) = 0 AND rn <= 40 * (n / 40);
SELECT 'T' || char(9) || hex(w) FROM (SELECT DISTINCT w FROM temp.w
  WHERE length(w) BETWEEN 4 AND 24 AND w GLOB '[A-Za-z]*' AND w NOT GLOB '*[^A-Za-z]*'
  ORDER BY rid % 997, w LIMIT 30);
SELECT 'T' || char(9) || hex(w) FROM (SELECT DISTINCT w FROM temp.w
  WHERE length(w) BETWEEN 3 AND 32 AND (w GLOB '*[0-9]*' OR w GLOB '*[_#.-]*') AND w GLOB '*[A-Za-z]*'
  ORDER BY rid % 991, w LIMIT 15);
SELECT 'T' || char(9) || hex(p) FROM (SELECT DISTINCT a.w || ' ' || b.w AS p FROM temp.w a
  JOIN temp.w b ON b.rid = a.rid AND b.pos = a.pos + 1
  WHERE length(a.w) >= 4 AND length(b.w) >= 4 AND a.w NOT GLOB '*["]*' AND b.w NOT GLOB '*["]*'
  ORDER BY a.rid % 983, p LIMIT 15);
SELECT 'E' || char(9) || hex(id) || char(9) || hex(canonical_name) || char(9) || hex(space_slug)
FROM (SELECT rowid AS r, id, canonical_name, space_slug,
             row_number() OVER (PARTITION BY space_slug ORDER BY rowid) AS rn,
             count(*) OVER (PARTITION BY space_slug) AS n
      FROM entities WHERE retracted = 0)
WHERE n < 50 OR (rn - 1) % (n / 50) = 0 AND rn <= 50 * (n / 50)
ORDER BY r;
SQL
mkdir -p "$W/gen.bin"
{ echo om2; cat "$P/gen.om"; } > "$W/gen.bin/gen.om"
"$OMC" < "$W/gen.bin/gen.om" > "$W/gen.bin/gen" 2> "$W/gen.bin/gen.err"
if [ $? -ne 0 ] || [ -s "$W/gen.bin/gen.err" ]; then echo "gen.sh: gen.om did not compile" >&2; exit 2; fi
chmod +x "$W/gen.bin/gen"
"$W/gen.bin/gen" "$DATA" "$OUT.read" || exit 2
cat "$OUT.read" "$P/fixed.tsv" > "$OUT" || exit 2
rm -f "$OUT.read"
echo "gen.sh: $(grep -c '^T' "$DATA") terms, $(grep -c '^E' "$DATA") entities, $(wc -l < "$OUT") requests"

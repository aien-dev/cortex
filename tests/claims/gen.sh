#!/bin/sh
# tests/claims/gen.sh : a claims corpus on real-shaped data, for the parity gate.
#   sh tests/claims/gen.sh DB OUT
# DB is a copy of a cortex-rs database (opened read-only). The live database holds no claims, so this
# corpus makes them from its real entities: 40 pairs of live entities of the same space (spread by
# rowid), and for each pair
#   - an object claim (subject -> object; predicate from the subject's entity type; metadata with the
#     real entity types; confidence 0.5..0.9), every seventh one without an id (server UUID);
#   - a literal claim whose literalValue is the object's real canonical name (any Unicode, quotes);
#   - traverse of the subject and of the object; get of the subject;
#   - an upsert of the object claim (same id, new predicate, literalValue = the object's real
#     metadata JSON);
#   - a retract of every third literal claim and of every tenth object entity;
#   - traverse of the subject again, and a search for the subject's name with include_retracted.
# Lines are the parity corpus format (spec/PARITY.md); run with
#   PARITY_GEN=tests/claims/gen.sh PARITY_EVIDENCE=evidence/claims sh tests/parity/run.sh DB
set -u
DB=${1:?usage: gen.sh DB OUT}
OUT=${2:?usage: gen.sh DB OUT}
sqlite3 -readonly -batch -noheader "$DB" > "$OUT" <<'SQL' || exit 2
CREATE TEMP TABLE p AS
WITH e AS (SELECT rowid AS r, id, canonical_name, entity_type, metadata_json, space_slug,
                  row_number() OVER (PARTITION BY space_slug ORDER BY rowid) AS rn
           FROM entities WHERE retracted = 0),
     s AS (SELECT a.r AS r, a.id AS sid, a.canonical_name AS sname, a.entity_type AS stype,
                  b.id AS oid, b.canonical_name AS oname, b.entity_type AS otype,
                  CASE WHEN json_valid(b.metadata_json) THEN b.metadata_json ELSE '{}' END AS ometa,
                  a.space_slug AS space
           FROM e a JOIN e b ON b.space_slug = a.space_slug AND b.rn = a.rn + 1),
     n AS (SELECT *, row_number() OVER (ORDER BY r) AS k, count(*) OVER () AS c FROM s)
SELECT k - 1 AS k, sid, sname, stype, oid, oname, otype, ometa, space FROM n
WHERE (k - 1) % (c / 40) = 0 AND k <= 40 * (c / 40);
SELECT 'claims.create' || char(9) || 'POST' || char(9) || '/api/cortex/write' || char(9) || 'aj' || char(9) ||
  json_object('kind', 'claim', 'value', CASE WHEN k % 7 = 3 THEN
    json_object('space', space, 'subjectEntityId', sid, 'predicate', 'relates_to_' || stype,
      'objectEntityId', oid, 'metadata', json_object('subjectType', stype, 'objectType', otype),
      'confidence', 0.5 + (k % 5) / 10.0)
  ELSE
    json_object('id', printf('cl-o%02d', k), 'space', space, 'subjectEntityId', sid,
      'predicate', 'relates_to_' || stype, 'objectEntityId', oid,
      'metadata', json_object('subjectType', stype, 'objectType', otype),
      'confidence', 0.5 + (k % 5) / 10.0)
  END)
FROM p ORDER BY k;
SELECT 'claims.create' || char(9) || 'POST' || char(9) || '/api/cortex/write' || char(9) || 'aj' || char(9) ||
  json_object('kind', 'claim', 'value', json_object('id', printf('cl-l%02d', k), 'space', space,
    'subjectEntityId', sid, 'predicate', 'names', 'literalValue', oname))
FROM p ORDER BY k;
SELECT 'claims.traverse' || char(9) || 'POST' || char(9) || '/api/cortex/traverse' || char(9) || 'aj' || char(9) ||
  json_object('subjectId', sid, 'space', space) FROM p ORDER BY k;
SELECT 'claims.traverse' || char(9) || 'POST' || char(9) || '/api/cortex/traverse' || char(9) || 'aj' || char(9) ||
  json_object('subjectId', oid, 'space', space) FROM p ORDER BY k;
SELECT 'claims.get' || char(9) || 'GET' || char(9) || '/api/cortex/get?id=' || sid || '&space=' || space ||
  char(9) || 'a' || char(9) FROM p ORDER BY k;
SELECT 'claims.upsert' || char(9) || 'POST' || char(9) || '/api/cortex/write' || char(9) || 'aj' || char(9) ||
  json_object('kind', 'claim', 'value', json_object('id', printf('cl-o%02d', k), 'space', space,
    'subjectEntityId', sid, 'predicate', 'restated_' || otype, 'objectEntityId', oid,
    'literalValue', json(ometa), 'confidence', 0.9))
FROM p WHERE k % 7 <> 3 ORDER BY k;
SELECT 'claims.retract' || char(9) || 'POST' || char(9) || '/api/cortex/write' || char(9) || 'aj' || char(9) ||
  json_object('kind', 'retract', 'value', json_object('targetType', 'claim', 'targetId', printf('cl-l%02d', k),
    'reason', 'claims corpus'))
FROM p WHERE k % 3 = 0 ORDER BY k;
SELECT 'claims.retract' || char(9) || 'POST' || char(9) || '/api/cortex/write' || char(9) || 'aj' || char(9) ||
  json_object('kind', 'retract', 'value', json_object('targetType', 'entity', 'targetId', oid))
FROM p WHERE k % 10 = 0 ORDER BY k;
SELECT 'claims.traverse' || char(9) || 'POST' || char(9) || '/api/cortex/traverse' || char(9) || 'aj' || char(9) ||
  json_object('subjectId', sid, 'space', space) FROM p ORDER BY k;
SELECT 'claims.search' || char(9) || 'POST' || char(9) || '/api/cortex/search' || char(9) || 'aj' || char(9) ||
  json_object('query', sname, 'space', space, 'include_retracted', json('true'), 'limit', 5) FROM p ORDER BY k;
SQL
n=$(wc -l < "$OUT")
grep -q "$(printf '\t')" "$OUT" || { echo "claims gen: empty corpus" >&2; exit 2; }
echo "claims gen: $n requests from $(sqlite3 "file:$DB?mode=ro" 'select count(*) from entities') entities"

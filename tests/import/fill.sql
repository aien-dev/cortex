-- Synthetic cortex rows (run after schema.sql). Covers: NULLs in every nullable column, empty
-- strings, non-ASCII UTF-8, content larger than any page size (overflow chains, incl. 300000 bytes),
-- integral REALs (stored as integers on disk: 1.0, 0.0, -3.0, 1e14; 1e15 exceeds 2^47-1 and SQLite
-- 3.45 stores it as a float, sqlite3.c OP_MakeRecord), non-integral REALs, every
-- integer serial type for revision (1,2,3,4,6,8-byte, constants 0 and 1), retracted 0/1, blobs of
-- 0/1536/70000 bytes and NULL, rowid gaps (deleted rows), claims with NULL object/literal, FTS rows
-- for a subset of entities plus one FTS row without an entity.
INSERT INTO spaces VALUES ('sp-0','atlas-memory','2026-01-01T00:00:00+00:00');
INSERT INTO spaces VALUES ('sp-1','zürich-ß','');
INSERT INTO spaces VALUES ('sp-2','s2','2026-02-02T02:02:02Z');
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 1500)
INSERT INTO entities (id, space_id, space_slug, entity_type, canonical_name, content, aliases_json,
  metadata_json, confidence, revision, retracted, valid_from, valid_to, created_at, embedding)
SELECT 'ent-' || printf('%05d', i), 'sp-' || (i % 3), CASE i % 3 WHEN 0 THEN 'atlas-memory' WHEN 1 THEN 'zürich-ß' ELSE 's2' END,
  CASE i % 4 WHEN 0 THEN 'lesson' WHEN 1 THEN 'fact' WHEN 2 THEN 'debug' ELSE '' END,
  'name ' || i || ' ünïcödé ✓',
  CASE WHEN i % 250 = 0 THEN replace(hex(zeroblob(150000)), '00', char(65 + i % 26, 10))
       WHEN i % 41 = 0 THEN replace(hex(zeroblob(35000)), '0', char(97 + i % 26))
       WHEN i % 7 = 0 THEN replace(hex(zeroblob(600)), '0', 'é')
       ELSE 'content of entity ' || i END,
  CASE WHEN i % 5 = 0 THEN '["a","b"]' ELSE '[]' END,
  '{"i":' || i || '}',
  CASE i % 8 WHEN 0 THEN 1.0 WHEN 1 THEN 0.5 WHEN 2 THEN 0.0 WHEN 3 THEN -3.0 WHEN 4 THEN 1e14
             WHEN 5 THEN 0.1 WHEN 6 THEN 1e300 ELSE -2.5e-310 END,
  CASE i % 12 WHEN 0 THEN 0 WHEN 1 THEN 1 WHEN 2 THEN 127 WHEN 3 THEN -128 WHEN 4 THEN 32767
             WHEN 5 THEN 8388607 WHEN 6 THEN -2147483648 WHEN 7 THEN 140737488355327
             WHEN 8 THEN 9223372036854775807 WHEN 9 THEN -9223372036854775808 WHEN 10 THEN -1
             ELSE 2 + i END,
  i % 2,
  CASE WHEN i % 6 = 0 THEN NULL ELSE '2026-03-0' || (i % 9) END,
  CASE WHEN i % 4 = 0 THEN '2027-01-01' ELSE NULL END,
  '2026-04-01T00:00:' || printf('%02d', i % 60) || '+00:00',
  CASE i % 5 WHEN 0 THEN NULL WHEN 1 THEN randomblob(1536) WHEN 2 THEN x''
             WHEN 3 THEN CASE WHEN i % 15 = 3 THEN randomblob(70000) ELSE x'00ff' END ELSE NULL END
FROM n;
INSERT INTO entities (id, space_id, space_slug, entity_type, canonical_name, content, created_at)
VALUES ('ent-big', 'sp-0', 'atlas-memory', 'fact', 'huge', replace(hex(zeroblob(150000)), '00', 'xy'), 'now');
DELETE FROM entities WHERE rowid % 97 = 5;
INSERT INTO entities_fts (id, canonical_name, content, space_slug)
SELECT id, canonical_name, substr(content, 1, 200), space_slug FROM entities WHERE rowid % 3 <> 1;
INSERT INTO entities_fts (id, canonical_name, content, space_slug) VALUES ('no-such-entity', 'x', 'y', 'z');
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 300)
INSERT INTO claims (id, space_id, space_slug, subject_entity_id, predicate, object_entity_id,
  literal_value_json, confidence, metadata_json, retracted, created_at)
SELECT 'cl-' || i, 'sp-' || (i % 3), 's' || (i % 3), 'ent-' || printf('%05d', i), 'relates_to',
  CASE WHEN i % 2 = 0 THEN NULL ELSE 'ent-' || printf('%05d', i + 1) END,
  CASE WHEN i % 3 = 0 THEN NULL ELSE '{"v":' || i || '}' END,
  CASE i % 3 WHEN 0 THEN 1.0 WHEN 1 THEN 0.25 ELSE 2.0 END,
  '{}', i % 2, '2026-05-05'
FROM n;
DELETE FROM claims WHERE rowid % 50 = 7;

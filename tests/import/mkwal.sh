#!/bin/sh
# mkwal.sh DIR : build WAL fixtures with ONE long-lived sqlite3 writer (oracle CLI 3.45.1) fed
# through a fifo, so the WAL is never checkpointed away by a closing connection.
#   txn0  schema + fill.sql, then wal_checkpoint(TRUNCATE): the db file holds the base state.
#   txnA  large update (many frames), committed, wal_checkpoint(PASSIVE) backfills it;
#         the next write restarts the WAL with new salts, so txnA frames stay behind as stale.
#   txn1  small committed change           -> snap1/ (db + wal copied, no shm)
#   txn2  second committed change          -> (frame counts recorded)
#   txn3  uncommitted: cache_size=5 forces spilled, non-commit frames into the WAL -> snap3/
# then ROLLBACK and close (that checkpoint makes w.db = committed state after txn2).
# Frame boundaries are not inferable from the file size (the restarted WAL keeps its old length);
# run.sh reads them with the independent walfix.py scanner.
set -eu
T=$(cd "$(dirname "$0")" && pwd)
D=$1
rm -rf "$D"; mkdir -p "$D"; cd "$D"
mkfifo cmd
/usr/bin/sqlite3 -batch -bail w.db < cmd > out.txt 2>&1 &
pid=$!
exec 3> cmd
n=0
sync_point() {
  n=$((n + 1)); printf '.print SYNC%s\n' "$n" >&3
  i=0
  while ! grep -q "^SYNC$n\$" out.txt; do
    i=$((i + 1)); if [ $i -gt 600 ]; then echo "mkwal: writer stuck at SYNC$n" >&2; cat out.txt >&2; exit 1; fi
    sleep 0.1
  done
}
{ echo "PRAGMA page_size=4096;"; echo "PRAGMA journal_mode=WAL;"; echo "PRAGMA wal_autocheckpoint=0;"
  cat "$T/schema.sql" "$T/fill.sql"; echo "PRAGMA wal_checkpoint(TRUNCATE);"; } >&3
sync_point
cat >&3 <<'EOF'
BEGIN;
UPDATE entities SET metadata_json = '{"txnA":' || rowid || '}', revision = revision + 0;
COMMIT;
PRAGMA wal_checkpoint(PASSIVE);
EOF
sync_point
cat >&3 <<'EOF'
BEGIN;
INSERT INTO spaces VALUES ('sp-t1', 'txn1-space', '2026-10-26');
UPDATE entities SET confidence = 0.75, content = 'txn1 ' || rowid WHERE rowid % 10 = 0;
COMMIT;
EOF
sync_point
mkdir snap1; cp w.db w.db-wal snap1/
cat >&3 <<'EOF'
BEGIN;
INSERT INTO claims (id, space_id, space_slug, subject_entity_id, predicate, created_at)
  VALUES ('cl-t2', 'sp-t1', 'txn1-space', 'ent-00010', 'txn2', '2026-10-26');
DELETE FROM entities WHERE rowid % 10 = 3;
UPDATE spaces SET created_at = 'txn2' WHERE id = 'sp-0';
COMMIT;
EOF
sync_point
cat >&3 <<'EOF'
PRAGMA cache_size=5;
BEGIN;
UPDATE spaces SET slug = 'UNCOMMITTED' WHERE id = 'sp-0';
INSERT INTO entities (id, space_id, space_slug, entity_type, canonical_name, content, created_at)
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 400)
  SELECT 'unc-' || i, 'sp-0', 'atlas-memory', 'fact', 'uncommitted', hex(zeroblob(3000)), 'x' FROM n;
EOF
sync_point
mkdir snap3; cp w.db w.db-wal snap3/
printf 'ROLLBACK;\n.quit\n' >&3
exec 3>&-
wait $pid

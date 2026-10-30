#!/bin/sh
# String-space capacity: the short-string pool must hold more than one 16 MiB omc pool.
# Usage: sh tests/big/run.sh SNAPSHOT.db [CONTROL_BINARY]
# Pads every entity's metadata with 3000 bytes (json_set on a scratch copy), imports it, starts
# build/cortex on BIG_PORT (default 18291) and reads back the LAST entity, whose strings lie past
# 16 MiB. PASS = the server loads the log and returns that entity with the exact pad from SQLite.
# With CONTROL_BINARY (a build with one 16 MiB pool) the same log must NOT load (trap 9, exit 109):
# the negative control showing the test reaches the old limit.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
SNAP=$1; CTL=${2:-}
P=${BIG_PORT:-18291}
W=${WORK:-$R/build/big}
CORTEX_TOKEN=big-test-token; export CORTEX_TOKEN
rm -rf "$W"; mkdir -p "$W"
PID=
stop() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; PID=; sleep 1; }
fail() { echo "FAIL big: $*"; stop; exit 1; }
cp "$SNAP" "$W/s.db"
sqlite3 "$W/s.db" "update entities set metadata_json = json_set(coalesce(metadata_json,'{}'), '\$.pad', hex(randomblob(1500)));" || fail "padding"
hsb=$(sqlite3 "$W/s.db" "select sum(length(cast(id as blob))+length(cast(space_id as blob))+length(cast(entity_type as blob))+length(cast(canonical_name as blob))+length(cast(aliases_json as blob))+length(cast(metadata_json as blob))) from entities")
echo "short-string bytes in the padded snapshot: $hsb (one pool: 16777216)"
[ "$hsb" -gt 16777216 ] || fail "padding did not pass 16 MiB"
"$R/build/cortex-import" "$W/s.db" "$W/cx.log" > "$W/import.out" 2>&1 || fail "import: $(cat "$W/import.out")"
last=$(sqlite3 "$W/s.db" "select id from entities where retracted = 0 order by rowid desc limit 1")
space=$(sqlite3 "$W/s.db" "select space_slug from entities where id='$last'")
want=$(sqlite3 "$W/s.db" "select json_extract(metadata_json,'\$.pad') from entities where id='$last'")
if [ -n "$CTL" ]; then
  timeout 60 "$CTL" --port "$P" --log "$W/cx.log" --encoder-url http://127.0.0.1:9 > "$W/ctl.out" 2>&1 < /dev/null
  rc=$?
  [ "$rc" = 109 ] || fail "control binary exit $rc, expected 109 (trap 9: string pool full)"
  echo "control: one-pool build exits 109 (trap 9) on this log"
fi
setsid nohup "$R/build/cortex" --port "$P" --log "$W/cx.log" --encoder-url http://127.0.0.1:9 > "$W/srv.out" 2>&1 < /dev/null &
PID=$!
i=0
until curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$P/health"; do
  kill -0 "$PID" 2>/dev/null || { PID=; fail "server exited: $(tail -c 300 "$W/srv.out")"; }
  i=$((i + 1)); [ $i -lt 600 ] || fail "server did not come up"
  sleep 0.2
done
curl -s -H "authorization: Bearer $CORTEX_TOKEN" "http://127.0.0.1:$P/api/cortex/get?id=$last&space=$space" > "$W/get.json"
stop
case $(cat "$W/get.json") in
  *"$want"*) echo "PASS big: last entity read back with its 3000-byte pad, past 16 MiB of short strings" ;;
  *) fail "last entity read-back differs: $(head -c 300 "$W/get.json")" ;;
esac

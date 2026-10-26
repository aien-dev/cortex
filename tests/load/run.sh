#!/bin/sh
# tests/load/run.sh : read-mix latency (oracle and Omega) and a kill -9 durability check (Omega).
#   sh tests/load/run.sh SRC.db
# Needs a corpus from the parity gate (build/parity/corpus.tsv; run tests/parity/run.sh first) and
# the pdrive client it built. Writes evidence/load/:
#   lat-{oracle,omega}-seq.ns          one latency (ns) per request, sequential client
#   lat-{oracle,omega}-c4.ns           the four concurrent clients' latencies, concatenated
#   wall.txt                           wall-clock time of each phase
#   crash.txt                          acknowledged writes before kill -9 and their presence after restart
# Statistics (p50/p99/mean) are computed afterwards through Wolfram and recorded in
# evidence/load/stats.txt with the exact queries.
set -u
SRC=${1:?usage: run.sh SRC.db}
R=$(cd "$(dirname "$0")/../.." && pwd)
PW=${PARITY_WORK:-$R/build/parity}
W=${LOAD_WORK:-$R/build/load}
EV=${LOAD_EVIDENCE:-$R/evidence/load}
BIN=${CORTEX_BIN:-$R/build/cortex}
IMP=${CORTEX_IMPORT:-$R/build/cortex-import}
ORA=${CORTEX_ORACLE:-$(command -v cortex-rs)}
OP=18180
SP=18190
TOK=paritytok
ENC=http://127.0.0.1:9
OPID=
SPID=
stop() {
  [ -n "$OPID" ] && kill "$OPID" 2>/dev/null
  [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
  OPID=
  SPID=
  sleep 1
}
fail() { echo "load: $*" >&2; stop; exit 2; }
ms() { date +%s%N; }
waitup() {
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/health" && return 0
    sleep 1
  done
  return 1
}
startomega() {
  CORTEX_TOKEN=$TOK setsid nohup "$BIN" --port $SP --log "$W/cx.log" --encoder-url $ENC \
    >> "$W/omega.out" 2>&1 < /dev/null &
  SPID=$!
  waitup $SP || fail "Omega did not come up"
}
[ -x "$PW/pdrive" ] && [ -f "$PW/corpus.tsv" ] || fail "run tests/parity/run.sh first"
[ -n "$ORA" ] && [ -x "$ORA" ] || fail "oracle cortex-rs not found (set CORTEX_ORACLE)"
for port in $OP $SP; do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/health" && fail "port $port is in use"
done
D=$PW/pdrive
rm -rf "$W"
mkdir -p "$W" "$EV" || exit 2
# read mix: every request of the generated read phase (search GET/POST, recall, get, traverse), in
# corpus order; split round-robin into four client streams
awk -F'\t' '$1 ~ /^(search|recall|get|traverse)\./' "$PW/corpus.tsv" > "$W/mix.tsv"
N=$(wc -l < "$W/mix.tsv")
[ "$N" -ge 2000 ] || fail "read mix has only $N requests"
for k in 0 1 2 3; do awk -v k=$k 'NR % 4 == k' "$W/mix.tsv" > "$W/mix$k.tsv"; done
sqlite3 "file:$SRC?mode=ro" ".backup '$W/o.db'" || fail "copy failed"
sqlite3 "file:$SRC?mode=ro" ".backup '$W/i.db'" || fail "copy failed"
"$IMP" "$W/i.db" "$W/cx.log" > "$W/import.out" 2>&1 || fail "import failed"
CORTEX_TOKEN=$TOK setsid nohup "$ORA" --port $OP --db-path "$W/o.db" --encoder-url $ENC \
  > "$W/oracle.out" 2>&1 < /dev/null &
OPID=$!
waitup $OP || fail "oracle did not come up"
startomega
: > "$EV/wall.txt"
for side in oracle omega; do
  port=$OP
  [ $side = omega ] && port=$SP
  t0=$(ms)
  "$D" "$W/mix.tsv" $port "$W/$side-seq.out" "$EV/lat-$side-seq.ns" || fail "$side sequential run failed"
  t1=$(ms)
  CP=
  for k in 0 1 2 3; do
    "$D" "$W/mix$k.tsv" $port "$W/$side-c$k.out" "$W/lat-$side-c$k.ns" &
    CP="$CP $!"
  done
  # shellcheck disable=SC2086
  wait $CP
  t2=$(ms)
  cat "$W/lat-$side-c0.ns" "$W/lat-$side-c1.ns" "$W/lat-$side-c2.ns" "$W/lat-$side-c3.ns" > "$EV/lat-$side-c4.ns"
  e=$(cat "$W/$side-seq.out" "$W/$side"-c?.out | grep -c '^#[0-9]* ERR$')
  echo "$side sequential requests=$N wall_ns=$((t1 - t0)); 4 clients requests=$(wc -l < "$EV/lat-$side-c4.ns") wall_ns=$((t2 - t1)); transport errors=$e" >> "$EV/wall.txt"
  [ "$e" = 0 ] || fail "$side had $e transport errors"
  [ "$(wc -l < "$EV/lat-$side-c4.ns")" = "$N" ] || fail "$side concurrent latency count mismatch"
done
kill "$OPID" 2>/dev/null
OPID=
# crash: a stream of 4000 acknowledged-or-not writes with known ids; kill -9 Omega mid-stream,
# restart it on the same log, then every write that was answered 201 must be readable with its
# content and nothing else may be in a half state (the log replays or the server refuses to start).
awk 'BEGIN { for (i = 0; i < 4000; i++)
  printf "crash.write\tPOST\t/api/cortex/write\taj\t{\"kind\":\"entity\",\"value\":{\"id\":\"ck-%05d\",\"space\":\"crash-space\",\"canonicalName\":\"crash row %05d\",\"content\":\"durable payload %05d\"}}\n", i, i, i }' > "$W/writes.tsv"
"$D" "$W/writes.tsv" $SP "$W/writes.out" &
DP=$!
sleep 2
kill -9 "$SPID"
SPID=
wait $DP
ack=$(awk '/^#[0-9]+ [0-9]+$/ { ix = substr($1, 2); getline; if ($2 == "201") print ix }' "$W/writes.out")
na=$(echo "$ack" | grep -c .)
nerr=$(grep -c '^#[0-9]* ERR$' "$W/writes.out")
# a request cut off by the kill gets an empty answer: not acknowledged, so it may or may not be stored
cut=$(awk '/^#[0-9]+ 0$/ { print substr($1, 2) }' "$W/writes.out")
nc=$(echo "$cut" | grep -c .)
[ "$nerr" -gt 0 ] || fail "kill -9 landed after the stream ended (no failed writes); nothing was tested"
startomega
echo "$ack" | awk 'NF { printf "crash.get\tGET\t/api/cortex/get?id=ck-%05d&space=crash-space\ta\t\n", $1 }' > "$W/gets.tsv"
"$D" "$W/gets.tsv" $SP "$W/gets.out" || fail "read-back failed"
got=$(awk '/^#[0-9]+ [0-9]+$/ { getline; if ($2 == "200") ok++ } END { print ok + 0 }' "$W/gets.out")
body=$(grep -c '"content":"durable payload [0-9]*"' "$W/gets.out")
echo "$cut" | awk 'NF { printf "crash.get\tGET\t/api/cortex/get?id=ck-%05d&space=crash-space\ta\t\n", $1 }' > "$W/cut.tsv"
cutin=0
if [ "$nc" -gt 0 ]; then
  "$D" "$W/cut.tsv" $SP "$W/cut.out" || fail "read-back of cut writes failed"
  cutin=$(grep -c '"content":"durable payload [0-9]*"' "$W/cut.out")
fi
stop
{
  echo "crash test $(date -u +%Y-%m-%dT%H:%M:%SZ): 4000 sequential writes, kill -9 after 2 s"
  echo "acknowledged (201) before kill: $na; refused after kill (ERR): $nerr; cut off mid-request (empty answer): $nc"
  echo "read back after restart: $got answered 200, $body carry their payload"
  echo "cut-off writes present after restart: $cutin of $nc (allowed either way: never acknowledged)"
} > "$EV/crash.txt"
cat "$EV/wall.txt" "$EV/crash.txt"
[ $((na + nerr + nc)) -eq 4000 ] || { echo "load: $na + $nerr + $nc answers do not account for 4000 writes" >&2; exit 1; }
[ "$na" -gt 0 ] && [ "$got" = "$na" ] && [ "$body" = "$na" ] || { echo "load: acknowledged writes lost" >&2; exit 1; }
exit 0

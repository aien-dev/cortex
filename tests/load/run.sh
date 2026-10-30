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
    curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$1/health" && return 0
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
# crash: 4 writer clients (1000 writes each, known ids: writer k sends ids k, k+4, k+8, ...) and
# 4 reader clients (the read mix) run together; kill -9 Omega mid-stream, restart it on the same
# log, then every write that was answered 201 must be readable with its content, and the server
# must come back (the log replays or the server refuses to start). Any other answer (transport
# error, empty answer, a 503 from a connection handler whose state process was gone) is
# "not acknowledged": it may or may not be stored.
for k in 0 1 2 3; do
  awk -v k=$k 'BEGIN { for (j = 0; j < 1000; j++) { i = k + 4 * j
    printf "crash.write\tPOST\t/api/cortex/write\taj\t{\"kind\":\"entity\",\"value\":{\"id\":\"ck-%05d\",\"space\":\"crash-space\",\"canonicalName\":\"crash row %05d\",\"content\":\"durable payload %05d\"}}\n", i, i, i } }' > "$W/writes$k.tsv"
done
CP=
for k in 0 1 2 3; do
  "$D" "$W/writes$k.tsv" $SP "$W/writes$k.out" &
  CP="$CP $!"
  "$D" "$W/mix$k.tsv" $SP "$W/reads$k.out" &
  CP="$CP $!"
done
sleep 2
kill -9 "$SPID"
SPID=
# shellcheck disable=SC2086
wait $CP
# per writer: one class per request index: A (201), E (transport error), Z (empty answer), O (other)
for k in 0 1 2 3; do
  awk -v k=$k '/^#[0-9]+ ERR$/ { print k + 4 * substr($1, 2), "E"; next }
    /^#[0-9]+ 0$/ { print k + 4 * substr($1, 2), "Z"; next }
    /^#[0-9]+ [0-9]+$/ { ix = substr($1, 2); getline; print k + 4 * ix, ($2 == "201" ? "A" : "O") }' "$W/writes$k.out"
done > "$W/classes.txt"
na=$(grep -c ' A$' "$W/classes.txt")
nerr=$(grep -c ' E$' "$W/classes.txt")
nz=$(grep -c ' Z$' "$W/classes.txt")
no=$(grep -c ' O$' "$W/classes.txt")
nall=$(wc -l < "$W/classes.txt")
rerr=$(cat "$W"/reads?.out | grep -c '^#[0-9]* ERR$')
[ $((nerr + nz + no)) -gt 0 ] || fail "kill -9 landed after the streams ended (every write acknowledged); nothing was tested"
startomega
awk '$2 == "A" { printf "crash.get\tGET\t/api/cortex/get?id=ck-%05d&space=crash-space\ta\t\n", $1 }' "$W/classes.txt" > "$W/gets.tsv"
"$D" "$W/gets.tsv" $SP "$W/gets.out" || fail "read-back failed"
got=$(awk '/^#[0-9]+ [0-9]+$/ { getline; if ($2 == "200") ok++ } END { print ok + 0 }' "$W/gets.out")
body=$(grep -c '"content":"durable payload [0-9]*"' "$W/gets.out")
awk '$2 != "A" { printf "crash.get\tGET\t/api/cortex/get?id=ck-%05d&space=crash-space\ta\t\n", $1 }' "$W/classes.txt" > "$W/cut.tsv"
cutin=0
if [ -s "$W/cut.tsv" ]; then
  "$D" "$W/cut.tsv" $SP "$W/cut.out" || fail "read-back of unacknowledged writes failed"
  cutin=$(grep -c '"content":"durable payload [0-9]*"' "$W/cut.out")
fi
stop
{
  echo "crash test $(date -u +%Y-%m-%dT%H:%M:%SZ): 4 writer clients x 1000 writes + 4 reader clients, kill -9 after 2 s"
  echo "binary sha256 $(sha256sum "$BIN" | cut -c1-64)"
  echo "acknowledged (201) before kill: $na; transport error: $nerr; empty answer: $nz; other answer: $no; total $nall"
  echo "reader transport errors (expected after the kill): $rerr"
  echo "read back after restart: $got answered 200, $body carry their payload"
  echo "unacknowledged writes present after restart: $cutin of $((nerr + nz + no)) (allowed either way)"
} > "$EV/crash.txt"
cat "$EV/wall.txt" "$EV/crash.txt"
[ "$nall" -eq 4000 ] || { echo "load: $nall answers do not account for 4000 writes" >&2; exit 1; }
[ "$na" -gt 0 ] && [ "$got" = "$na" ] && [ "$body" = "$na" ] || { echo "load: acknowledged writes lost" >&2; exit 1; }
exit 0

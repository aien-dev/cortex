#!/bin/sh
# tests/conc/run.sh : concurrent clients and slow clients against the Omega server.
#   sh tests/conc/run.sh SRC.db
# Needs the parity corpus, pdrive and pcmp (run tests/parity/run.sh first). Starts build/cortex on a
# fresh import (port 18290, unreachable encoder). The read mix of the corpus is cut into 16 slices:
#   seq    the 16 slices one after another, one client       -> lat-seq.ns
#   c16    the 16 slices as 16 parallel clients               -> lat-c16.ns
#   slow   the 16 parallel clients while S slow clients (tests/conc/slow.om) hold connections open
#          by never finishing their request head              -> lat-slow.ns, slow.txt
# Pass: no transport error in any phase, every request answered in every phase, every slow
# connection ended by the server (answered or closed) within SLOWMAX seconds, and every parallel
# answer equal to the one-client answer to the same request under the parity masks (pcmp).
# CONC_CONTROL_BIN=path runs the slow phase once more against that binary (negative control: a
# one-connection server is expected to stall behind the slow clients); recorded, not gated.
# Statistics are computed afterwards through Wolfram and recorded in evidence/conc/stats.txt.
set -u
SRC=${1:?usage: run.sh SRC.db}
R=$(cd "$(dirname "$0")/../.." && pwd)
PW=${PARITY_WORK:-$R/build/parity}
W=${CONC_WORK:-$R/build/conc}
EV=${CONC_EVIDENCE:-$R/evidence/conc}
BIN=${CORTEX_BIN:-$R/build/cortex}
IMP=${CORTEX_IMPORT:-$R/build/cortex-import}
OMC=$(sh "$R/tools/omc.sh") || { echo "conc: pinned omc unavailable" >&2; exit 2; }
S=${CONC_SLOW:-200}
SLOWMAX=11
SP=18290
TOK=paritytok
ENC=http://127.0.0.1:9
SPID=
stop() {
  [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
  SPID=
  sleep 1
}
fail() { echo "conc: $*" >&2; stop; exit 2; }
waitup() {
  for i in $(seq 1 30); do
    curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$SP/health" && return 0
    sleep 1
  done
  return 1
}
start() { # start BINARY
  CORTEX_TOKEN=$TOK setsid nohup "$1" --port $SP --log "$W/cx.log" --encoder-url $ENC \
    >> "$W/server.out" 2>&1 < /dev/null &
  SPID=$!
  waitup || fail "server did not come up"
}
ms() { date +%s%N; }
D=$PW/pdrive
[ -x "$D" ] && [ -x "$PW/pcmp" ] && [ -f "$PW/corpus.tsv" ] || fail "run tests/parity/run.sh first"
curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SP/health" && fail "port $SP is in use"
rm -rf "$W"
mkdir -p "$W" "$EV" || exit 2
{ echo om2; cat "$R/tests/conc/slow.om"; } > "$W/slow.om"
"$OMC" < "$W/slow.om" > "$W/slow" 2> "$W/slow.err"
if [ $? -ne 0 ] || [ -s "$W/slow.err" ]; then fail "slow.om did not compile"; fi
chmod +x "$W/slow"
awk -F'\t' '$1 ~ /^(search|recall|get|traverse)\./' "$PW/corpus.tsv" > "$W/mix.tsv"
N=$(wc -l < "$W/mix.tsv")
[ "$N" -ge 2000 ] || fail "read mix has only $N requests"
for k in $(seq 0 15); do awk -v k=$k 'NR % 16 == k' "$W/mix.tsv" > "$W/mix$k.tsv"; done
sqlite3 "file:$SRC?mode=ro" ".backup '$W/i.db'" || fail "copy failed"
"$IMP" "$W/i.db" "$W/cx.log" > "$W/import.out" 2>&1 || fail "import failed"
start "$BIN"
: > "$EV/wall.txt"
par() { # par PHASE: 16 parallel clients; concatenated latencies in EV/lat-PHASE.ns
  CP=
  for k in $(seq 0 15); do
    "$D" "$W/mix$k.tsv" $SP "$W/$1-c$k.out" "$W/lat-$1-c$k.ns" &
    CP="$CP $!"
  done
  # shellcheck disable=SC2086
  wait $CP
  for k in $(seq 0 15); do cat "$W/lat-$1-c$k.ns"; done > "$EV/lat-$1.ns"
}
errs() { cat "$@" | grep -c '^#[0-9]* ERR$'; }
SINCE=$(date -u +%Y-%m-%dT%H:%M:%S)
t0=$(ms)
for k in $(seq 0 15); do
  "$D" "$W/mix$k.tsv" $SP "$W/seq-c$k.out" "$W/lat-seq-c$k.ns" || fail "sequential run failed"
done
t1=$(ms)
for k in $(seq 0 15); do cat "$W/lat-seq-c$k.ns"; done > "$EV/lat-seq.ns"
par c16
t2=$(ms)
"$W/slow" $SP "$S" 14 "$W/slow.txt" &
SL=$!
sleep 1
t3=$(ms)
par slow
t4=$(ms)
wait $SL
src=$?
cp "$W/slow.txt" "$EV/slow.txt"
e1=$(errs "$W"/seq-c*.out); e2=$(errs "$W"/c16-c*.out); e3=$(errs "$W"/slow-c*.out)
{
  echo "conc $(date -u +%Y-%m-%dT%H:%M:%SZ) binary sha256 $(sha256sum "$BIN" | cut -c1-64)"
  echo "requests per phase: $N"
  echo "seq  1 client   wall_ns=$((t1 - t0)) transport_errors=$e1"
  echo "c16  16 clients wall_ns=$((t2 - t1)) transport_errors=$e2"
  echo "slow 16 clients wall_ns=$((t4 - t3)) transport_errors=$e3 with $S slow clients (slow rc=$src)"
} >> "$EV/wall.txt"
# every parallel answer must equal the one-client answer to the same request (parity masks)
pc=0
for ph in c16 slow; do
  for k in $(seq 0 15); do
    "$PW/pcmp" "$W/mix$k.tsv" "$W/seq-c$k.out" "$W/$ph-c$k.out" "$W/pcmp-$ph-$k.txt" "$SINCE" > /dev/null 2>&1 || pc=1
  done
  grep -h '^TOTAL' "$W"/pcmp-$ph-*.txt | awk -v ph=$ph '{ for (i = 2; i <= NF; i++) { split($i, a, "="); t[a[1]] += a[2] } }
    END { printf "pcmp %s vs one client: records=%d pass=%d fail=%d masked-values=%d\n", ph, t["records"], t["pass"], t["fail"], t["masked-values"] }' >> "$EV/wall.txt"
done
stop
if [ -n "${CONC_CONTROL_BIN:-}" ]; then
  start "$CONC_CONTROL_BIN"
  "$W/slow" $SP "$S" 14 "$W/ctl-slow.txt" &
  SL=$!
  sleep 1
  t5=$(ms)
  par ctl
  t6=$(ms)
  wait $SL
  stop
  echo "control sha256 $(sha256sum "$CONC_CONTROL_BIN" | cut -c1-64): 16 clients with $S slow clients wall_ns=$((t6 - t5)) transport_errors=$(errs "$W"/ctl-c*.out) latencies=$(wc -l < "$EV/lat-ctl.ns") of $N" >> "$EV/wall.txt"
  cp "$W/ctl-slow.txt" "$EV/ctl-slow.txt"
fi
late=$(awk -v m=$SLOWMAX '$2 > m * 1000000000 || $3 == "open"' "$EV/slow.txt" | wc -l)
ns=$(wc -l < "$EV/slow.txt")
echo "slow connections: $ns of $S opened, $late not ended by the server within $SLOWMAX s; endings: $(cut -d' ' -f3- "$EV/slow.txt" | sort | uniq -c | tr -s ' ' | tr '\n' ';')" >> "$EV/wall.txt"
cat "$EV/wall.txt"
[ "$e1" = 0 ] && [ "$e2" = 0 ] && [ "$e3" = 0 ] || { echo "conc: transport errors" >&2; exit 1; }
[ "$(wc -l < "$EV/lat-c16.ns")" = "$N" ] && [ "$(wc -l < "$EV/lat-slow.ns")" = "$N" ] || { echo "conc: missing answers" >&2; exit 1; }
[ "$src" = 0 ] && [ "$ns" = "$S" ] && [ "$late" = 0 ] || { echo "conc: slow clients not handled" >&2; exit 1; }
[ "$pc" = 0 ] || { echo "conc: parallel answers differ from one-client answers (see $W/pcmp-*.txt)" >&2; exit 1; }
exit 0

#!/bin/sh
# tests/shadow/run.sh : shadow comparison of a running cortex-rs against the Omega server, on the
# same data, with a corpus of real read requests.
#   CORTEX_TOKEN=... sh tests/shadow/run.sh LIVE_DB LIVE_PORT CORPUS OUTDIR
# LIVE_DB is the database the running cortex-rs on 127.0.0.1:LIVE_PORT serves (opened read-only;
# the running server is never stopped or reconfigured). CORPUS is in the parity format
# (spec/PARITY.md), read requests only; flag a sends "authorization: Bearer $CORTEX_TOKEN".
# Each attempt:
#   1. fingerprints the live data (every entity id/revision/retracted/name/content length and every
#      claim id/retracted), takes a read-only .backup, fingerprints again (retry if they differ);
#   2. imports the snapshot and starts build/cortex on SHADOW_PORT (default 18280) with the same
#      encoder URL (SHADOW_ENC, default http://127.0.0.1:18081);
#   3. replays CORPUS to the live server, fingerprints the live data again: if anything was written
#      between the snapshot and the end of the live replay, the attempt is discarded (drift), since
#      both servers must see the same rows; otherwise replays CORPUS to the Omega server and compares
#      the answers with pcmp (timing fields masked as in the parity gate).
# Up to SHADOW_TRIES (default 20) attempts; the first drift-free attempt is the result.
# OUTDIR gets summary.txt, report.txt, live.rec, omega.rec, attempts.txt. Exit 0 only when a
# drift-free attempt compared with zero failures.
set -u
DB=${1:?usage: run.sh LIVE_DB LIVE_PORT CORPUS OUTDIR}
LP=${2:?usage: run.sh LIVE_DB LIVE_PORT CORPUS OUTDIR}
CORPUS=${3:?usage: run.sh LIVE_DB LIVE_PORT CORPUS OUTDIR}
OUT=${4:?usage: run.sh LIVE_DB LIVE_PORT CORPUS OUTDIR}
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/tests/parity
BIN=${CORTEX_BIN:-$R/build/cortex}
IMP=${CORTEX_IMPORT:-$R/build/cortex-import}
SP=${SHADOW_PORT:-18280}
ENC=${SHADOW_ENC:-http://127.0.0.1:18081}
TRIES=${SHADOW_TRIES:-20}
W=${SHADOW_WORK:-$R/build/shadow}
SPID=
stop() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; SPID=; }
fail() { echo "shadow: $*" >&2; stop; exit 2; }
[ -n "${CORTEX_TOKEN:-}" ] || fail "CORTEX_TOKEN is not set"
[ -f "$DB" ] && [ -f "$CORPUS" ] || fail "missing LIVE_DB or CORPUS"
[ -x "$BIN" ] && [ -x "$IMP" ] || fail "build first (sh build.sh)"
curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SP/health" && fail "port $SP is in use"
curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$LP/health" || fail "live server on $LP not answering"
OMC=$(sh "$R/tools/omc.sh") || fail "pinned omc unavailable"
rm -rf "$W"
mkdir -p "$W" "$OUT" || fail "cannot make $W"
for u in pdrive pcmp; do
  { echo om2; cat "$P/$u.om"; } > "$W/$u.om"
  "$OMC" < "$W/$u.om" > "$W/$u" 2> "$W/$u.err"
  if [ $? -ne 0 ] || [ -s "$W/$u.err" ]; then fail "$u.om did not compile: $(cat "$W/$u.err")"; fi
  chmod +x "$W/$u"
done
fp() {
  sqlite3 -readonly -batch "file:$DB?mode=ro" \
    "select id, revision, retracted, canonical_name, length(content) from entities order by id;
     select id, retracted from claims order by id;" | sha256sum | cut -c1-64
}
: > "$OUT/attempts.txt"
ok=0
a=0
while [ $a -lt "$TRIES" ]; do
  a=$((a + 1))
  stop
  rm -f "$W/s.db" "$W/cx.log" "$W/cx.log.sock"
  f0=$(fp)
  sqlite3 "file:$DB?mode=ro" ".backup '$W/s.db'" || fail "backup failed"
  f1=$(fp)
  if [ "$f0" != "$f1" ]; then echo "attempt $a: write during backup" >> "$OUT/attempts.txt"; sleep 5; continue; fi
  "$IMP" "$W/s.db" "$W/cx.log" > "$W/import.out" 2>&1 || fail "import failed: $(cat "$W/import.out")"
  setsid nohup "$BIN" --port "$SP" --log "$W/cx.log" --encoder-url "$ENC" > "$W/omega.out" 2>&1 < /dev/null &
  SPID=$!
  up=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$SP/health" && { up=1; break; }
    sleep 1
  done
  [ $up = 1 ] || fail "Omega server did not come up: $(cat "$W/omega.out")"
  SINCE=$(date -u +%Y-%m-%dT%H:%M:%S)
  t0=$(date +%s)
  PDRIVE_TOKEN=$CORTEX_TOKEN "$W/pdrive" "$CORPUS" "$LP" "$W/live.rec" || fail "driving the live server failed"
  f2=$(fp)
  t1=$(date +%s)
  if [ "$f0" != "$f2" ]; then
    echo "attempt $a: live data changed during the live replay (${t0}..${t1})" >> "$OUT/attempts.txt"
    continue
  fi
  PDRIVE_TOKEN=$CORTEX_TOKEN "$W/pdrive" "$CORPUS" "$SP" "$W/omega.rec" || fail "driving Omega failed"
  stop
  echo "attempt $a: drift-free, live replay ${t0}..${t1}" >> "$OUT/attempts.txt"
  ok=1
  break
done
stop
[ $ok = 1 ] || { cat "$OUT/attempts.txt"; fail "no drift-free attempt in $TRIES tries"; }
"$W/pcmp" "$CORPUS" "$W/live.rec" "$W/omega.rec" "$W/report.txt" "$SINCE"
rc=$?
[ $rc -le 1 ] || fail "comparator error rc=$rc"
errs=$(grep -c ' ERR$' "$W/live.rec" "$W/omega.rec" | awk -F: '{ s += $2 } END { print s + 0 }')
{
  echo "shadow $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=$rc"
  echo "corpus     $(wc -l < "$CORPUS") requests, sha256 $(sha256sum < "$CORPUS" | cut -c1-64)"
  echo "snapshot   $(sqlite3 "file:$W/s.db?mode=ro" 'select count(*) from entities') entities, $(sqlite3 "file:$W/s.db?mode=ro" 'select count(*) from claims') claims, fingerprint $f0"
  echo "import     $(cat "$W/import.out")"
  echo "omega      sha256 $(sha256sum < "$BIN" | cut -c1-64)"
  echo "omc        sha256 $(sha256sum < "$OMC" | cut -c1-64)"
  echo "attempts   $a ($(tail -1 "$OUT/attempts.txt"))"
  echo "transport errors (ERR records, both sides) $errs"
  tail -1 "$W/report.txt"
  awk '$1=="PASS"||$1=="FAIL" { split($3, c, "."); k = c[1] "." c[2]; n[k]++; if ($1=="PASS") p[k]++ }
       END { for (k in n) printf "%-24s %5d / %5d\n", k, p[k]+0, n[k] }' "$W/report.txt" | sort
  grep '^FAIL' "$W/report.txt" | head -50
} > "$OUT/summary.txt"
cp "$W/report.txt" "$W/live.rec" "$W/omega.rec" "$OUT/"
cat "$OUT/summary.txt"
[ "$errs" = 0 ] || rc=1
exit $rc

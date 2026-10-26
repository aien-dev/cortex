#!/bin/sh
# tests/parity/run.sh : wire parity gate, Omega Cortex against the cortex-rs oracle (spec/PARITY.md).
#   sh tests/parity/run.sh SRC.db
# SRC.db is a copy of a cortex-rs database; it is opened read-only and never written. The gate
#   1. builds the corpus (tests/parity/gen.sh) and the Omega driver/comparator (pdrive, pcmp);
#   2. makes two fresh copies with sqlite3 .backup, imports one with build/cortex-import;
#   3. starts the oracle (cortex-rs, port 18180) on one copy and the Omega server (build/cortex,
#      port 18190) on the imported log, both with an unreachable encoder (http://127.0.0.1:9);
#   4. drives the identical request sequence against each, compares answer by answer, stops both.
# Exit 0 only when every record is exact or differs only by the masks of spec/PARITY.md.
# Environment: CORTEX_ORACLE (default: cortex-rs on PATH), CORTEX_BIN (default build/cortex),
# CORTEX_IMPORT (default build/cortex-import), PARITY_WORK (default build/parity),
# PARITY_EVIDENCE (default evidence/parity; set to a scratch directory for a mutant run).
set -u
SRC=${1:?usage: run.sh SRC.db}
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/tests/parity
W=${PARITY_WORK:-$R/build/parity}
EV=${PARITY_EVIDENCE:-$R/evidence/parity}
BIN=${CORTEX_BIN:-$R/build/cortex}
IMP=${CORTEX_IMPORT:-$R/build/cortex-import}
ORA=${CORTEX_ORACLE:-$(command -v cortex-rs)}
OP=18180
SP=18190
TOK=paritytok
ENC=http://127.0.0.1:9
fail() { echo "parity: $*" >&2; stop; exit 2; }
OPID=
SPID=
stop() {
  [ -n "$OPID" ] && kill "$OPID" 2>/dev/null
  [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
  OPID=
  SPID=
}
[ -f "$SRC" ] || fail "no source database $SRC"
[ -x "$BIN" ] && [ -x "$IMP" ] || fail "build first (sh build.sh)"
[ -n "$ORA" ] && [ -x "$ORA" ] || fail "oracle cortex-rs not found (set CORTEX_ORACLE)"
for port in $OP $SP; do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/health" && fail "port $port is in use"
done
OMC=$(sh "$R/tools/omc.sh") || fail "pinned omc unavailable"
rm -rf "$W"
mkdir -p "$W" "$EV" || fail "cannot make $W"
for u in pdrive pcmp; do
  { echo om2; cat "$P/$u.om"; } > "$W/$u.om"
  "$OMC" < "$W/$u.om" > "$W/$u" 2> "$W/$u.err"
  if [ $? -ne 0 ] || [ -s "$W/$u.err" ]; then fail "$u.om did not compile"; fi
  chmod +x "$W/$u"
done
sh "$P/gen.sh" "$SRC" "$W/corpus.tsv" > "$W/gen.out" || fail "corpus generation failed"
sqlite3 "file:$SRC?mode=ro" ".backup '$W/o.db'" || fail "copy failed"
sqlite3 "file:$SRC?mode=ro" ".backup '$W/i.db'" || fail "copy failed"
"$IMP" "$W/i.db" "$W/cx.log" > "$W/import.out" 2>&1 || fail "import failed: $(cat "$W/import.out")"
CORTEX_TOKEN=$TOK setsid nohup "$ORA" --port $OP --db-path "$W/o.db" --encoder-url $ENC \
  > "$W/oracle.out" 2>&1 < /dev/null &
OPID=$!
CORTEX_TOKEN=$TOK setsid nohup "$BIN" --port $SP --log "$W/cx.log" --encoder-url $ENC \
  > "$W/omega.out" 2>&1 < /dev/null &
SPID=$!
up=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$OP/health" &&
     curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SP/health"; then up=1; break; fi
  sleep 1
done
[ $up = 1 ] || fail "servers did not come up"
SINCE=$(date -u +%Y-%m-%dT%H:%M:%S)
"$W/pdrive" "$W/corpus.tsv" $OP "$W/oracle.rec" || fail "driving the oracle failed"
"$W/pdrive" "$W/corpus.tsv" $SP "$W/omega.rec" || fail "driving Omega failed"
stop
"$W/pcmp" "$W/corpus.tsv" "$W/oracle.rec" "$W/omega.rec" "$W/report.txt" "$SINCE"
rc=$?
[ $rc -le 1 ] || fail "comparator error rc=$rc"
awk '$1=="PASS"||$1=="FAIL" { n[$3]++; if ($1=="PASS") p[$3]++ }
     END { for (c in n) printf "%-24s %5d / %5d\n", c, p[c]+0, n[c] }' "$W/report.txt" | sort > "$W/classes.txt"
{
  echo "parity gate $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=$rc"
  echo "corpus     $(wc -l < "$W/corpus.tsv") requests, sha256 $(sha256sum < "$W/corpus.tsv" | cut -c1-64)"
  echo "generator  $(cat "$W/gen.out")"
  echo "source     $(sqlite3 "file:$SRC?mode=ro" 'select count(*) from entities') entities (copy of a cortex-rs database)"
  echo "import     $(cat "$W/import.out")"
  echo "omc        sha256 $(sha256sum < "$OMC" | cut -c1-64)"
  echo "omega      sha256 $(sha256sum < "$BIN" | cut -c1-64)"
  echo "oracle     sha256 $(sha256sum < "$ORA" | cut -c1-64)"
  echo "since      $SINCE"
  tail -1 "$W/report.txt"
  echo "per class (pass / total):"
  cat "$W/classes.txt"
  grep '^FAIL' "$W/report.txt" | head -50
} > "$EV/summary.txt"
cp "$W/report.txt" "$EV/report.txt"
cat "$EV/summary.txt"
exit $rc

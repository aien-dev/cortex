#!/bin/sh
# check.sh : every local gate of the Omega Cortex, one after the other (no CI; see README.md).
#   sh check.sh SRC.db
# SRC.db is a cortex-rs database (opened read-only; take a copy with sqlite3 .backup first).
# Steps: build, JSON/number differentials, FTS/LIKE differentials, importer checks, wire parity gate,
# parity mutant (must be caught), load and kill -9 durability. Logs and fresh evidence go to
# $CHECK_DIR (default build/check); the committed evidence/ files are not touched.
# Exit 0 only when every step passes. Runs at lowest CPU and I/O priority, one step at a time.
set -u
if [ -z "${CXO_NICED:-}" ]; then CXO_NICED=1 exec nice -n 19 ionice -c3 sh "$0" "$@"; fi
SRC=${1:?usage: check.sh SRC.db}
[ -f "$SRC" ] || { echo "check: $SRC not found" >&2; exit 2; }
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
R=$(cd "$(dirname "$0")" && pwd)
C=${CHECK_DIR:-$R/build/check}
rm -rf "$C"
mkdir -p "$C" || exit 2
fails=0
step() { # step NAME COMMAND...
  name=$1; shift
  t0=$(date +%s)
  "$@" > "$C/$name.log" 2>&1
  rc=$?
  t1=$(date +%s)
  if [ $rc -eq 0 ]; then echo "PASS $name ($((t1 - t0)) s)"; else echo "FAIL $name rc=$rc ($((t1 - t0)) s), log $C/$name.log"; fails=$((fails + 1)); fi
  return $rc
}
cd "$R" || exit 2
step build sh build.sh || { echo "check: build failed, nothing else can run"; exit 1; }
step json env W="$C/json-work" bash tests/json/run.sh
step fts env WORK="$C/fts-work" sh tests/fts/run.sh "$SRC"
step import env LIVE="$SRC" sh tests/import/run.sh "$C/import-work"
rm -rf "$C/json-work" "$C/fts-work" "$C/import-work"
if step parity env PARITY_WORK="$C/parity-work" PARITY_EVIDENCE="$C/parity" sh tests/parity/run.sh "$SRC"; then
  step mutant env MUTANT_WORK="$C/mutant-work" MUTANT_EVIDENCE="$C/parity" sh tests/parity/mutant.sh "$SRC"
  rm -rf "$C/mutant-work"
  step load env PARITY_WORK="$C/parity-work" LOAD_WORK="$C/load-work" LOAD_EVIDENCE="$C/load" sh tests/load/run.sh "$SRC"
  rm -rf "$C/load-work"
  step conc env PARITY_WORK="$C/parity-work" CONC_WORK="$C/conc-work" CONC_EVIDENCE="$C/conc" sh tests/conc/run.sh "$SRC"
  rm -rf "$C/conc-work"
  step claims env PARITY_GEN="$R/tests/claims/gen.sh" PARITY_WORK="$C/claims-work" PARITY_EVIDENCE="$C/claims" sh tests/parity/run.sh "$SRC"
  rm -rf "$C/claims-work"
else
  echo "SKIP mutant, load, conc, claims (they need a passing parity run)"; fails=$((fails + 4))
fi
if [ $fails -eq 0 ]; then echo "check: ALL PASS"; exit 0; fi
echo "check: $fails step(s) failed"; exit 1

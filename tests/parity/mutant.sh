#!/bin/sh
# tests/parity/mutant.sh : negative control for the parity gate (spec/PARITY.md).
#   sh tests/parity/mutant.sh SRC.db
# Builds a mutant server whose LIKE-fallback score in o_search_row is 0.71 instead of 0.7, runs the
# full gate against it with scratch work/evidence directories, and expects the gate to FAIL.
# Writes $MUTANT_EVIDENCE/mutant.txt (default evidence/parity). Exit 0 only when the mutant is caught
# (gate rc 1 with at least one FAIL record), 1 when it survives, 2 on a setup error.
set -u
SRC=${1:?usage: mutant.sh SRC.db}
R=$(cd "$(dirname "$0")/../.." && pwd)
M=${MUTANT_WORK:-$R/build/mutant}
EV=${MUTANT_EVIDENCE:-$R/evidence/parity}
mkdir -p "$EV"
[ -s "$R/build/cortex.unit.om" ] || { echo "mutant: build first (sh build.sh)" >&2; exit 2; }
OMC=$(sh "$R/tools/omc.sh") || exit 2
rm -rf "$M" && mkdir -p "$M/ev"
# the one mutation: the first `s = 0.7` after `fn o_search_row` in the server unit
awk 'BEGIN{n=0} /^fn o_search_row/{f=1} f && n==0 && $0=="s = 0.7" {print "s = 0.71"; n=1; next} {print} END{if(n!=1) exit 3}' \
  "$R/build/cortex.unit.om" > "$M/cortex.unit.om" || { echo "mutant: site not found" >&2; exit 2; }
CHG=$(diff "$R/build/cortex.unit.om" "$M/cortex.unit.om" | grep -c '^[<>]')
[ "$CHG" -eq 2 ] || { echo "mutant: expected one changed line, got $CHG diff lines" >&2; exit 2; }
"$OMC" < "$M/cortex.unit.om" > "$M/cortex" 2> "$M/cortex.err"
if [ $? -ne 0 ] || [ -s "$M/cortex.err" ]; then echo "mutant: compile failed: $(cat "$M/cortex.err")" >&2; exit 2; fi
chmod +x "$M/cortex"
CORTEX_BIN=$M/cortex PARITY_WORK=$M/work PARITY_EVIDENCE=$M/ev sh "$R/tests/parity/run.sh" "$SRC" > "$M/run.log" 2>&1
GRC=$?
NF=$(grep -c '^FAIL ' "$M/ev/report.txt" 2>/dev/null)
NF=${NF:-0}
{
  echo "parity mutant $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mutation   o_search_row LIKE score s = 0.7 -> s = 0.71 (one line of build/cortex.unit.om)"
  echo "mutant     sha256 $(sha256sum < "$M/cortex" | cut -c1-64)"
  echo "gate rc    $GRC (expected 1)"
  grep '^TOTAL' "$M/ev/report.txt"
  echo "failing classes (records):"
  grep '^FAIL ' "$M/ev/report.txt" | awk '{print $3}' | sort | uniq -c
  echo "first FAIL lines:"
  grep '^FAIL ' "$M/ev/report.txt" | head -5
} > "$EV/mutant.txt"
if [ "$GRC" -eq 1 ] && [ "$NF" -gt 0 ]; then
  echo "MUTANT CAUGHT" >> "$EV/mutant.txt"; cat "$EV/mutant.txt"; exit 0
fi
echo "MUTANT SURVIVED" >> "$EV/mutant.txt"; cat "$EV/mutant.txt"; exit 1

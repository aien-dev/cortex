#!/bin/sh
# build.sh : compile the Omega Cortex server and importer with the pinned omc (tools/omc.sh).
#   build/cortex         server  (one OM-2 unit, module order below; see spec/BUILD-CONTRACT.md)
#   build/cortex-import  cortex-rs SQLite -> Cortex log importer
#   build/SHA256SUMS     sha256 of both binaries, their units and the compiler
# A compile is accepted only with rc 0 and empty stderr. Exit 0 only when both builds are accepted.
set -u
if [ -z "${CXO_NICED:-}" ]; then CXO_NICED=1 exec nice -n 19 ionice -c3 sh "$0" "$@"; fi
R=$(cd "$(dirname "$0")" && pwd)
B=$R/build
OMC=$(sh "$R/tools/omc.sh") || exit 1
mkdir -p "$B"
SERVER="f64 uni_rust json crc32c uni_fts flog fts like http store log api api2 api3 qs enc de main"
IMPORT="crc32c sqlite import_main"
unit() { # unit OUT MODULES...
  out=$1; shift
  { echo om2; for m in "$@"; do cat "$R/om/$m.om"; done; } > "$out.unit.om"
}
compile() { # compile NAME
  rm -f "$B/$1" "$B/$1.tmp"
  "$OMC" < "$B/$1.unit.om" > "$B/$1.tmp" 2> "$B/$1.err"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -s "$B/$1.err" ]; then
    echo "build: $1 FAILED rc=$rc: $(cat "$B/$1.err")" >&2
    rm -f "$B/$1.tmp"
    return 1
  fi
  chmod +x "$B/$1.tmp" && mv "$B/$1.tmp" "$B/$1"
  echo "build: $1 ok fns=$(grep -c '^fn ' "$B/$1.unit.om")"
}
# shellcheck disable=SC2086
unit "$B/cortex" $SERVER
# shellcheck disable=SC2086
unit "$B/cortex-import" $IMPORT
compile cortex || exit 1
compile cortex-import || exit 1
(cd "$B" && sha256sum cortex cortex-import cortex.unit.om cortex-import.unit.om) > "$B/SHA256SUMS"
echo "omc $(sha256sum "$OMC" | cut -d' ' -f1)  (omega-mv 91b3c932)" >> "$B/SHA256SUMS"
cat "$B/SHA256SUMS"

#!/bin/sh
# omcbuild.sh OUTBIN SRC.om... : concatenate sources as one OM-2 unit (the server build prepends
# `om2` too) and compile with the pinned omc. Fails unless compile rc is 0 and stderr is empty.
set -u
OMC=$(sh "$(dirname "$0")/../../tools/omc.sh") || exit 1
out=$1; shift
unit="$out.unit.om"
{ echo om2; cat "$@"; } > "$unit"
rm -f "$out"
"$OMC" < "$unit" > "$out.tmp" 2> "$out.err"
rc=$?
if [ "$rc" -ne 0 ] || [ -s "$out.err" ]; then
  echo "omcbuild: $out compile rc=$rc: $(cat "$out.err")" >&2
  rm -f "$out.tmp"
  exit 1
fi
mv "$out.tmp" "$out" && chmod +x "$out"
echo "omcbuild: $out ok sha256=$(sha256sum "$out" | cut -d' ' -f1) unit_sha256=$(sha256sum "$unit" | cut -d' ' -f1) fns=$(grep -c '^fn ' "$unit")"

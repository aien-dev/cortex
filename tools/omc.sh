#!/bin/sh
# tools/omc.sh : print the path of the pinned Omega compiler (aien-dev/omega-mv 91b3c932,
# seed/out/omc, sha256 189ada82...). Uses $OMC when set; otherwise extracts the binary once from an
# omega-mv clone ($OMEGA_REPO, default /tmp/cxo/omega) into build/omc. Exit 1 on a pin mismatch.
set -u
PIN_REV=91b3c932
PIN_SHA=189ada82e00bb440cb41351bd252cc68c54a1b1050051cc42a1df700081c3b54
R=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${OMC:-}" ]; then
  OMC=$R/build/omc
  if [ ! -x "$OMC" ]; then
    mkdir -p "$R/build"
    REPO=${OMEGA_REPO:-/tmp/cxo/omega}
    if ! git -C "$REPO" show "$PIN_REV:seed/out/omc" > "$OMC.tmp"; then
      echo "omc.sh: cannot read $PIN_REV:seed/out/omc from $REPO" >&2
      rm -f "$OMC.tmp"
      exit 1
    fi
    chmod +x "$OMC.tmp" && mv "$OMC.tmp" "$OMC"
  fi
fi
have=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$have" != "$PIN_SHA" ]; then
  echo "omc.sh: $OMC sha256 $have != pinned $PIN_SHA" >&2
  exit 1
fi
echo "$OMC"

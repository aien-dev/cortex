#!/bin/sh
# usage: cc.sh out files...   (dev helper: one OM-2 unit, pinned omc via tools/omc.sh)
out=$1; shift
OMC=$(sh "$(dirname "$0")/../omc.sh") || exit 1
(echo om2; cat "$@") > $out.om; "$OMC" < $out.om > $out 2> $out.err; rc=$?; echo rc=$rc; cat $out.err; L=$(sed -n 's/.*line \([0-9]*\).*/\1/p' $out.err); [ -n "$L" ] && sed -n "${L}p" $out.om; chmod +x $out

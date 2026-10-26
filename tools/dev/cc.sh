#!/bin/sh
# usage: cc.sh out files...
out=$1; shift
(echo om2; cat "$@") > $out.om; /tmp/cxo/omega/seed/out/omc < $out.om > $out 2> $out.err; rc=$?; echo rc=$rc; cat $out.err; L=$(sed -n 's/.*line \([0-9]*\).*/\1/p' $out.err); [ -n "$L" ] && sed -n "${L}p" $out.om; chmod +x $out

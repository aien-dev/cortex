#!/bin/sh
# tests/import/run.sh - SqliteImport module checks (crc32c.om, sqlite.om, import_main.om).
# Oracles: /usr/bin/sqlite3 3.45.1 (oracle.sh dump with hex()/typeof()/ieee754_to_blob()/rowid),
# Python 3 walfix.py / realcheck.py (independent WAL + record parsers, fixture edits only), and a
# Python CRC-32C reference. Omega programs are built with the pinned omc (omcbuild.sh).
# usage: sh tests/import/run.sh [WORKDIR]    (default /tmp/cxo/impwork/run; needs ~400 MB)
# Prints PASS/FAIL per check, NEG lines are negative controls that must observe a failure.
set -u
# host rule: run at lowest CPU and I/O priority (re-exec once under nice -n 19 / ionice -c3).
# Delete WORKDIR afterwards (about 1.2 GB); the cited evidence is evidence/import/run.log.
if [ -z "${CXO_NICED:-}" ]; then CXO_NICED=1 exec nice -n 19 ionice -c3 sh "$0" "$@"; fi
T=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$T/../.." && pwd)
W=${1:-/tmp/cxo/impwork/run}
LIVE=${LIVE:-/tmp/cxo/data/cortex-copy.db}
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
# same: importer dump of DB equals the sqlite3 oracle dump of a scratch copy of DB (+ its -wal)
imp_dump() { # imp_dump NAME DBPATH -> NAME.log NAME.dump NAME.imperr
  rm -f "$1.log"
  "$W/cortex-import" "$2" "$1.log" > "$1.impout" 2> "$1.imperr"; echo $? > "$1.rc"
  [ "$(cat "$1.rc")" = 0 ] && "$W/logdump" "$1.log" > "$1.dump"
}
oracle_dump() { # oracle_dump NAME DBPATH -> NAME.oracle (on a scratch copy)
  rm -rf "o_$1"; mkdir "o_$1"; cp "$2" "o_$1/x.db"
  [ -e "$2-wal" ] && cp "$2-wal" "o_$1/x.db-wal"
  sh "$T/oracle.sh" "o_$1/x.db" > "$1.oracle"
}
nobad() { ! grep -q 'BAD:' "$1"; }

echo "== toolchain"
OMC=$(sh "$R/tools/omc.sh") || exit 1
export OMC
echo "omc $(sha256sum "$OMC" | cut -d' ' -f1) (omega-mv 91b3c932, tools/omc.sh)"
echo "sqlite3 $(/usr/bin/sqlite3 --version | cut -d' ' -f1-2)"
echo "python $(python3 --version 2>&1)"
for f in om/crc32c.om om/sqlite.om om/import_main.om tests/import/logdump.om tests/import/crctest.om; do
  echo "src $(sha256sum "$R/$f" | cut -d' ' -f1) $f fns=$(grep -c '^fn ' "$R/$f")"
done
echo "fns library+program (crc32c+sqlite+import_main): $(cat "$R/om/crc32c.om" "$R/om/sqlite.om" "$R/om/import_main.om" | grep -c '^fn ')"

echo "== build"
sh "$T/omcbuild.sh" "$W/cortex-import" "$R/om/crc32c.om" "$R/om/sqlite.om" "$R/om/import_main.om" || exit 1
sh "$T/omcbuild.sh" "$W/logdump" "$R/om/crc32c.om" "$T/logdump.om" || exit 1
sh "$T/omcbuild.sh" "$W/crctest" "$R/om/crc32c.om" "$T/crctest.om" || exit 1

echo "== crc32c"
check crc_check_value [ "$(printf 123456789 | ./crctest)" = e3069283 ]
check crc_empty [ "$(printf '' | ./crctest)" = 00000000 ]
head -c 8388608 /dev/urandom > r8m.bin
refcrc() { python3 -c "
import sys
t=[]
for n in range(256):
    c=n
    for _ in range(8): c=(c>>1)^0x82F63B78 if c&1 else c>>1
    t.append(c)
c=0xFFFFFFFF
for b in open(sys.argv[1],'rb').read(): c=t[(c^b)&255]^(c>>8)
print('%08x'%(c^0xFFFFFFFF))" "$1"; }
for n in 1 7 8 65535 65536 65537 1000003 8388608; do
  head -c $n r8m.bin > r.bin
  check "crc_random_${n}B_vs_python" [ "$(./crctest < r.bin)" = "$(refcrc r.bin)" ]
done
sed 's/2197175160/2197175161/' "$R/om/crc32c.om" > crc_mutant.om
sh "$T/omcbuild.sh" "$W/crcmut" crc_mutant.om "$T/crctest.om" > /dev/null || exit 1
if [ "$(printf 123456789 | ./crcmut)" = e3069283 ]; then bad "NEG crc_poly_mutant_detected"; else ok "NEG crc_poly_mutant_detected (mutant gives $(printf 123456789 | ./crcmut))"; fi

echo "== on-disk REAL storage (independent parser)"
# expected serial types from sqlite3.c 3.45 OP_MakeRecord: an integral REAL is stored as the
# smallest integer type (0 -> 8, 1 -> 9) unless it needs 8 bytes (> 2^47-1), then as float (7).
rm -f real.db; /usr/bin/sqlite3 real.db "CREATE TABLE t(c REAL); INSERT INTO t VALUES (1.0),(0.5),(-3.0),(0.0),(1e14),(1e15);"
st=$(python3 "$T/realcheck.py" real.db); echo "serial types rowid:type = $st"
check integral_reals_stored_as_integers [ "$st" = "1:9 2:7 3:1 4:8 5:5 6:7" ]

echo "== live copy ($LIVE)"
cp "$LIVE" live.db
[ -e "$LIVE-wal" ] && cp "$LIVE-wal" live.db-wal
sha256sum live.db
for i in 1 2 3; do
  rm -f live.log
  t0=$(date +%s%N); ./cortex-import live.db live.log > live.impout 2> live.imperr; rc=$?; t1=$(date +%s%N)
  echo "live import run $i rc=$rc wall_ms=$(( (t1 - t0) / 1000000 )) $(cat live.impout)"
done
cat live.imperr
"$W/logdump" live.log > live.dump
oracle_dump live live.db
check live_oracle_has_no_BAD nobad live.oracle
check live_summary [ "$(cat live.impout)" = "IMPORT OK spaces=9 entities=6327 claims=0 fts=3576" ]
check live_dump_equals_sqlite3 cmp live.dump live.oracle
echo "live log $(stat -c %s live.log) bytes, dump lines $(wc -l < live.dump), sha256 $(sha256sum live.log | cut -d' ' -f1)"
cp live.oracle live.oracle.mut
python3 - live.oracle.mut <<'EOF'
import sys
p = sys.argv[1]; b = bytearray(open(p, 'rb').read())
i = b.index(b'|f:') + 3; b[i] = ord('0') if b[i] != ord('0') else ord('1')
open(p, 'wb').write(b)
EOF
if cmp -s live.dump live.oracle.mut; then bad "NEG diff_detects_one_f64_digit"; else ok "NEG diff_detects_one_f64_digit"; fi

echo "== synthetic databases (schema.sql = cortex-rs init_schema, fill.sql)"
for v in s512:512:0 s4k:4096:0 s64k:65536:0 sres:1024:40; do
  n=${v%%:*}; r=${v##*:}; p=${v#*:}; p=${p%%:*}
  rm -f $n.db; { echo "PRAGMA page_size=$p;"; cat "$T/schema.sql" "$T/fill.sql"; } | /usr/bin/sqlite3 -bail $n.db
  [ "$r" != 0 ] && /usr/bin/sqlite3 $n.db ".filectrl reserve_bytes $r" "VACUUM"
  echo "$n page_size=$(/usr/bin/sqlite3 $n.db 'pragma page_size') reserved=$(od -An -tu1 -j20 -N1 $n.db | tr -d ' ') pages=$(/usr/bin/sqlite3 $n.db 'pragma page_count') maxpayload=$(/usr/bin/sqlite3 $n.db 'select max(length(cast(content as blob))) from entities')"
  imp_dump $n $n.db; cat $n.impout
  oracle_dump $n $n.db
  check "${n}_oracle_has_no_BAD" nobad $n.oracle
  check "${n}_dump_equals_sqlite3" cmp $n.dump $n.oracle
done
check s512_has_nulls_overflow_claims sh -c "grep -q '|null|' s512.dump && grep -c '^CLAIM' s512.dump | grep -qx 294 && awk 'length > 600000' s512.dump | grep -q ENTITY"

echo "== WAL"
sh "$T/mkwal.sh" "$W/wal" || exit 1
for s in snap1 snap3; do
  echo "$s walfix: $(python3 "$T/walfix.py" info wal/$s/w.db-wal)"
  imp_dump $s wal/$s/w.db; cat $s.imperr $s.impout
  oracle_dump $s wal/$s/w.db
  check "${s}_dump_equals_sqlite3" cmp $s.dump $s.oracle
done
cp wal/w.db final.db; oracle_dump final final.db
check snap3_equals_committed_state_after_close cmp snap3.dump final.oracle
inf=$(python3 "$T/walfix.py" info wal/snap3/w.db-wal)
V=$(echo "$inf" | sed 's/.*valid=\([0-9]*\).*/\1/'); M=$(echo "$inf" | sed 's/.*committed=\([0-9]*\).*/\1/')
C1=$(echo "$inf" | sed 's/.*commits=\([0-9]*\),.*/\1/')
check snap3_has_uncommitted_trailing_frames [ "$V" -gt "$M" ]
check snap3_importer_reports_same_frames grep -q "valid=$V committed=$M" snap3.imperr
U=$(printf UNCOMMITTED | od -An -tx1 | tr -d ' \n' | tr a-f A-F)
check snap3_dump_lacks_uncommitted_rows sh -c "! grep -q '$U' snap3.dump && ! grep -q 't:756E632D' snap3.dump"
check snap3_differs_from_snap1 sh -c "! cmp -s snap3.dump snap1.dump"

mkdir -p flip; cp wal/snap3/w.db wal/snap3/w.db-wal flip/
python3 "$T/walfix.py" flipck flip/w.db-wal $((C1 + 1))
echo "flip frame $((C1 + 1)) walfix: $(python3 "$T/walfix.py" info flip/w.db-wal)"
imp_dump flip flip/w.db; cat flip.imperr
oracle_dump flip flip/w.db
check "NEG flipped_cksum_stops_overlay_at_frame_$((C1 + 1))" grep -q "valid=$C1 committed=$C1" flip.imperr
check flip_dump_equals_sqlite3 cmp flip.dump flip.oracle
check flip_dump_equals_txn1_state cmp flip.dump snap1.dump

mkdir -p be; cp wal/snap3/w.db wal/snap3/w.db-wal be/
python3 "$T/walfix.py" be be/w.db-wal
echo "be walfix: $(python3 "$T/walfix.py" info be/w.db-wal) magic=$(od -An -tx1 -N4 be/w.db-wal | tr -d ' ')"
imp_dump be be/w.db; cat be.imperr
oracle_dump be be/w.db
check bigendian_cksum_dump_equals_sqlite3 cmp be.dump be.oracle
check bigendian_cksum_equals_native cmp be.dump snap3.dump

mkdir -p magic; cp wal/snap3/w.db wal/snap3/w.db-wal magic/
printf '\377' | dd of=magic/w.db-wal bs=1 seek=3 conv=notrunc 2> /dev/null
imp_dump magic magic/w.db; cat magic.imperr
oracle_dump magic magic/w.db
check badmagic_wal_ignored_like_sqlite grep -q 'WAL ignored' magic.imperr
check badmagic_dump_equals_sqlite3 cmp magic.dump magic.oracle

mkdir -p ver; cp wal/snap3/w.db wal/snap3/w.db-wal ver/
python3 "$T/walfix.py" version ver/w.db-wal 3007001
rm -f ver.log; ./cortex-import ver/w.db ver.log 2> ver.imperr; rc=$?; cat ver.imperr
check "wal_version_3007001_refused(rc=$rc)" sh -c "[ $rc = 14 ] && [ ! -e ver.log ] && [ ! -e ver.log.tmp ]"

echo "== refusals"
rm -f u16.db; /usr/bin/sqlite3 u16.db "PRAGMA encoding='UTF-16le'; CREATE TABLE spaces(x);"
./cortex-import u16.db u16.log 2> u16.err; rc=$?; cat u16.err
check "utf16_refused(rc=$rc)" sh -c "[ $rc = 9 ] && [ ! -e u16.log ]"
h0=$(sha256sum s512.log | cut -d' ' -f1)
./cortex-import s512.db s512.log 2> exist.err; rc=$?; cat exist.err
check "existing_out_refused_and_untouched(rc=$rc)" sh -c "[ $rc = 53 ] && [ $h0 = \$(sha256sum s512.log | cut -d' ' -f1) ]"
touch t.log.tmp; ./cortex-import s512.db t.log 2> tmp.err; rc=$?; cat tmp.err
check "existing_out_tmp_refused(rc=$rc)" sh -c "[ $rc = 54 ] && [ ! -e t.log ]"
head -c 4096 r8m.bin > notdb.db; ./cortex-import notdb.db nd.log 2> nd.err; rc=$?; cat nd.err
check "non_sqlite_refused(rc=$rc)" [ $rc = 5 ]
head -c 100000 s4k.db > trunc.db; ./cortex-import trunc.db tr.log 2> tr.err; rc=$?; cat tr.err
check "truncated_db_refused(rc=$rc)" sh -c "[ $rc != 0 ] && [ ! -e tr.log ] && [ ! -e tr.log.tmp ]"
cp s4k.db badpg.db; croot=$(/usr/bin/sqlite3 s4k.db "select rootpage from sqlite_master where name='claims'")
ctype=$(od -An -tx1 -j$(( (croot - 1) * 4096 )) -N1 s4k.db | tr -d ' ')
printf '\002' | dd of=badpg.db bs=1 seek=$(( (croot - 1) * 4096 )) conv=notrunc 2> /dev/null
./cortex-import badpg.db bp.log 2> bp.err; rc=$?; cat bp.err
check "late_refusal_removes_OUT_tmp(claims root $croot type $ctype->02, rc=$rc)" sh -c "[ $rc = 18 ] && [ ! -e bp.log ] && [ ! -e bp.log.tmp ]"
./cortex-import s512.db 2> usage.err; rc=$?; cat usage.err
check "usage(rc=$rc)" [ $rc = 2 ]

echo "== log decoder negative controls"
cp s512.log crc.log
flip() { python3 -c "import sys; p=sys.argv[1]; o=int(sys.argv[2]); b=bytearray(open(p,'rb').read()); b[o]^=1; open(p,'wb').write(b)" "$1" "$2"; }
flip crc.log $(( 8 + 8 + 20 ))
./logdump crc.log > crc.dump; rc=$?; tail -1 crc.dump
check "NEG corrupted_payload_byte_detected_CRCFAIL(rc=$rc)" [ $rc = 3 ]
cp s512.log crc2.log
flip crc2.log 12
./logdump crc2.log > crc2.dump; rc=$?; tail -1 crc2.dump
check "NEG corrupted_crc_field_detected(rc=$rc)" [ $rc = 3 ]
head -c $(( $(stat -c %s s512.log) - 5 )) s512.log > torn.log
./logdump torn.log > torn.dump; rc=$?; tail -1 torn.dump
check "NEG torn_tail_detected(rc=$rc)" [ $rc = 4 ]

echo "== result: PASS=$pass FAIL=$fail"
[ $fail = 0 ]

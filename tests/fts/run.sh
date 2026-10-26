#!/bin/sh
# tests/fts/run.sh : differential tests of om/uni_fts.om, om/flog.om, om/fts.om, om/like.om
# against SQLite 3.45.0 (sqlite3.c of libsqlite3-sys 0.28.0, built with the -D flags of its
# build.rs and gcc -O3 like the cc crate inside cortex-rs) and glibc libm, plus negative controls.
#
# usage: sh tests/fts/run.sh [DB]       DB defaults to /tmp/cxo/data/cortex-copy.db (read only)
# env:   OMC (pinned compiler), SQLITE_SRC (dir with sqlite3.c/sqlite3.h), WORK (scratch dir)
# exit 0 only when every differential is bit-identical AND every negative control is detected.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DB=${1:-/tmp/cxo/data/cortex-copy.db}
OMC=${OMC:-/tmp/cxo/omega/seed/out/omc}
SQLITE_SRC=${SQLITE_SRC:-$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/libsqlite3-sys-0.28.0/sqlite3}
WORK=${WORK:-/tmp/cxo/fts-work/run}
EV="$ROOT/evidence/fts"
N="nice -n 19 ionice -c3"
mkdir -p "$WORK" "$EV"
LOG="$EV/run.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail=0
check() { # name, expect(0=same,1=differ), file_a, file_b
  if cmp -s "$3" "$4"; then r=same; else r=differ; fi
  if { [ "$2" = 0 ] && [ $r = same ]; } || { [ "$2" = 1 ] && [ $r = differ ]; }; then
    say "PASS $1 ($r)"
  else
    say "FAIL $1 ($r)"; fail=1
  fi
}
say "date $(date -u +%FT%TZ) host $(uname -m)"
say "omc $(sha256sum "$OMC" | cut -c1-64)"
say "sqlite3.c $(sha256sum "$SQLITE_SRC/sqlite3.c" | cut -c1-64)"
say "libm $(sha256sum "$(readlink -f /lib/aarch64-linux-gnu/libm.so.6)" | cut -c1-64)"
say "db $(sha256sum "$DB" | cut -c1-64)"
say "gcc $(gcc --version | head -1)"
for f in uni_fts flog fts like; do say "om/$f.om $(sha256sum "$ROOT/om/$f.om" | cut -c1-64) fns=$(grep -c '^fn ' "$ROOT/om/$f.om")"; done

# ---- oracle ----
FLAGS="-DSQLITE_CORE -DSQLITE_DEFAULT_FOREIGN_KEYS=1 -DSQLITE_ENABLE_API_ARMOR -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ENABLE_MEMORY_MANAGEMENT -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_STAT2 -DSQLITE_ENABLE_STAT4 -DSQLITE_SOUNDEX -DSQLITE_THREADSAFE=1 -DSQLITE_USE_URI -DHAVE_USLEEP=1 -D_POSIX_THREAD_SAFE_FUNCTIONS -DHAVE_ISNAN -DHAVE_LOCALTIME_R"
if [ ! -x "$WORK/oracle" ] || [ "$HERE/oracle.c" -nt "$WORK/oracle" ]; then
  [ -f "$WORK/sqlite3.o" ] || $N gcc -O3 -fPIC -ffunction-sections -fdata-sections $FLAGS -I"$SQLITE_SRC" -c "$SQLITE_SRC/sqlite3.c" -o "$WORK/sqlite3.o" || exit 2
  $N gcc -O2 -I"$SQLITE_SRC" -c "$HERE/oracle.c" -o "$WORK/oracle.o" && gcc -o "$WORK/oracle" "$WORK/oracle.o" "$WORK/sqlite3.o" -lm -lpthread -ldl || exit 2
fi
O="$WORK/oracle"
$O plan "$DB" | tee -a "$LOG"

# ---- build harnesses (library files concatenated in build order + harness) ----
build() { # name, extra files...
  name=$1; shift
  cat "$@" > "$WORK/$name.om"
  $N "$OMC" < "$WORK/$name.om" > "$WORK/$name" 2> "$WORK/$name.err"; rc=$?
  if [ $rc -ne 0 ] || [ -s "$WORK/$name.err" ]; then say "FAIL compile $name rc=$rc $(cat "$WORK/$name.err")"; exit 3; fi
  chmod +x "$WORK/$name"
}
LIB="$ROOT/om/uni_fts.om $ROOT/om/flog.om $ROOT/om/fts.om $ROOT/om/like.om $HERE/tlib.om $HERE/tdump.om"
build t_flog $LIB "$HERE/t_flog.om"
build t_tok $LIB "$HERE/t_tok.om"
build t_query $LIB "$HERE/t_query.om"
build t_like $LIB "$HERE/t_like.om"
say "compiled: t_flog t_tok t_query t_like"

# ---- inputs ----
$O dump "$DB" "$WORK/dump.bin"
$O tok "$DB" "$WORK/tok.txt"
python3 "$HERE/gen_tokf.py" "$WORK/tokf.bin" >> "$LOG"
$O tokf "$WORK/tokf.bin" "$WORK/tokf.txt"
$O log "$WORK/log.bin" 1000000 3000 4200 2>> "$LOG"
$O fma "$WORK/fma.bin" 2000000
python3 "$HERE/gen_queries.py" "$DB" "$WORK/q1.bin" 2400 20261026 >> "$LOG"
python3 "$HERE/gen_queries.py" "$DB" "$WORK/q2.bin" 3000 99 >> "$LOG"
python3 "$HERE/gen_like.py" "$DB" "$WORK/like.bin" 600 >> "$LOG"
rm -f "$WORK/mut.db"; $O mutate "$DB" "$WORK/mut.db" "$WORK/ops.txt"
say "ops $(grep -c '^D' "$WORK/ops.txt") deletes $(grep -c '^P' "$WORK/ops.txt") re-inserts"

# ---- differentials ----
if $N "$WORK/t_flog" l "$WORK/log.bin" > "$WORK/flog.txt"; then say "PASS flog vs glibc log: $(cat "$WORK/flog.txt")"; else say "FAIL flog vs glibc log: $(head -3 "$WORK/flog.txt")"; fail=1; fi
if $N "$WORK/t_flog" f "$WORK/fma.bin" > "$WORK/fma.txt"; then say "PASS flog_fma vs FMADD: $(cat "$WORK/fma.txt")"; else say "FAIL flog_fma vs FMADD: $(head -3 "$WORK/fma.txt")"; fail=1; fi
$N "$WORK/t_tok" "$WORK/dump.bin" > "$WORK/tok_om.txt"; check "tokenizer, all entities_fts rows" 0 "$WORK/tok_om.txt" "$WORK/tok.txt"
$N "$WORK/t_tok" "$WORK/tokf.bin" f > "$WORK/tokf_om.txt"; check "tokenizer, every code point + invalid UTF-8" 0 "$WORK/tokf_om.txt" "$WORK/tokf.txt"
$O query "$DB" "$WORK/q1.bin" "$WORK/q1_or.txt"
$N "$WORK/t_query" "$WORK/dump.bin" "$WORK/q1.bin" > "$WORK/q1_om.txt" 2> "$WORK/q1.time"
check "search corpus 1 (2400 queries x 5 spaces x 4 limits)" 0 "$WORK/q1_om.txt" "$WORK/q1_or.txt"
say "timing q1: $(cat "$WORK/q1.time")"
$O query "$DB" "$WORK/q2.bin" "$WORK/q2_or.txt"
$N "$WORK/t_query" "$WORK/dump.bin" "$WORK/q2.bin" > "$WORK/q2_om.txt" 2> "$WORK/q2.time"
check "search corpus 2 (3000 queries x 5 spaces x 4 limits)" 0 "$WORK/q2_om.txt" "$WORK/q2_or.txt"
say "timing q2: $(cat "$WORK/q2.time")"
$O query "$WORK/mut.db" "$WORK/q1.bin" "$WORK/qm_or.txt"
$N "$WORK/t_query" "$WORK/dump.bin" "$WORK/q1.bin" "$WORK/ops.txt" > "$WORK/qm_om.txt" 2> "$WORK/qm.time"
check "search after delete/re-insert + token-pool compaction" 0 "$WORK/qm_om.txt" "$WORK/qm_or.txt"
$O like "$DB" "$WORK/like.bin" "$WORK/like_or.txt"
$N "$WORK/t_like" "$WORK/dump.bin" "$WORK/like.bin" > "$WORK/like_om.txt"
check "LIKE (600 patterns x every entity)" 0 "$WORK/like_om.txt" "$WORK/like_or.txt"
# latency: the 200 most frequent title words as single-term queries (x 5 spaces x 4 limits)
python3 - "$DB" "$WORK/lat.bin" <<'EOF'
import collections, re, sqlite3, struct, sys
con = sqlite3.connect('file:%s?mode=ro' % sys.argv[1], uri=True)
c = collections.Counter(w.lower() for (t,) in con.execute('SELECT canonical_name FROM entities_fts') for w in re.findall(r'[A-Za-z]{3,}', t))
open(sys.argv[2], 'wb').write(b''.join(struct.pack('<I', len(w)) + w.encode() for w, _ in c.most_common(200)))
EOF
$O query "$DB" "$WORK/lat.bin" "$WORK/lat_or.txt"
$N "$WORK/t_query" "$WORK/dump.bin" "$WORK/lat.bin" > "$WORK/lat_om.txt" 2> "$WORK/lat.time"
check "single-term latency corpus (200 frequent words)" 0 "$WORK/lat_om.txt" "$WORK/lat_or.txt"
say "timing single-term: $(cat "$WORK/lat.time")"
python3 - "$WORK" >> "$LOG" <<'EOF'
import sys, collections
w = sys.argv[1]
for name in ('q1', 'q2'):
    L = open('%s/%s_or.txt' % (w, name), 'rb').read().split(b'\n')[:-1]
    st = collections.Counter(l.split()[3] for l in L)
    nz = sum(1 for l in L if not l.split()[4].endswith(b'=0'))
    rows = sum(int(l.split()[4][2:]) for l in L)
    ties = sum(1 for l in L if len(set(x.split(b':')[1] for x in l.split()[5:])) < len(l.split()[5:]))
    print('%s lines=%d ok=%d err=%d nonempty=%d rows=%d lines_with_tied_bm25=%d' % (name, len(L), st[b'ok'], st[b'err'], nz, rows, ties))
L = open('%s/like_or.txt' % w).read().split('\n')[:-1]
print('like patterns=%d err=%d matches=%d' % (len(L), sum(1 for l in L if ' err ' in l), sum(int(l.split()[2][2:]) for l in L)))
EOF

# ---- negative controls: each mutant must make its differential FAIL ----
mutant() { # name, file, python replace expression old new, harness, run command...
  name=$1; file=$2; old=$3; new=$4; harness=$5; shift 5
  mkdir -p "$WORK/mut"; cp "$ROOT/om/uni_fts.om" "$ROOT/om/flog.om" "$ROOT/om/fts.om" "$ROOT/om/like.om" "$WORK/mut/"
  python3 - "$WORK/mut/$file" "$old" "$new" <<'EOF'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old.startswith('@qutx:'):
    # change one number of the unicode table text: @qutx:INDEX, new = replacement value
    i = int(old[6:])
    a = s.index('text qutx "') + len('text qutx "'); b = s.index('"', a)
    v = s[a:b].split(' ')
    assert v[i] != new, 'mutation is a no-op'
    v[i] = new
    s = s[:a] + ' '.join(v) + s[b:]
else:
    assert s.count(old) >= 1, 'mutation anchor not found: ' + old
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
EOF
  cat "$WORK/mut/uni_fts.om" "$WORK/mut/flog.om" "$WORK/mut/fts.om" "$WORK/mut/like.om" "$HERE/tlib.om" "$HERE/tdump.om" "$HERE/$harness.om" > "$WORK/mut/h.om"
  $N "$OMC" < "$WORK/mut/h.om" > "$WORK/mut/h" 2> "$WORK/mut/h.err" || { say "FAIL negative control $name: mutant did not compile"; fail=1; return; }
  chmod +x "$WORK/mut/h"
  "$@"
}
# 1. bm25 k1 = 1.3 instead of 1.2 (K uses k1, the numerator uses k1+1)
mutant "bm25 k1=1.3" fts.om "kk = mul add kk 0.25 bitcast f64 ulong 4608083138725491507" "kk = mul add kk 0.25 1.3" t_query \
  sh -c "$N '$WORK/mut/h' '$WORK/dump.bin' '$WORK/q1.bin' > '$WORK/mut/q.txt' 2>/dev/null"
check "negative control bm25 k1=1.3 detected" 1 "$WORK/mut/q.txt" "$WORK/q1_or.txt"
# 2. bm25 without the fused last term (plain multiply-add)
mutant "bm25 unfused tail" fts.om "s = flog_fma t get qidf i s" "s = add s mul t get qidf i" t_query \
  sh -c "$N '$WORK/mut/h' '$WORK/dump.bin' '$WORK/q1.bin' > '$WORK/mut/q.txt' 2>/dev/null"
check "negative control unfused bm25 tail detected" 1 "$WORK/mut/q.txt" "$WORK/q1_or.txt"
# 3. one tokenizer table entry: aiOff[1] (index QUAO+1 = 4037) 2 -> 3, a case-fold offset
mutant "aiOff entry" uni_fts.om "@qutx:4037" "3" t_tok \
  sh -c "$N '$WORK/mut/h' '$WORK/tokf.bin' f > '$WORK/mut/t.txt' 2>/dev/null"
check "negative control tokenizer table entry detected" 1 "$WORK/mut/t.txt" "$WORK/tokf.txt"
# 4. log table: ln2lo replaced by 0
mutant "log ln2lo" flog.om "d = flog_fma flog_t 1 kd d" "d = flog_fma 0.0 kd d" t_flog \
  sh -c "$N '$WORK/mut/h' l '$WORK/log.bin' > '$WORK/mut/l.txt'; echo rc=\$? >> '$WORK/mut/l.txt'"
if grep -q 'mismatches=0' "$WORK/mut/l.txt"; then say "FAIL negative control flog ln2lo not detected"; fail=1; else say "PASS negative control flog ln2lo detected ($(head -1 "$WORK/mut/l.txt"))"; fi
# 5. LIKE without ASCII case folding
mutant "LIKE case" like.om "if not and and eq fts_lower c fts_lower c2 lt c 128 lt c2 128" "if true" t_like \
  sh -c "$N '$WORK/mut/h' '$WORK/dump.bin' '$WORK/like.bin' > '$WORK/mut/k.txt' 2>/dev/null"
check "negative control LIKE case folding detected" 1 "$WORK/mut/k.txt" "$WORK/like_or.txt"
# 6. tie order: unstable insertion (ties before earlier rows)
mutant "tie order" fts.om "if le get qrb sub p 1 b
break" "if lt get qrb sub p 1 b
break" t_query \
  sh -c "$N '$WORK/mut/h' '$WORK/dump.bin' '$WORK/q1.bin' > '$WORK/mut/q.txt' 2>/dev/null"
check "negative control unstable tie order detected" 1 "$WORK/mut/q.txt" "$WORK/q1_or.txt"

if [ $fail -eq 0 ]; then say "RESULT PASS"; else say "RESULT FAIL"; fi
exit $fail

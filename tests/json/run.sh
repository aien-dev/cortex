#!/bin/bash
# tests/json/run.sh - JsonNum module (om/f64.om, om/uni_rust.om, om/json.om): differential tests
# against a Rust oracle (serde_json 1.0.151, serde_path_to_error 0.1.20, ryu 1.0.23, zmij 1.0.23,
# chrono 0.4.45, uuid 1.26.1, rustc 1.98.1) plus negative controls (mutants that must be caught).
# Host only (Linux aarch64). The oracle and the corpora live outside the repo ($W); the oracle source is
# tests/json/oracle/. Exit 0 only when every comparison matches and every mutant is caught.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$R/tests/json
OMC=$(sh "$R/tools/omc.sh") || exit 2
W=${W:-/tmp/jn/run}
RYU_TABLE=${RYU_TABLE:-$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/ryu-1.0.23/src/d2s_full_table.rs}
N="nice -n 19 ionice -c3"
FAIL=0
mkdir -p "$W/mut"
say() { printf '%s\n' "$*"; }
step() { say "== $*"; }

step "toolchain"
say "omc $OMC sha256 $(sha256sum "$OMC" | cut -d' ' -f1)"
say "omc pinned by tools/omc.sh (omega-mv 91b3c932)"
say "rustc $(rustc +1.98.1 --version)"
for f in f64 uni_rust json; do say "om/$f.om sha256 $(sha256sum "$R/om/$f.om" | cut -d' ' -f1) functions $(grep -c '^fn ' "$R/om/$f.om")"; done

step "generated tables reproduce (ugen built with rustc 1.98.1, gen_tables.py)"
mkdir -p "$W/ugen/src"
cp "$T/gen/ugen_main.rs" "$W/ugen/src/main.rs"; cp "$T/gen/ugen_Cargo.toml" "$W/ugen/Cargo.toml"
(cd "$W/ugen" && $N cargo +1.98.1 build --release --offline -q -j2) || { say "FAIL ugen build"; exit 2; }
$N "$W/ugen/target/release/ugen" > "$W/uni.txt"
python3 "$T/gen/gen_tables.py" "$RYU_TABLE" "$W/uni.txt" > "$W/tables.txt" 2> "$W/tables.counts"
cat "$W/tables.counts"
grep -h '^text jt\(pi\|ps\|p10\|lr\|kc\|ki\|dbg\) ' "$R/om/f64.om" "$R/om/uni_rust.om" > "$W/tables.embedded"
if cmp -s "$W/tables.txt" "$W/tables.embedded"; then say "PASS tables identical to embedded text"; else say "FAIL embedded tables differ"; FAIL=1; fi

step "oracle build"
mkdir -p "$W/oracle/src"
cp "$T/oracle/Cargo.toml" "$W/oracle/Cargo.toml"; cp "$T/oracle/main.rs" "$W/oracle/src/main.rs"
(cd "$W/oracle" && $N cargo +1.98.1 build --release --offline -q -j2) || { say "FAIL oracle build"; exit 2; }
O="$N $W/oracle/target/release/jnoracle"

# build HARNESS OUT [OMDIR]: om2 + f64 + uni_rust + json + t_io + harness
build() {
  local d=${3:-$R/om}
  { echo om2; cat "$d/f64.om" "$d/uni_rust.om" "$d/json.om" "$T/t_io.om" "$T/$1.om"; } > "$2.om"
  $N "$OMC" < "$2.om" > "$2" 2> "$2.err"; local rc=$?
  if [ $rc -ne 0 ] || [ -s "$2.err" ]; then say "FAIL compile $1 rc=$rc $(cat "$2.err")"; return 1; fi
  chmod +x "$2"
}
step "harness builds"
for h in t_json t_f64 t_uni t_time t_api; do build $h "$W/$h" || FAIL=1; done
{ echo om2; cat "$R/om/f64.om" "$R/om/uni_rust.om" "$R/om/json.om" "$T/t_perf.om"; } > "$W/t_perf.om"
$N "$OMC" < "$W/t_perf.om" > "$W/t_perf" 2> "$W/t_perf.err" && chmod +x "$W/t_perf" || FAIL=1

step "corpora (deterministic seeds)"
$O gen-json 200000 12345 > "$W/json.bin"
python3 "$T/gen_big.py" > "$W/big.bin"
$O gen-f64 1000000 777 > "$W/f64.bin"
python3 "$T/rand_f64.py" 2000000 20261026 > "$W/f64r.bin"
$O gen-uni 300000 99 > "$W/uni.bin"
$O gen-time 200000 5 > "$W/time.bin"
$O gen-api 100000 4242 > "$W/api.bin"
for c in json big f64 f64r uni time api; do say "$c.bin sha256 $(sha256sum "$W/$c.bin" | cut -d' ' -f1) bytes $(stat -c %s "$W/$c.bin")"; done

# run NAME HARNESS MODE CORPUS [ARGS]  (oracle MODE on CORPUS vs harness on CORPUS)
run() {
  local name=$1 h=$2 mode=$3 c=$4; shift 4
  $O "$mode" < "$W/$c.bin" > "$W/$name.exp"
  $N "$h" "$@" < "$W/$c.bin" > "$W/$name.got"; local rc=$?
  [ $rc -eq 0 ] || say "  harness exit $rc"
  python3 "$T/cmp.py" "$name" "$W/$name.exp" "$W/$name.got" 3 || return 1
}
step "differential runs"
run json200k "$W/t_json" json json || FAIL=1
run jsonbig "$W/t_json" json big || FAIL=1
run f64mixed "$W/t_f64" f64 f64 || FAIL=1
run f64random "$W/t_f64" f64 f64r || FAIL=1
run unicode "$W/t_uni" uni uni || FAIL=1
run time_uuid "$W/t_time" time time || FAIL=1
run api_typed "$W/t_api" api api raw || FAIL=1
say "api_value_view: same corpus with the RawValue collapse on (jrvm = 0); differences must all be documents"
say "  containing the RawValue token (documented Value-vs-typed divergence)"
$N "$W/t_api" < "$W/api.bin" > "$W/api_value.got"
python3 - "$W/api.bin" "$W/api_typed.exp" "$W/api_value.got" <<'EOF' || FAIL=1
import sys
def recs(b):
    i, o = 0, []
    while i < len(b):
        n = int.from_bytes(b[i:i + 4], 'little'); o.append(b[i + 4:i + 4 + n]); i += 4 + n
    return o
d, e, g = (recs(open(p, 'rb').read()) for p in sys.argv[1:4])
bad = [k for k in range(len(e)) if e[k] != g[k]]
tok = [k for k in bad if b'$serde_json::private::RawValue' in d[k]]
print('api_value_view records %d match %d mismatch %d (all with RawValue token: %s)' % (len(e), len(e) - len(bad), len(bad), len(tok) == len(bad)))
sys.exit(0 if len(tok) == len(bad) else 1)
EOF

step "negative controls (each mutant must produce mismatches)"
# mutant NAME FILE HARNESS ORACLE_MODE CORPUS OLD NEW
mutant() {
  local name=$1 f=$2 h=$3 mode=$4 c=$5 old=$6 new=$7
  rm -rf "$W/mut/om"; cp -r "$R/om" "$W/mut/om"
  python3 - "$W/mut/om/$f" "$old" "$new" <<'EOF' || { say "FAIL mutant $1 not applicable"; return 1; }
import sys
p, old, new = sys.argv[1], sys.argv[2].replace('\\n', '\n'), sys.argv[3].replace('\\n', '\n')
s = open(p).read()
assert s.count(old) == 1, 'pattern count %d' % s.count(old)
open(p, 'w').write(s.replace(old, new))
EOF
  build "$h" "$W/mut/$h" "$W/mut/om" || return 1
  $O "$mode" < "$W/$c.bin" > "$W/mut/$name.exp"
  $N "$W/mut/$h" < "$W/$c.bin" > "$W/mut/$name.got"
  if python3 "$T/cmp.py" "mutant-$name" "$W/mut/$name.exp" "$W/mut/$name.got" 1; then
    say "FAIL negative control $name NOT caught"; return 1
  else
    say "PASS negative control $name caught"
  fi
}
mutant esc7f json.om t_json json json 'c = get jsp o\no = add o 1\nn = sub n 1\nif or lt c 32 or eq c 34 eq c 92' 'c = get jsp o\no = add o 1\nn = sub n 1\nif or or lt c 32 eq c 127 or eq c 34 eq c 92' || FAIL=1
mutant ryu_round f64.om t_f64 f64 f64 'up = ge rem vr 10 5' 'up = ge rem vr 10 6' || FAIL=1
mutant u64_overflow json.om t_json json json 'if or gt sig 1844674407370955161 gt d 5\nret js_nlong pos sig' 'if or gt sig 1844674407370955161 gt d 6\nret js_nlong pos sig' || FAIL=1
mutant final_sigma uni_rust.om t_uni uni uni 'lc = 962' 'lc = 963' || FAIL=1
mutant autosi_millis f64.om t_time time time 'if eq rem nn 1000000 0' 'if eq rem nn 100000 0' || FAIL=1
mutant dup_last_wins json.om t_json json json 'keep = true\nif lt add k 1 n\nif eq js_kcmp ulong x ulong get jcl add add s k 1 0\nkeep = false\nend\nend' 'keep = true\nif gt k 0\nif eq js_kcmp ulong x ulong get jcl sub add s k 1 0\nkeep = false\nend\nend' || FAIL=1

step "throughput (host, nice 19; machine shared with other lanes)"
uptime
for i in 1 2 3; do $N "$W/t_perf"; done

step "summary"
if [ $FAIL -eq 0 ]; then say "RESULT PASS"; else say "RESULT FAIL"; fi
exit $FAIL

# Omega Cortex — shared build contract (owner: CortexOmega)

Goal: re-implement the Cortex memory server (Rust `cortex-rs` 0.1.0, live binary
`~/.local/bin/cortex-rs` sha256 91ccba94…afe, SQLite 3.45.0 bundled, serde_json 1.0.x, ryu 1.0.x,
axum 0.7, rustc 1.98.1) in seeded Omega, byte-for-byte compatible on the wire.
Reference source: /tmp/cxo/cortex-rs/src (db.rs, handlers.rs, models.rs, embeddings.rs, auth.rs).
Repo being built: /tmp/cxo/cortex (becomes github.com/aien-dev/cortex, Apache-2.0 WITH LLVM-exception).

## Toolchain (pinned)
- Compiler: omega-mv origin/main 3364a1dfd, `/tmp/cxo/omega/seed/out/omc`,
  sha256 befb8199db8c4bca188a494dfaac2a6f0ee5c36fcea11188c75666c55fce8a1d. Do not rebuild it in place.
- Language authority: /tmp/cxo/omega/docs/one_layer/OMEGESE.md sections 3, 9 (9.4 arrays, 9.9 floats,
  9.12 const, 9.13 OM-2), 10 (host words). Fixtures: /tmp/cxo/omega/seed/host/tests/*.om,
  /tmp/cxo/omega/seed/omc/tests. Never guess syntax; compile small probes.
- Compile: `"$OMC" < prog.om > prog 2> prog.err` (rc 0 + empty stderr = accepted; never run output
  of a failed compile). Trap = exit 100+code.
- Facts that bite: local names <= 8 chars (function names <= 63); <= 6 params; 16 registers per
  function (error 12 => split the function); a `global` can NOT be passed to a user function
  (error 19) but host words (read/write/send/recv/pread/...) accept globals; `new` arrays only in a
  function's outermost block; every `while` has an implicit 1,000,000-pass cap unless `bound N`
  (N <= 999999) — for long loops use nested loops or `for i ulong n` over a computed count;
  global pool max 16,777,216 elements, 1 GiB total; at most 512 functions per compiled unit
  (keep your module lean: report your function count); omc input <= 8 MiB.

## Program structure
All server sources are concatenated in a fixed order into ONE unit (`build.sh`), so every global
and function is visible everywhere. Cross-module data passes through the callee's documented
input/output globals (caller `put`s into them, then calls). To avoid collisions:

| owner | files (om/) | global names start with | function names start with |
|---|---|---|---|
| FtsEngine | uni_fts.om, flog.om, fts.om, like.om | `q` | `fts_`, `like_`, `uf_`, `flog` |
| JsonNum | json.om, f64.om, uni_rust.om | `j` | `js_`, `num_`, `ru_` |
| SqliteImport | crc32c.om, sqlite.om, import_main.om | `k` | `crc_`, `sq_`, `imp_` |
| CortexOmega | everything else | any other letter | `cx_`, `st_`, `http_`, `api_`, ... |

Each module ships `tests/<module>/` with its own `main` harness(es), a runner script, and a
differential check against the stated oracle, plus at least one negative control (a mutant or
corrupted expected value that the check must FAIL). Evidence logs go to `evidence/<module>/`.
No `main` inside om/*.om library files except import_main.om.

## Log file format (storage; SqliteImport writes it, CortexOmega reads+writes it)
File = 8-byte header `CXLOG001` then records. Integers little-endian.
Record = u32 payload_len, u32 crc32c(payload) (Castagnoli, reflected poly 0x82F63B78, init/xorout
0xFFFFFFFF; check value of "123456789" = 0xE3069283), then payload.
Payload = u8 op, then fields. Field kinds: `str` = u32 len + bytes, len 0xFFFFFFFF = SQL NULL;
`u64`/`i64` = 8 bytes; `f64` = 8 bytes IEEE bits; `u8` = 1 byte; `blob` = like str (NULL allowed).
Ops (field order is normative):
- 1 SPACE: u64 rowid, str id, str slug, str created_at
- 2 ENTITY (full row image; replay = put by id): u64 rowid, u64 ftsrow (0 = no FTS row),
  str id, str space_id, str space_slug, str entity_type, str canonical_name, str content,
  str aliases_json, str metadata_json, f64 confidence, i64 revision, u8 retracted,
  str valid_from, str valid_to, str created_at, blob embedding
- 3 ENTITY_RETRACT: str id (retracted=1, FTS row removed)
- 4 CLAIM: u64 rowid, str id, str space_id, str space_slug, str subject_entity_id, str predicate,
  str object_entity_id, str literal_value_json, f64 confidence, str metadata_json, u8 retracted,
  str created_at
- 5 CLAIM_RETRACT: str id
- 6 ENTITY_DELETE: str id (hard delete; compaction removes all earlier records of it)
- 7 SPACE_DELETE: str slug
REAL columns stored on disk as integers by SQLite must be converted to f64; TEXT is copied as raw
bytes; `ftsrow` is the rowid in `entities_fts_content` whose c0 equals the entity id.
A torn or crc-failing tail record ends replay (the server truncates it).

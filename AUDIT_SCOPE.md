# Audit scope

Written for an outside, independent security audit. Revision described:
`3d2432aabb8cb3d8e602ac8af6160c9cb713b220` on `wip/omega-cortex`, 2026-10-26. Everything below is taken from the repository's own files at
that revision; items marked NOT_RUN were not executed while writing this document.

## What this repository is

A memory server written in seeded Omega (OM-2), built from 18 modules in `om/` concatenated into
one compiled unit by `build.sh`, and an importer built from `crc32c`, `sqlite` and `import_main`.
`spec/BUILD-CONTRACT.md` states the goal: re-implement `cortex-rs` 0.1.0 byte-for-byte on the wire.
`spec/ORACLE-OBSERVED.md` records the observed behaviour of the oracle binary. `spec/PARITY.md`
defines the wire parity gate. There is no README. The `om/` sources total 14,273 lines (largest:
`fts.om` 2,618, `json.om` 1,983, `de.om` 1,369). Licence file: Apache License 2.0;
`spec/BUILD-CONTRACT.md` states Apache-2.0 WITH LLVM-exception.

## What to review, in priority order

1. Authentication in `om/api.om`: `auth_init` reads `CORTEX_TOKEN` from the environment;
   `auth_file` falls back to `$HOME/.config/cortex/token` (the file name the oracle uses);
   `auth_check` answers 503 when no token is configured, 401 on a missing or wrong bearer, and
   calls `scope_check` for scoped tokens (403 for a space the token does not cover); `auth_eq`
   compares with an XOR fold over at most 4,096 bytes after a length check. Tokens file format
   (`om/main.om`, `tok_load`, `tok_line`): one `TOKEN SPACE[,SPACE...]` per line, `#` comments,
   file size under 1 MiB.
2. HTTP parsing in `om/http.om`: `http_read` (headers over 64 KiB without an end are refused),
   `http_body` (`BODYMAX` 2,097,152, 413 above it), `http_chunked`, `http_chunk1`, `http_fill`,
   `http_recv` with the read deadline, and `http_origin_ok` (allowed origin
   `http://127.0.0.1:18095`; per `spec/ORACLE-OBSERVED.md` the Omega server keeps loopback origins
   only). OPTIONS preflights are answered without auth, as in the oracle.
3. Listening in `om/main.om`: default host `127.0.0.1`, port 18080; `--host` accepts any IPv4
   address, so a non-loopback bind is possible by flag. `serve` handles one connection at a time;
   a slow client holds the server until its deadline.
4. Storage: `om/log.om` and `om/store.om` (record = length, CRC-32C, payload; a torn or
   CRC-failing tail ends replay and is truncated, per `spec/BUILD-CONTRACT.md`).
5. `om/sqlite.om` and `om/import_main.om`: a SQLite file and WAL parser reading untrusted pages.
6. JSON and query parsing: `om/json.om`, `om/de.om`, `om/qs.om`, `om/enc.om`.
7. `build.sh` and `tools/omc.sh`: the compiler is taken from an omega-mv clone at rev `91b3c932`
   and refused unless its sha256 matches the pin.

## Trust boundaries

- Untrusted: HTTP clients on the listening socket; request bodies and query strings; the SQLite
  database given to `cortex-import`; replies from the encoder URL.
- Trusted: the token in `CORTEX_TOKEN` or the token file, the `--tokens` file, the log file
  path, the pinned `omc` binary.
- Omega loops trap after 1,000,000 passes unless bounded (`spec/BUILD-CONTRACT.md`); a trap ends
  the process with exit 100 plus the code.

## Threat model summary

- Assets: stored memories (entities, claims, spaces), the bearer tokens, durability of
  acknowledged writes.
- Attackers considered: a local client without the token, a token holder outside its scope,
  malformed or oversized HTTP requests, a torn log tail after a crash.
- Defended: bearer auth with 503 when unconfigured, scoped tokens, body and header limits, read
  deadline, CRC-checked log records, loopback default bind and loopback-only CORS origin.
- Not defended / explicitly out of scope: TLS (plain HTTP only); concurrent clients (one
  connection at a time); a non-loopback `--host` chosen by the operator; denial of service by a
  request that hits a loop trap.

## Build from source at a pin

Needs an omega-mv clone containing rev `91b3c932`; `tools/omc.sh` extracts `seed/out/omc` from it
(`OMEGA_REPO` points at the clone, or `OMC` at an existing binary) and accepts only sha256
`189ada82e00bb440cb41351bd252cc68c54a1b1050051cc42a1df700081c3b54`.

```sh
OMEGA_REPO=/path/to/omega-mv sh build.sh
```

Output: `build/cortex`, `build/cortex-import`, `build/SHA256SUMS`. A compile is accepted only with
exit 0 and empty stderr.

## Run every test

NOT_RUN while writing this document. Each runner's header names its oracle and inputs.

```sh
sh tests/fts/run.sh DB              # needs SQLITE_SRC (sqlite3.c 3.45.0), gcc, glibc libm
sh tests/import/run.sh WORKDIR      # needs sqlite3 3.45.1 and python3; about 1.2 GB scratch
bash tests/json/run.sh              # needs the Rust oracle in tests/json/oracle and cargo
sh tests/parity/run.sh SRC.db       # needs the cortex-rs 0.1.0 binary and a copy of its database
sh tests/parity/mutant.sh SRC.db    # negative control: the gate must FAIL
sh tests/load/run.sh SRC.db         # needs the parity corpus; latency and kill -9 check
```

All runners except `tests/load/run.sh` exit 0 only when every comparison matches and every
negative control is caught. Every runner needs inputs that are not in the repository: a copy of a
cortex-rs database, the `cortex-rs` binary, or oracle toolchains. An outside auditor without those
cannot run them.

## Known limitations and NOT_RUN

- No hosted CI at this revision.
- `spec/PARITY.md` mentions `check.sh` and `spec/CORTEX-API.md`; neither is in the tree at this
  revision.
- Parity covers the oracle's wire behaviour; `POST /api/cortex/delete` and `--tokens` are
  Omega-only extensions and are not in the parity corpus (`spec/PARITY.md`).
- `tests/` holds Python, C and Rust files used only as oracles and fixture generators.
- No hardware qualification of any kind; host results only.

## Dependencies and provenance

- Production path: the pinned `omc` only. `build.sh` runs no assembler or linker step; it pipes
  the unit into `omc` and keeps its output.
- Test oracles: SQLite 3.45.0 source, `/usr/bin/sqlite3` 3.45.1, gcc, glibc libm, a Rust oracle
  (serde_json 1.0.151, ryu 1.0.23, chrono 0.4.45, uuid 1.26.1), Python 3, the `cortex-rs` 0.1.0
  binary (sha256 `91ccba94...98afe` in `spec/PARITY.md`).

## Evidence

Committed under `evidence/`:

- `evidence/parity/summary.txt`: 4,642 records, 4,642 pass, 0 fail, 3,726 masked values, with
  corpus and binary sha256s; `report.txt` per record; `mutant.txt` gate rc 1 with 172 failing
  records.
- `evidence/fts/run.log` (RESULT PASS), `evidence/import/run.log` (PASS=50 FAIL=0),
  `evidence/json/run.log` (RESULT PASS), each naming the omc sha256.
- `evidence/load/`: raw latencies, `stats.txt` computed with Wolfram and marked as one unpaired
  run (indicative, not an A/B speed claim), `crash.txt` (623 acknowledged writes before kill -9,
  623 present after restart).

These are the author's logs; they are not independent reproduction.

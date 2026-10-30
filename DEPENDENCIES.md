# Dependencies

Versions are the ones the committed evidence was produced with (Ubuntu 24.04, Linux aarch64).

## Runtime: none

`build/cortex` and `build/cortex-import` are statically linked aarch64 ELF files produced by the
Omega compiler. They use Linux system calls only: no libc, no SQLite, no TLS library, no runtime.
All server and importer logic (HTTP/1.1, JSON and float text, FTS5 tokenizer and bm25, LIKE, the
append-only log, the SQLite reader) is first-party Omega in `om/`.

## Build path (host programs that remain)

| program | version | what it does here | Omega successor |
|---|---|---|---|
| omc | aien-dev/omega-mv 91b3c932 `seed/out/omc`, sha256 189ada82…3b54 | the compiler (itself Omega) | — (the toolchain) |
| POSIX sh (dash) | 0.5.12 (Ubuntu dash, `/bin/sh`) | `build.sh` concatenates the modules into one unit, calls omc, writes SHA256SUMS | an Omega build driver (unit assembly and hashing in `.om`); not written yet |
| coreutils (`cat`, `sha256sum`, `chmod`, `mv`) | 9.4 | used by `build.sh` | same Omega build driver |
| git | 2.43.0 | `tools/omc.sh` reads the pinned omc out of an omega-mv clone | none needed: verification oracle tier (pin check against a hash) |

## Migration path (one-time, at cutover)

| program | version | what it does here | Omega successor |
|---|---|---|---|
| sqlite3 CLI | 3.45.1 | `.backup` takes a consistent read-only snapshot of a live cortex-rs database before `cortex-import` reads it | `cortex-import` reading the live file under SQLite's WAL read-lock protocol; until then the snapshot step stays a host step |

## Verification only (oracles and harness glue; never in the build or production path)

| program | version | used by |
|---|---|---|
| cortex-rs | 0.1.0, live binary sha256 91ccba94…98afe | parity gate and load test (the oracle) |
| sqlite3 CLI | 3.45.1 | parity/load copies (`.backup`), corpus extraction (`tests/parity/gen.sh`), importer oracle (`tests/import/oracle.sh`) |
| curl | 8.5.0 | readiness probes in the parity and load scripts |
| awk (GNU Awk) | 5.2.1 | corpus slicing, report counting in the scripts |
| bash | 5.2.21 | `tests/json/run.sh` |
| gcc + SQLite amalgamation | gcc 13.3.0; sqlite3.c of libsqlite3-sys 0.28.0 (SQLite 3.45.0) | FTS5/bm25/LIKE differential oracle (`tests/fts/oracle.c`) |
| glibc libm | Ubuntu 2.39 | `log` oracle in the FTS differentials |
| python3 | 3.12.3 | independent WAL/record parsers and CRC-32C reference (`tests/import`), corpus and table generators (`tests/json`, `tests/fts`) |
| rustc / cargo | 1.98.1 (`--offline`); serde_json 1.0.151, serde_path_to_error 0.1.20, ryu 1.0.23, zmij 1.0.23, chrono 0.4.45, uuid 1.26.1 | JSON and float-text differential oracle (`tests/json/oracle/`) |
| Wolfram Language evaluator | — | latency statistics in `evidence/load/stats.txt` (queries quoted there) |

The parity comparator and request driver (`tests/parity/pcmp.om`, `pdrive.om`) and the corpus
expander (`gen.om`) are Omega.

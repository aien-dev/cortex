# Cortex in Omega

A re-implementation of the Cortex memory server (cortex-rs 0.1.0) in seeded Omega. It answers the
same HTTP API with the same bytes (spec/CORTEX-API.md) and keeps its data in an append-only log
instead of SQLite. The server and the importer are single static aarch64 binaries built by the
pinned Omega compiler; nothing else runs in production (DEPENDENCIES.md).

## Status

- **Implemented and exercised on a host (Linux aarch64).** All local gates pass on a copy of a real
  Cortex database (6,327 entities): wire parity 4642/4642 records identical except masked timing
  fields (`elapsedMs`, timestamps, runtime string; 3726 masked values, 48 renamed UUIDs;
  evidence/parity), the negative-control mutant is caught (172 failing records), and every
  acknowledged write survived kill -9 and restart in the load test (evidence/load).
- **Not deployed.** No running Cortex uses it yet. spec/CUTOVER.md is a draft plan, not executed.
- No CI: the gates below are run by hand (`check.sh`). The evidence files name the exact binaries
  and inputs they were produced with.
- Linux aarch64 only (the compiler emits aarch64 ELF).
- Limits: up to 262,144 FTS documents, 16 Mi index tokens and 64 MiB of short strings (four
  16 MiB pools; about 305 bytes per entity on real data). Connections are served concurrently: a
  handler process per connection (at most `S_MAXH`) forwards each whole request to the single
  state process, so a slow client holds only its own handler (evidence/conc). Ranked search and
  recall take about 1.35x the cortex-rs wall time; get and traverse are faster.

## Build

```
OMEGA_REPO=/path/to/omega-mv sh build.sh
```

`tools/omc.sh` extracts `seed/out/omc` at omega-mv 91b3c932 from that clone into `build/omc` and
refuses any other sha256. `build.sh` writes `build/cortex`, `build/cortex-import` and
`build/SHA256SUMS`, and accepts a compile only with exit 0 and empty stderr.

## Import a cortex-rs database

```
sqlite3 'file:/path/to/cortex.db?mode=ro' '.backup /tmp/cortex-snapshot.db'
build/cortex-import /tmp/cortex-snapshot.db /path/to/cortex.log
```

The importer reads the SQLite file (and its WAL) read-only, writes the log to a temporary file,
syncs it and renames it into place; it never overwrites an existing log.

## Run

```
CORTEX_TOKEN=... build/cortex --port PORT --log /path/to/cortex.log --encoder-url URL
```

Options: `--host` (default 127.0.0.1), `--port`, `--log`, `--encoder-url`, `--tokens FILE`
(space-scoped extra tokens). Without `CORTEX_TOKEN` the token is read from the same per-user file
as cortex-rs (spec/CORTEX-API.md). `GET /health` answers without a token.

## Local gates

```
sh check.sh /path/to/cortex-snapshot.db
```

runs, one at a time and at lowest CPU/IO priority:

| step | script | what it proves |
|---|---|---|
| build | `build.sh` | both binaries compile with the pinned omc |
| json | `tests/json/run.sh` | JSON parsing, error texts and float/number text match serde_json/ryu/zmij bit for bit; mutants caught |
| fts | `tests/fts/run.sh` | tokenizer, bm25, `log` and LIKE match SQLite 3.45.0 and glibc; negative controls caught |
| import | `tests/import/run.sh` | the SQLite reader and importer match sqlite3 on real and synthetic files, WAL included; corruption detected |
| parity | `tests/parity/run.sh` | the wire gate against the cortex-rs binary (spec/PARITY.md) |
| mutant | `tests/parity/mutant.sh` | the gate fails when one score constant changes |
| load | `tests/load/run.sh` | read-mix latency of both servers and the kill -9 durability check |
| big | `tests/big/run.sh` | a snapshot padded past 16 MiB of short strings loads and reads back |
| conc | `tests/conc/run.sh` | 16 concurrent clients plus slow clients, against the latency gate |
| claims | `tests/claims/gen.sh` via the parity runner | claim create/upsert/retract parity |

The parity and load steps need the cortex-rs binary on `PATH` (or `CORTEX_ORACLE`) and use ports
18180 and 18190. The json and fts steps need their offline oracles (DEPENDENCIES.md). Logs and fresh
evidence go to `build/check/`; the committed `evidence/` is not touched. Exit 0 only when every step
passes.

## Layout

- `om/` server and importer modules (order in `build.sh`; ownership in spec/BUILD-CONTRACT.md)
- `spec/` contracts: API, build, parity rule, observed oracle behaviour, cutover draft
- `tests/` the gates; `evidence/` their committed results

License: Apache-2.0 WITH LLVM-exception (LICENSE).

## Human-Directed Agentic Engineering

Development follows Human-Directed Agentic Engineering (HDAE): humans define goals,
architecture, constraints, acceptance criteria, and stopping points; agents implement,
execute checks, diagnose failures, and revise within those boundaries. Human review
retains responsibility for claims, acceptance, and release decisions.

For the documented method and a systems-software case study, see Gregory M. Kurtzer,
[*Ginux: Building an Independent Kernel That Runs Linux Userspace through
Human-Directed Agentic Engineering* (2026)](https://doi.org/10.5281/zenodo.23682548).
This citation describes the development method, not runtime autonomy or an endorsement.

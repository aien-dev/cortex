# Wire parity gate: Omega Cortex against cortex-rs

`sh tests/parity/run.sh SRC.db` replays one fixed request corpus against the cortex-rs oracle and the
Omega server, each on its own copy of the same data, and compares the two answer streams record by
record. Exit 0 only when every record is exact or differs only as this file allows.
`sh tests/parity/mutant.sh SRC.db` is the negative control. `check.sh` runs both.

## Setup

| side | binary | port | data |
|---|---|---|---|
| oracle | `cortex-rs` 0.1.0 (sha256 `91ccba94…98afe`) | 18180 | `sqlite3 .backup` copy of SRC.db |
| Omega | `build/cortex` | 18190 | the second copy, imported by `build/cortex-import` into `cx.log` |

Both run with `CORTEX_TOKEN=paritytok` and `--encoder-url http://127.0.0.1:9`, a closed port, so every
recall takes the no-embedding path on both sides. SRC.db is opened read-only. The oracle runs first and
the Omega server second; each sees the identical sequence, so write-phase state evolves the same way.

## Corpus (`tests/parity/gen.sh`, `gen.om`, `fixed.tsv`)

One request per line: `CLASS<TAB>METHOD<TAB>PATH<TAB>FLAGS<TAB>BODY`. `~HEX` in PATH is sent
percent-encoded; FLAGS select the auth header, content type, origin and similar
(see `tests/parity/pdrive.om`). The generated part comes from the data itself: sqlite3
extracts 40 FTS vocabulary terms by frequency stride, 30 title words, 15 identifier-like words,
15 two-word phrases and 152 entities (50 per large space by stride and every row of the small
spaces). `gen.om` expands them into GET/POST search, recall, get and traverse requests with several
spaces, limits, `include_retracted` values and query shapes, including operators (` OR `, ` NOT `,
` AND `, `*`, `-x`, `(x`, `x)`) and malformed or empty queries. `fixed.tsv` adds 365 hand-written
cases: /health and HEAD, CORS preflights and origins, auth (missing, wrong, case, padding), unknown
routes and wrong methods, content types, query-string and body errors (axum Query/Json rejections,
oversize bodies), the write phase (create, read back, search, upsert, claim, traverse, retract, with
client-supplied ids), and the visitor-memory shapes the chat client sends (remember, list, forget for
a `v-<64 hex>` space, with and without explicit ids).

The corpus is deterministic for a given SRC.db; its sha256 is in `evidence/parity/summary.txt`.
POST /api/cortex/delete and `--tokens` are Omega-only extensions (spec/CORTEX-API.md) and are not
in the corpus.

## Equivalence rule (`tests/parity/pcmp.om`)

A record passes when all of these hold:

1. The status lines are byte-equal.
2. The header lines are equal as a multiset, ignoring `date` (order differs: the oracle sends
   `connection` before `date`).
3. `content-length` is equal, with three exceptions: the body needed one of the masks in 4; the
   request is a HEAD of /health or /status, both bodies are empty and Omega's length is exactly the
   oracle's plus one (the masked `runtime` value below is one byte longer); or the request is a HEAD
   of /api/cortex/search or /api/cortex/recall, both bodies are empty and the lengths differ by at
   most 24 bytes (the unseen body holds the masked `elapsedMs` number, whose text is at most 24
   bytes; observed: 727.0010540000001 from the oracle against 1.990726 from Omega).
4. The body bytes are equal except for these values:
   - an `elapsedMs` number (wall time);
   - a `committedAt`, `createdAt` or `updatedAt` string when both values are fresh (at or after the
     run start, compared on the first 19 bytes) and have the same shape;
   - server-generated UUIDs, which must follow one consistent one-to-one renaming learned only from
     `targetId`, a receipt `id` and `spaceId`; an unknown UUID anywhere else fails;
   - the /health field `"runtime"`, exactly `"native-arm64-rust"` in the oracle and
     `"native-arm64-omega"` in Omega. The Omega server reports its own runtime by decision; this is
     the only intentional difference on the wire.

Everything else, including score digits, key order, float text, ordering of ties and error texts,
must be byte-equal. Both streams must hold exactly one record per corpus line, and a transport error
on either side fails the record.

## Result (`evidence/parity/`)

`summary.txt` holds the corpus sha256, the three binary sha256s, the import summary and the per-class
counts; `report.txt` holds one PASS/FAIL line per record. The committed run: 4642 records, 4642 pass,
0 fail, 3726 masked values, 48 renamed UUIDs.

## Negative control (`tests/parity/mutant.sh`)

The mutant changes one line of the server unit, the LIKE-fallback score in `o_search_row`
(`s = 0.7` to `s = 0.71`), rebuilds it with the pinned omc and runs the whole gate with scratch work
and evidence directories. The gate must exit 1 with FAIL records. `evidence/parity/mutant.txt`
records the result: gate rc 1, 172 failing records across search, error.query and route classes.

## Fixes the gate found

- Search FTS: the live binary returns rows only from the quoted-phrase attempt
  (spec/ORACLE-OBSERVED.md); the Omega server dropped the operator and AND-joined attempts.
- Empty-query list: shifting entries during the ordered insert left stale result kinds, so later rows
  printed a previous request's score instead of 0.4.
- Comparator: byte loops over the 1.2 MB corpus and multi-megabyte bodies now run in 65,536-byte
  chunks (an Omega loop traps after 1,000,000 passes), and a mismatch inside a string value is
  located from its opening quote.

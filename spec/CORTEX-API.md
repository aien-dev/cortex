# Cortex wire contract (Omega Cortex = cortex-rs 0.1.0 on the wire)

The Omega server answers every request of cortex-rs 0.1.0 with the same bytes, apart from the
`/health` runtime field (below). "Same" is defined and checked by the parity gate (spec/PARITY.md);
edge behaviour measured on the live binary, including every error text, is in
spec/ORACLE-OBSERVED.md. This file is the summary a client needs.

## Server

```
cortex [--host 127.0.0.1] [--port 18080] --log PATH [--encoder-url URL] [--tokens FILE]
cortex-import SRC.db OUT.log
```

- `--log PATH`: the append-only Cortex log (format: spec/BUILD-CONTRACT.md). It replaces cortex-rs
  `--db-path`; the server refuses `--db-path` and tells you to import the SQLite store once with
  `cortex-import`. The importer reads a cortex-rs database (main file plus WAL, read-only) and writes
  a new log; take the source with `sqlite3 'file:DB?mode=ro' '.backup COPY'` first.
- `--encoder-url URL`: the embedding service used by recall, as in cortex-rs. When it does not answer,
  recall runs on lexical and metadata scores only, like cortex-rs.
- Every write is appended and flushed before the 201 answer; after a crash the log replays up to the
  last complete record and a torn tail is cut (checked by tests/load/run.sh with kill -9).

## Authentication

- `/health`, `/status` and CORS preflights need no token. Every `/api/cortex/*` route needs
  `Authorization: Bearer <token>`.
- The token is `CORTEX_TOKEN` from the environment; when unset or blank, `$HOME/.config/cortex/token`,
  re-read on every request. No token configured: 503
  `{"error":"Service unavailable: Cortex authentication token unconfigured on host"}`.
  Missing or wrong token: 401 `{"error":"Unauthorized: invalid or missing Cortex bearer token"}`.
  The comparison is constant-time.

## Routes

| method, path | input | success |
|---|---|---|
| GET `/health`, GET `/status` (HEAD too) | — | 200 `{"runtime":"native-arm64-omega","service":"cortex-rs","space":"atlas-memory","status":"ok","version":"0.1.0"}` |
| POST `/api/cortex/write` | JSON, `kind` = `entity` / `claim` / `retract` (fields below) | 201 `{"recorded":true,"receipt":{"id","operation","targetType","targetId","committedAt"}}` |
| GET `/api/cortex/search` | query string `q` (or `query`), `space`, `limit` (default 12, max 50), `include_retracted` | 200 `{"results":[entity + lexicalScore, graphScore, semanticScore, score],"degraded":[],"elapsedMs":…}` |
| POST `/api/cortex/search` | JSON with the same fields | same as GET |
| POST `/api/cortex/recall` | JSON `query`, `space`, `limit` (default 5, max 20), `tokenBudget` (default 1200) | 200 `{"results":[{"entity","finalScore","componentScores":{"lexical","semantic","confidenceRecency","graph"}}],"degraded":[],"elapsedMs":…}` |
| GET `/api/cortex/get` | `id` or `name`, optional `space` | 200 entity; 400 `Missing id or name parameter`; 404 `Entity not found` |
| POST `/api/cortex/traverse` | JSON `subjectId`, `space` | 200 `{"claims":[…]}` (claim keys sorted) |
| POST `/api/cortex/delete` | **Omega extension**, see below | 200 `{"deleted":N}` |

Write inputs (camelCase):
- entity: `id`?, `space` (default `atlas-memory`), `entityType` (default `discovery`),
  `canonicalName`, `content`, `aliases`, `metadata` (default `{}`), `confidence` (default 1.0),
  `validFrom`?, `validTo`?, `externalId`?. An entity with the same `space` and `canonicalName` is
  updated under its existing id and its revision increases; otherwise `id` (or a new UUID) is used.
- claim: `id`?, `space`, `subjectEntityId`, `predicate`, `objectEntityId`?, `literalValue`?,
  `confidence`, `metadata`.
- retract: `targetType` (`entity` / `claim`), `targetId`, `reason`?.

Entity objects: `id, spaceId, spaceSlug, entityType, canonicalName, content, aliases, metadata,
confidence, revision, retracted, validFrom, validTo, createdAt`.

Search: the query, with double quotes removed, is matched as one FTS5 phrase (bm25 order); when that
gives nothing, a substring match on name or content follows (score 0.7); an empty query lists the
newest entities (score 0.4). Operators such as `OR`, `NOT` or `*` are not interpreted, which is what
the live binary does (spec/ORACLE-OBSERVED.md).

Errors from body and query parsing are axum's: 400/422 with a text/plain message (415 without a JSON
content type, 413 above 2,097,152 bytes), byte-identical to cortex-rs (spec/ORACLE-OBSERVED.md).

CORS: any OPTIONS answers 200 with `access-control-allow-methods: *` and
`access-control-allow-headers: *`; `access-control-allow-origin` is echoed only for
`http://127.0.0.1:18095` and `http://localhost:18095`. Every answer carries
`vary: origin, access-control-request-method, access-control-request-headers`. The live cortex-rs
binary also allowed two non-loopback origins; the Omega server does not.

## Differences from cortex-rs (intentional)

1. `/health` and `/status` report `"runtime":"native-arm64-omega"` (cortex-rs: `native-arm64-rust`).
   The parity gate masks exactly this value.
2. **POST `/api/cortex/delete`** (not in cortex-rs; not in the parity corpus). Hard delete for data
   that must leave the disk, such as a visitor's "forget me": body `{"targetType":"entity",
   "targetId":ID}` removes one entity, `{"space":SLUG}` removes a space with its entities and claims.
   The answer is `{"deleted":N}` (live entities removed; 0 when nothing matched). The server then
   rewrites the log with the current state only, so the deleted bytes are gone from the file.
   Same authentication as the other routes. cortex-rs can only retract (the row stays on disk).
3. **`--tokens FILE`** (not in cortex-rs). Extra tokens limited to some spaces, one
   `TOKEN SPACE[,SPACE...]` per line (blank lines and `#` lines skipped). A scoped token may only
   touch the spaces listed: a request naming another space, or naming none, gets 403
   `{"error":"Forbidden: token scope does not cover this space"}`. The main token keeps full access.
   Without `--tokens` the server behaves exactly like cortex-rs.
4. Loopback-only CORS origins (above).

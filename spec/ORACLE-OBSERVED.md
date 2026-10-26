# cortex-rs 0.1.0 behaviour observed on the live binary (2026-10-26)

Binary `$HOME/.local/bin/cortex-rs` (sha256 91ccba94…afe; SQLite 3.45.0, serde 1.0.229, serde_json 1.0.151,
axum 0.7.9, tower-http 0.5.2, hyper 1.11.1, uuid 1.26.1, chrono 0.4.45, rustc 1.98.1), run on a copy of the
database with `CORTEX_TOKEN=paritytok`. Source: archived aien-dev/cortex-rs src/ (identical to the private
canonical checkout). `T` = `Authorization: Bearer paritytok`, `J` = `Content-Type: application/json`.

## Routing, auth, CORS (every response carries `vary: origin, access-control-request-method, access-control-request-headers`)
| request | status | body / headers |
|---|---|---|
| GET /health, /status | 200 | `{"runtime":"native-arm64-rust","service":"cortex-rs","space":"atlas-memory","status":"ok","version":"0.1.0"}` (content-type application/json, 108 bytes) |
| HEAD /health | 200 | headers only, content-length 108 |
| POST /health | 405 | empty, `allow: GET,HEAD` |
| any /api/cortex/* or unknown path without valid token | 401 | `{"error":"Unauthorized: invalid or missing Cortex bearer token"}`; a wrong method on a known route also carries its `allow` |
| token unset and no `$HOME/.config/cortex/token` | 503 | `{"error":"Service unavailable: Cortex authentication token unconfigured on host"}` |
| unknown path with valid token | 404 | empty |
| GET /api/cortex/recall (valid token) | 405 | `allow: POST` |
| DELETE /api/cortex/get | 405 | `allow: GET,HEAD` |
| PUT /api/cortex/search | 405 | `allow: GET,HEAD,POST` |
| OPTIONS anything (preflight or not, any origin) | 200 | `access-control-allow-methods: *`, `access-control-allow-headers: *`, `allow` of the route (none for unknown paths), `access-control-allow-origin` only for an allowed origin; no auth |
| GET with `Origin: http://localhost:18095` | normal | adds `access-control-allow-origin: http://localhost:18095`; `http://evil` gets none |
- Header `Bearer  paritytok  ` (extra spaces) is accepted (value trimmed); `bearer` lower-case is 401.
- The live binary's allow-list is 127.0.0.1:18095, localhost:18095 and two non-loopback origins (a LAN and a tailnet address, not recorded here); the archived source now keeps loopback only (AlphaAudit). The Omega server keeps loopback only.

## Body extraction (axum Json)
- Missing/other content type: 415 text/plain `Expected request with `Content-Type: application/json``. `application/vnd.x+json` is accepted.
- Syntax error: 400 text/plain `Failed to parse the request body as JSON: <path: >serde message`, e.g. `EOF while parsing an object at line 1 column 12`; empty body `EOF while parsing a value at line 1 column 0`; `value.a: EOF while parsing a value at line 1 column 33`; `value.x.y[2]: …`; `x[1][1].z: …` inside the tagged write enum; `x: EOF …` (only the key) for an ignored field of a plain struct; `query: unexpected end of hex escape at line 1 column 17`.
- Data error: 422 text/plain `Failed to deserialize the JSON body into the target type: …`:
  - recall: `missing field `query` at line 1 column 12`; `query: invalid type: integer `5`, expected a string at line 1 column 10` (also for `{"query":5,` = data error wins over the later EOF); `duplicate field `query` at line 1 column 20`; `limit: invalid value: integer `-1`, expected usize at line 1 column 23`; `limit: invalid type: floating point `1.5`, expected usize …`; `limit: invalid type: null, expected usize …`; `limit: invalid type: map, expected usize at line 1 column 21` (position = start of the map); `space: invalid type: sequence, expected a string …`; `tokenBudget: invalid type: string "x", expected usize …`; `["a"]` → `invalid length 1, expected struct RecallPayload with 4 elements at line 1 column 5`.
  - search POST: `limit: invalid type: string "5", expected usize`, `include_retracted: invalid type: integer `1`, expected a boolean`, `q: invalid type: integer `5`, expected a string`.
  - write (internally tagged enum `WritePayload`, buffered Content, no positions inside `value`): `kind: unknown variant `zap`, expected one of `entity`, `claim`, `retract` at line 1 column 13` (also when the body is truncated after it); `missing field `kind` at line 1 column 12`; `[]` → `missing field `kind` at line 1 column 2`; `5` → `invalid type: integer `5`, expected internally tagged enum WritePayload at line 1 column 1`; `kind: invalid type: integer `5`, expected variant identifier at line 1 column 9`; `duplicate field `kind` at line 1 column 23`; inside value, NO position and NO path: `invalid type: integer `5`, expected a string`, `missing field `canonicalName``, `invalid type: null, expected a string`, `invalid type: string "a", expected f64`, `invalid type: integer `5`, expected struct EntityWriteInput`, `missing field `targetId``, `duplicate field `canonicalName``, `duplicate field `value``.
- Trailing bytes after the first JSON value are ignored (`{"query":"a"} x` → 200).

## Query strings (axum Query, serde_urlencoded) → 400 text/plain `Failed to deserialize query string: …`
`duplicate field `q``; `limit=` → `cannot parse integer from empty string`; `limit=abc` and `limit=-1` → `invalid digit found in string`; `limit=+5` accepted; `limit=99999999999999999999999` → `number too large to fit in target type`; `include_retracted=yes` → `provided string was not `true` or `false``; `q` wins over `query`.

## get
No id/name → 400 `{"error":"Missing id or name parameter"}`; not found → 404 `{"error":"Entity not found"}`.

## Ordering facts
- Unscored recall rows come in `idx_entities_type` order (space_slug, entity_type, rowid) — checked with LIMIT 20.
- The LIKE fallback, get and the empty-query list scan the same index; ORDER BY with ties keeps that scan order (SQLite sorter, checked with a toy table).
- FTS: ascending rowid scan, stable sort by bm25 (FtsEngine evidence/fts).
- Search FTS on the live binary: of the three `run_fts` attempts in the archived `search_entities`
  (raw query when it holds ` AND `/` OR `/` NOT `/`*`; the quoted phrase; the terms joined with ` AND `),
  only the quoted phrase ever returns rows. Probes: `intact OR p95`, `p95 OR intact`, `intac*`,
  `hardw*`, `broke existing`, `intact AND sha` all answer `{"results":[]…}` (the same FTS5 queries
  return rows from the sqlite3 shell), and `824*` returns only the rows the phrase `"824"` matches.
  The parity corpus holds 1,100 operator and 1,000 term searches; in the 96 of them where the two rules
  give different answers, the oracle followed "phrase, then the LIKE fallback" every time. The Omega
  server implements the observed rule.

## Writes
`{"kind":"entity","value":{"canonicalName":"x","metadata":{"b":1,"a":[1.0,-0,1e2,12345678901234567890,-9223372036854775809]}}}` → 201
`{"recorded":true,"receipt":{"id":UUIDv4,"operation":"entity.upsert","targetType":"entity","targetId":UUIDv4,"committedAt":"2026-10-26T16:15:15.567077208+00:00"}}`;
get returns `"metadata":{"a":[1.0,-0.0,100.0,12345678901234567890,-9.223372036854776e+18],"b":1}` (sorted keys, zmij float text).

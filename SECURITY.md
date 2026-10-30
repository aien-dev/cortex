# Security policy

## Reporting a vulnerability

Report privately. Do not open a public issue, pull request or discussion about it.

1. GitHub: open this repository's Security tab and choose "Report a vulnerability". This
   creates a private advisory that only the maintainers can see. If that option is not shown,
   private vulnerability reporting has not been enabled for this repository yet; use email.
2. Email: drake@aienos.com with the subject `[cortex] security report`.

Include the commit or release you tested, the component (path), steps to reproduce, and what an
attacker gains. If the report involves a secret, say where it was exposed and do not send the
secret itself. Encrypted mail is not required; do not post proof-of-concept payloads publicly.

## Response targets

This project has one maintainer; the targets below are best effort and stated honestly.

- Acknowledgement: within 3 working days.
- Triage and severity: within 7 days of acknowledgement.
- Fix or mitigation for confirmed issues: aim for 30 days for high and critical, 90 days
  otherwise, with a status update at least every 14 days until closed.
- Disclosure: coordinated. An advisory is published with credit (unless you ask otherwise)
  once the fix is on the default branch. Default embargo 90 days, negotiable.

## Scope

`cortex` (the repository's default branch) is a re-implementation in seeded Omega of the Cortex memory
server `cortex-rs` 0.1.0, meant to be byte-for-byte compatible on the wire, plus `cortex-import`,
which converts a cortex-rs SQLite database into the server's append-only log (`CXLOG001`).

In scope:

- Access to `/api/cortex/*` without a valid bearer token, a token scope (`--tokens` file) that
  reaches a space it does not cover, or a token comparison that leaks the token.
- Memory safety and trap behaviour of the HTTP parser in `om/http.om` (request line, headers,
  `Content-Length`, chunked bodies, the 2,097,152-byte body limit, the 10 second read deadline).
- Corruption or loss of acknowledged writes in the log (`om/log.om`, `om/store.om`), or a crafted
  log or SQLite file that makes `cortex` or `cortex-import` misbehave.
- CORS answers that allow an origin other than the loopback origin in `om/http.om`.

Out of scope:

- `cortex-rs` itself (the oracle, not in this repository), the embedding encoder reached through
  `--encoder-url`, the pinned compiler, and the host operating system.

## Supported versions

Only the head of the default branch (currently `wip/omega-cortex`; `main` once the port is merged
there); nothing is released. Reports against older commits are welcome but fixes land on the default branch only.

## Status

Work in progress. Hosted CI compiles both units with the pinned compiler and produces an SBOM; the
differential and parity suites run locally (`check.sh`), not in CI. No certification, no
bug bounty. See AUDIT_SCOPE.md for what to review and how to build and test it.

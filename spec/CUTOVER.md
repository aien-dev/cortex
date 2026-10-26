# Cutover plan: cortex-rs to the Omega Cortex (PROPOSED, NOT EXECUTED)

Status: PROPOSED. Nothing here has been run against a production instance. Each step that stops,
switches or restarts a production Cortex needs the operator's approval. Host-specific details
(ports, service names, paths, credentials) live in the operator's private runbook, not in this
public repository.

## Order

One instance at a time. The primary instance goes first; any further instance only after the first
has run on Omega for a quiet week, and only with the operator's explicit approval (an instance that
runs under a separate system user needs a new privileged launch rule, which is a new trust path).

## Steps per instance

1. **Checkpointed import.** Snapshot without touching the live writer:
   `sqlite3 'file:DB?mode=ro' '.backup SNAP.db'`, then `cortex-import SNAP.db NEW.log`
   (refuses an existing OUT; prints `IMPORT OK spaces=… entities=… claims=… fts=…`). Compare the
   counts with `SELECT count(*)` on SNAP.db.
2. **Side-port run.** Start the Omega server on a free side port with the same token source and
   encoder URL as the production instance, under the operator's process supervisor or by hand.
3. **Shadow comparison.** Replay real read traffic to both ports and compare with
   `tests/parity/pcmp` (same equivalence rule as spec/PARITY.md). Writes made to the production
   instance after the snapshot are mirrored to the side instance in commit order
   (`tests/shadow/`), so reads that follow them are compared too. Gate: zero byte differences
   (identical except the masked timing fields: `elapsedMs`, timestamps and the `/health` runtime
   string) on rows present in both, over at least one day of real queries.
4. **Write-path checks on the build being switched in.** The wire parity gate and its mutant from a
   clean clone (`check.sh`), the concurrent writers-plus-readers load test with kill -9 mid-run
   (`tests/load/`), and claims create/upsert/retract on real-shaped data.
5. **Switch.** Pause writers, take the final snapshot and import (step 1), stop cortex-rs (do not
   delete it or its database), start the Omega server on the production port. Clients keep their
   URL.
6. **Rollback.** cortex-rs, its launch configuration and its SQLite file stay untouched during and
   after the switch. Rollback = stop the Omega server, start cortex-rs again. Writes accepted by
   Omega after the switch are not in SQLite: re-send them as `/api/cortex/write` requests (they are
   the log records after the switch time) or accept their loss explicitly.

## Known differences a client can see

- `/health` reports `"runtime":"native-arm64-omega"`.
- POST `/api/cortex/delete` and `--tokens` exist only in the Omega server (spec/CORTEX-API.md).
- A client that "forgets" by retracting keeps the retracted row on disk, as with cortex-rs; delete
  removes it from the log.

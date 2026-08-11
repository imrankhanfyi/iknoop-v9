# Lossless sensor-store compaction

## Decision

Reject automatic retention/downsampling. Old raw samples still support workout reconciliation, raw export, detailed charts, and possible sleep rescoring. Deleting or replacing them would silently change user-visible history.

Instead, convert each high-volume sensor table to SQLite `WITHOUT ROWID`. The existing tables are rowid tables with a composite primary-key autoindex, so each `(deviceId, ts)` key is stored twice. `WITHOUT ROWID` makes that primary key the table's storage b-tree: rows, values, and all public queries remain identical while the duplicate index is removed.

## Scope

Rebuild `hrSample`, `rrInterval`, `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`, and `ppgWaveformSample` in a versioned Apple/GRDB migration for this personal macOS fork. No values, timestamps, source identifiers, or public API change. An Android twin is intentionally deferred because this is a fork-local physical-storage maintenance change, not an upstream cross-platform release.

## Safety rules

- Each rebuild is transactional: create replacement, copy every column, drop old, rename replacement.
- The primary-key column order and every non-key column/default are preserved exactly.
- No automatic `VACUUM`: it can temporarily require another whole database copy and should be a separately surfaced, space-checked maintenance action.
- Tests seed all stream kinds, migrate, and prove row counts, values, primary keys, and `WITHOUT ROWID` SQL survive.

## Red-team review

1. **Could this lose historical data?** The copy happens before drop in one transaction; tests include RR's multi-row same-second key.
2. **Could it change query speed/semantics?** Range reads already query the composite primary key prefix; `WITHOUT ROWID` retains that b-tree.
3. **Does it shrink existing files immediately?** No. SQLite retains freed pages until vacuum, intentionally deferred for disk-safety.
4. **Does it solve all growth?** No. It removes duplicated index storage losslessly; an archive/aggregation design remains a future project.

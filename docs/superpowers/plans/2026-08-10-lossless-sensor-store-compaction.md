# Lossless Sensor Store Compaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove duplicate composite-primary-key storage without deleting sensor history.

**Architecture:** A versioned transactional Apple/GRDB table rebuild makes high-volume sensor tables `WITHOUT ROWID` while preserving their columns and key order.

**Tech Stack:** Swift/GRDB, Kotlin/Room, SQLite.

## Global Constraints

- Preserve every stored row and public query result.
- Do not run automatic vacuuming or raw-data retention.
- Add an Apple migration test. Android is deferred for this personal macOS fork.

### Task 1: Apple migration

**Files:** `Packages/WhoopStore/Sources/WhoopStore/Database.swift`; `Packages/WhoopStore/Tests/WhoopStoreTests/MigrationTests.swift`

- [ ] Add a v28 migration that rebuilds all seven sensor tables with identical columns/keys and `WITHOUT ROWID`.
- [ ] Write a migration test that seeds the v27 schema and proves all copied rows and the rowidless SQL survive.

### Task 2: Verification

- [ ] Run focused and full Apple tests, then validate the installed migration against the live database's row-count and time-range invariants.
- [ ] Review the migration SQL for value, key, and `WITHOUT ROWID` parity before commit.

# Stable Sleep Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a night’s detected chart/data extent stable while independently editable asleep and woke markers change only user overrides.

**Architecture:** Add a nullable immutable `detectedEndTs` to the sleep-session record, backfilled from the current end on migration. The editable window and HR query use detected bounds, while the existing effective start and mutable end retain the user’s corrected markers. Make each marker an isolated hit target and make its commit address just that marker.

**Tech Stack:** Swift, GRDB/SQLite, SwiftUI, Kotlin/Room.

**Spec:** User-approved sleep-boundary recovery design, 2026-08-18.

## Global Constraints

- All data stays on device; no network or telemetry.
- Add only forward GRDB and Room migrations; preserve existing records.
- Keep Swift/Kotlin stored schemas equivalent; Android validation is explicitly waived.
- App-target Swift must be built and the live macOS app installed for verification.

---

### Task 1: Durable detected sleep end

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/Database.swift`
- Modify: `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift`
- Modify: `android/app/src/main/java/com/noop/data/Entities.kt`
- Modify: `android/app/src/main/java/com/noop/data/WhoopDatabase.kt`

- [ ] Write a migration test that expects a nullable `detectedEndTs` column and verifies existing end values are backfilled.
- [ ] Run the focused test and confirm it fails because the column is absent.
- [ ] Add v31 GRDB and Room migrations, model field/default, read/write propagation, and an edit update that never changes `detectedEndTs`.
- [ ] Run focused store tests and inspect migration schema compatibility.

### Task 2: Fixed chart domain and isolated marker commits

**Files:**
- Modify: `Strand/Data/SleepTimelineEditDomain.swift`
- Modify: `Strand/Screens/SleepView.swift`
- Modify: `StrandTests/SleepTimelineEditDomainTests.swift`

- [ ] Write failing tests proving a source domain survives a persisted marker edit and that an asleep/woke command mutates only its own value.
- [ ] Run the focused app tests and confirm the missing API failure.
- [ ] Implement pure boundary-change and detected-domain helpers, query HR over the detected range, and replace full-width marker gesture containers with two independent handle targets.
- [ ] Run focused tests and the macOS app test target.

### Task 3: Recovery affordance and live verification

**Files:**
- Modify: `Strand/Screens/SleepView.swift`

- [ ] Add a transient Undo action for the last saved boundary change, restoring the exact previous pair.
- [ ] Build the Release app, install without re-signing, and verify the bundle signature.
- [ ] Relaunch the live app and confirm restored 06:20 wake, full detected HR range, stable pixel width, and independent marker behavior.

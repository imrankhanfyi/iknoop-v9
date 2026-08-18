# Sleep Graph Annotations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Let a person add, move, edit, and delete descriptive pins on a nightly sleep-stage timeline without changing automatic sleep results.

**Architecture:** Add a device-scoped SQLite table for timestamped annotations and expose the same CRUD contract through GRDB and Room. Apple and Android sleep cards query the displayed in-bed window and overlay neutral pins on the existing shared timeline. The editor writes annotations only; it does not affect SleepMark, staging, or analytics.

**Tech Stack:** Swift 6, GRDB/SQLite, SwiftUI (macOS/iOS), Kotlin, Room, Jetpack Compose, XCTest, JUnit.

**Spec:** docs/superpowers/specs/2026-08-17-sleep-graph-annotations-design.md

## Global Constraints

- Store deviceId TEXT, tsMs INTEGER, and type INTEGER with primary key (deviceId, tsMs, type); type codes are in-bed=0, fell-asleep=1, awake-in-bed=2, briefly-got-up=3, arose=4.
- Keep the Swift and Kotlin schema, encodings, conflict behavior, ordering, and deletion coverage byte-identical.
- Query inclusively inside the displayed in-bed window, ordered by timestamp then type; do not attach annotations to sleepSession.startTs.
- Snap additions and dragged positions to 30-second epochs. Move/type replacement is transactional and leaves one row if its target already exists.
- Keep SleepMark, stage JSON, sleep totals, efficiency, recovery, strain, staging, calibration, CSV/Health exports, and all network behavior unchanged.
- Data remains local. The backup already copies the complete SQLite database, so do not add annotation values to settings.json.

---

## File Structure

- Packages/WhoopStore/Sources/WhoopStore/SleepAnnotationStore.swift — Swift enum/row, snapping, and GRDB CRUD.
- Packages/WhoopStore/Sources/WhoopStore/Database.swift and DeviceRegistryStore.swift — v30 migration and device deletion.
- Packages/WhoopStore/Tests/WhoopStoreTests/SleepAnnotationStoreTests.swift — persistence and migration tests.
- android/app/src/main/java/com/noop/data/{Entities,WhoopDao,WhoopRepository,WhoopDatabase,DeviceRegistryDao,DeviceRegistry}.kt — Room storage twin.
- android/app/src/test/java/com/noop/data/{SleepAnnotationMigrationTest,SleepAnnotationStoreTest}.kt — Android SQL and contract tests.
- Strand/Data/SleepAnnotationEditorModel.swift and Strand/Screens/SleepView.swift — Apple coordinate model and SwiftUI overlay/editor.
- StrandTests/SleepAnnotationEditorModelTests.swift — Apple behavior tests.
- android/app/src/main/java/com/noop/ui/SleepScreen.kt and android/app/src/test/java/com/noop/ui/SleepAnnotationEditorTest.kt — Compose overlay/editor and pure interaction tests.

### Task 1: Implement and test the Swift storage contract

**Files:**
- Create: Packages/WhoopStore/Sources/WhoopStore/SleepAnnotationStore.swift
- Modify: Packages/WhoopStore/Sources/WhoopStore/Database.swift, before return migrator
- Modify: Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift, deviceScopedTables
- Create: Packages/WhoopStore/Tests/WhoopStoreTests/SleepAnnotationStoreTests.swift
- Modify: Packages/WhoopStore/Tests/WhoopStoreTests/DeviceRegistryStoreTests.swift

**Interfaces:**
- Produces public enum SleepAnnotationType: Int, CaseIterable, Codable, Sendable with .inBed=0, .fellAsleep=1, .awakeInBed=2, .brieflyGotUp=3, .arose=4.
- Produces public struct SleepAnnotationRow: Equatable, Codable, Sendable with deviceId: String, tsMs: Int64, and type: SleepAnnotationType.
- Produces WhoopStore.snappedTsMs, sleepAnnotations(deviceId:fromTsMs:toTsMs:), insertSleepAnnotation, moveSleepAnnotation, replaceSleepAnnotation, and deleteSleepAnnotation.

- [ ] **Step 1: Write failing persistence and snapping tests**

~~~swift
func testAnnotationsDeduplicateAndOrderInsideInclusiveWindow() async throws {
    let store = try await WhoopStore.inMemory()
    let fell = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .fellAsleep)
    let awake = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .awakeInBed)
    let arose = SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .arose)
    for row in [arose, awake, fell, awake] { try await store.insertSleepAnnotation(row) }
    XCTAssertEqual(try await store.sleepAnnotations(deviceId: "a", fromTsMs: 60_000, toTsMs: 90_000),
                   [fell, awake, arose])
}

func testMoveAndReplaceCollapseAnExistingTarget() async throws {
    let store = try await WhoopStore.inMemory()
    let old = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
    let target = SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .inBed)
    try await store.insertSleepAnnotation(old); try await store.insertSleepAnnotation(target)
    try await store.moveSleepAnnotation(old, toTsMs: 90_000)
    try await store.replaceSleepAnnotation(target, with: .arose)
    XCTAssertEqual(try await store.sleepAnnotations(deviceId: "a", fromTsMs: 0, toTsMs: 120_000),
                   [SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .arose)])
}

func testSnapUsesNearestThirtySecondEpoch() {
    XCTAssertEqual(WhoopStore.snappedTsMs(44_999), 30_000)
    XCTAssertEqual(WhoopStore.snappedTsMs(45_000), 60_000)
}
~~~

- [ ] **Step 2: Run the tests to verify they fail**

Run: cd Packages/WhoopStore && swift test --filter SleepAnnotationStoreTests

Expected: compilation failure because the annotation types and store methods do not exist.

- [ ] **Step 3: Implement the minimal GRDB table and CRUD**

~~~swift
migrator.registerMigration("v30-sleep-annotations") { db in
    try db.create(table: "sleepAnnotation") { t in
        t.column("deviceId", .text).notNull()
        t.column("tsMs", .integer).notNull()
        t.column("type", .integer).notNull()
        t.primaryKey(["deviceId", "tsMs", "type"])
    }
}
~~~

Use INSERT OR IGNORE; query with tsMs >= ? AND tsMs <= ? ORDER BY tsMs ASC, type ASC. Implement move and type replacement in one syncWrite transaction: delete the old natural key, then insert-ignore the target. Round ties upward with (tsMs + 15_000) / 30_000 * 30_000. Add sleepAnnotation to DeviceRegistryStore.deviceScopedTables.

- [ ] **Step 4: Add migration and device-deletion regression tests**

Assert PRAGMA table_info(sleepAnnotation) columns are deviceId, tsMs, type in that order and primary-key ordinal is 1, 2, 3. Add target/other-device annotation rows to the existing deletion fixture and assert only the target row is removed.

- [ ] **Step 5: Run the focused Swift suite**

Run: cd Packages/WhoopStore && swift test --filter 'SleepAnnotationStoreTests|DeviceRegistryStoreTests|MigrationTests'

Expected: PASS.

- [ ] **Step 6: Commit**

~~~bash
git add Packages/WhoopStore/Sources/WhoopStore/SleepAnnotationStore.swift Packages/WhoopStore/Sources/WhoopStore/Database.swift Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift Packages/WhoopStore/Tests/WhoopStoreTests/SleepAnnotationStoreTests.swift Packages/WhoopStore/Tests/WhoopStoreTests/DeviceRegistryStoreTests.swift
git commit -m "feat: persist sleep graph annotations"
~~~

### Task 2: Mirror the storage contract on Android

**Files:**
- Modify: android/app/src/main/java/com/noop/data/Entities.kt, WhoopDao.kt, WhoopRepository.kt, WhoopDatabase.kt, DeviceRegistryDao.kt, DeviceRegistry.kt
- Create: android/app/src/test/java/com/noop/data/SleepAnnotationMigrationTest.kt
- Create: android/app/src/test/java/com/noop/data/SleepAnnotationStoreTest.kt
- Modify: android/app/src/test/java/com/noop/data/DeviceRegistryTest.kt

**Interfaces:**
- Produces entity SleepAnnotationRow(deviceId: String, tsMs: Long, type: Int) with primary keys deviceId, tsMs, type.
- Produces Room DAO/repository methods with Task 1 names and millisecond semantics.

- [ ] **Step 1: Write failing Android SQL and parity tests**

~~~kotlin
@Test fun migrationSqlMatchesSwiftColumnAndKeyOrder() {
    assertEquals(
        listOf("CREATE TABLE IF NOT EXISTS `sleepAnnotation` (`deviceId` TEXT NOT NULL, " +
            "`tsMs` INTEGER NOT NULL, `type` INTEGER NOT NULL, " +
            "PRIMARY KEY(`deviceId`, `tsMs`, `type`))"),
        WhoopDatabase.SLEEP_ANNOTATION_MIGRATION_SQL,
    )
}
@Test fun snapMatchesSwift() {
    assertEquals(30_000L, SleepAnnotation.snapTsMs(44_999L))
    assertEquals(60_000L, SleepAnnotation.snapTsMs(45_000L))
}
~~~

Add a fake DAO test that records the transaction delete-old then insert-ignore-new operations and verifies a duplicate target leaves one row.

- [ ] **Step 2: Run the test to verify it fails**

Run: cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.data.SleepAnnotation*'

Expected: FAIL because the entity, migration SQL, and snap helper do not exist.

- [ ] **Step 3: Add the exact Room migration and CRUD**

~~~kotlin
internal val SLEEP_ANNOTATION_MIGRATION_SQL = listOf(
    "CREATE TABLE IF NOT EXISTS `sleepAnnotation` (`deviceId` TEXT NOT NULL, " +
        "`tsMs` INTEGER NOT NULL, `type` INTEGER NOT NULL, " +
        "PRIMARY KEY(`deviceId`, `tsMs`, `type`))",
)
internal val MIGRATION_21_22 = object : Migration(21, 22) {
    override fun migrate(db: SupportSQLiteDatabase) {
        for (stmt in SLEEP_ANNOTATION_MIGRATION_SQL) db.execSQL(stmt)
    }
}
~~~

Use Insert IGNORE and SELECT from sleepAnnotation where deviceId and inclusive millisecond bounds match, ordered tsMs ASC then type ASC. Add deleteSleepAnnotationsFor(deviceId) and invoke it in DeviceRegistry.deleteDeviceData.

- [ ] **Step 4: Run the Android data suite**

Run: cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.data.SleepAnnotation*' --tests 'com.noop.data.DeviceRegistryTest'

Expected: PASS, including migration shape, deduplication, replacement, snap, and delete wiring.

- [ ] **Step 5: Commit**

~~~bash
git add android/app/src/main/java/com/noop/data/Entities.kt android/app/src/main/java/com/noop/data/WhoopDao.kt android/app/src/main/java/com/noop/data/WhoopRepository.kt android/app/src/main/java/com/noop/data/WhoopDatabase.kt android/app/src/main/java/com/noop/data/DeviceRegistryDao.kt android/app/src/main/java/com/noop/data/DeviceRegistry.kt android/app/src/test/java/com/noop/data/SleepAnnotationMigrationTest.kt android/app/src/test/java/com/noop/data/SleepAnnotationStoreTest.kt android/app/src/test/java/com/noop/data/DeviceRegistryTest.kt
git commit -m "feat: mirror sleep annotations on android"
~~~

### Task 3: Add Apple timeline pins and editor

**Files:**
- Create: Strand/Data/SleepAnnotationEditorModel.swift
- Modify: Strand/Screens/SleepView.swift, stageTimeline and stageTimelineRow
- Create: StrandTests/SleepAnnotationEditorModelTests.swift

**Interfaces:**
- Consumes Task 1 store interface.
- Produces SleepAnnotationEditorModel.snappedTimestamp(x:width:startTsMs:endTsMs:), clampedX, and stackedLabelLevel(for:in:).
- Produces a SwiftUI SleepAnnotationOverlay accepting annotations, bounds, selection, and add/move/replace/delete closures.

- [ ] **Step 1: Write failing coordinate and non-effect tests**

~~~swift
func testDragTimestampClampsAndSnaps() {
    XCTAssertEqual(SleepAnnotationEditorModel.snappedTimestamp(
        x: 50, width: 100, startTsMs: 0, endTsMs: 120_000), 60_000)
    XCTAssertEqual(SleepAnnotationEditorModel.snappedTimestamp(
        x: -5, width: 100, startTsMs: 0, endTsMs: 120_000), 0)
}

func testEqualTimestampLabelsStackByType() {
    let rows = [
        SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed),
        SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .fellAsleep),
    ]
    XCTAssertEqual(SleepAnnotationEditorModel.stackedLabelLevel(for: rows[0], in: rows), 0)
    XCTAssertEqual(SleepAnnotationEditorModel.stackedLabelLevel(for: rows[1], in: rows), 1)
}
~~~

Also inject a throwing mutation closure and assert the exact prior annotation array is restored. Keep a Stages fixture unchanged before and after add, move, replace, and delete model operations.

- [ ] **Step 2: Run the test to verify it fails**

Run: xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/SleepAnnotationEditorModelTests CODE_SIGNING_ALLOWED=NO test

Expected: FAIL because SleepAnnotationEditorModel does not exist.

- [ ] **Step 3: Implement the Apple data/UI seam**

Load annotations for the current inclusive in-bed window converted to milliseconds. Add + Marker with exact labels In bed, Fell asleep, Awake in bed, Briefly got up, Arose; create at the snapped midpoint. Store an optimistic snapshot for every mutation and restore it on a thrown store error.

Overlay neutral StrandPalette.textTertiary vertical stems over the shared stage-row axis, stack equal-time labels sorted by type, and give every stem an accessible label type plus local time. On selection show a compact editor with the five types, formatted local time, and Delete. Use DragGesture on macOS and long-press followed by drag on iOS; persist one snapped move only when dragging ends. Do not modify Night, Stages, SleepMark, or the stage segments.

- [ ] **Step 4: Run targeted Apple tests**

Run: xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/SleepAnnotationEditorModelTests -only-testing:StrandTests/SleepMarkTests CODE_SIGNING_ALLOWED=NO test

Expected: PASS.

- [ ] **Step 5: Commit**

~~~bash
git add Strand/Data/SleepAnnotationEditorModel.swift Strand/Screens/SleepView.swift StrandTests/SleepAnnotationEditorModelTests.swift
git commit -m "feat: annotate apple sleep timelines"
~~~

### Task 4: Add Compose timeline pins and editor

**Files:**
- Modify: android/app/src/main/java/com/noop/ui/SleepScreen.kt, Hero and StageTimeline
- Create: android/app/src/test/java/com/noop/ui/SleepAnnotationEditorTest.kt

**Interfaces:**
- Consumes Task 2 repository interface.
- Produces sleepAnnotationTimestampForX(xPx: Float, widthPx: Float, startTsMs: Long, endTsMs: Long): Long and sleepAnnotationLabelLevel(row: SleepAnnotationRow, rows: List<SleepAnnotationRow>): Int.

- [ ] **Step 1: Write failing Compose-model tests**

~~~kotlin
@Test fun dragCoordinateClampsAndSnapsLikeSwift() {
    assertEquals(60_000L, sleepAnnotationTimestampForX(50f, 100f, 0L, 120_000L))
    assertEquals(0L, sleepAnnotationTimestampForX(-1f, 100f, 0L, 120_000L))
}
@Test fun equalTimestampLabelsStackByType() {
    val rows = listOf(SleepAnnotationRow("a", 60_000L, 0), SleepAnnotationRow("a", 60_000L, 1))
    assertEquals(0, sleepAnnotationLabelLevel(rows[0], rows))
    assertEquals(1, sleepAnnotationLabelLevel(rows[1], rows))
}
~~~

- [ ] **Step 2: Run the test to verify it fails**

Run: cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.ui.SleepAnnotationEditorTest'

Expected: FAIL because the coordinate helpers do not exist.

- [ ] **Step 3: Implement Compose loading, overlay, and editor**

Fetch annotations for selected windowOnsetTs/windowWakeTs in milliseconds. Render neutral Palette.textTertiary stems in a full-width overlay aligned to StageRowTrack and ClockLabelRow; stack labels by tsMs/type. Use long-press plus horizontal pointerInput drag and persist the snapped position at drag completion.

Add the same five-item + Marker menu to the stage card. Selected pins open a compact Material 3 sheet/dialog with type picker, formatted local time, and Delete. Keep an optimistic list snapshot and restore on failure. Add Compose semantics type plus local time and an edit label. Do not alter stage spans, totals, or analytics.

- [ ] **Step 4: Run Android UI tests and compile**

Run: cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.ui.SleepAnnotationEditorTest' --tests 'com.noop.data.SleepAnnotation*'

Expected: PASS.

Run: cd android && ./gradlew compileFullDebugKotlin

Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

~~~bash
git add android/app/src/main/java/com/noop/ui/SleepScreen.kt android/app/src/test/java/com/noop/ui/SleepAnnotationEditorTest.kt
git commit -m "feat: annotate android sleep timelines"
~~~

### Task 5: Verify the complete feature

**Files:**
- Modify only files that a failing verification command proves require a correction.

- [ ] **Step 1: Run full checks**

Run: cd Packages/WhoopStore && swift test
Expected: PASS.

Run: xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
Expected: BUILD SUCCEEDED.

Run: xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
Expected: BUILD SUCCEEDED.

Run: cd android && ./gradlew testFullDebugUnitTest compileFullDebugKotlin
Expected: BUILD SUCCESSFUL.

- [ ] **Step 2: Inspect scope and hygiene**

Run: git diff --check && git status --short

Expected: no whitespace errors and no generated project, biometric data, .build, Android build, .codex, or workspace/recovery files staged.

Review the diff to verify no SleepStager/StrandAnalytics, existing SleepMark, CSV, Health export, or backup-settings change exists; verify both device-deletion paths contain sleepAnnotation.

- [ ] **Step 3: Commit verified fixes and request review**

~~~bash
git add <only files changed by a verified fix>
git commit -m "fix: verify sleep annotation integration"
~~~

Use superpowers:requesting-code-review after verification is clean. Do not push, install, or overwrite the installed app without a separate user request.

## Self-Review

**Spec coverage:** Tasks 1–2 cover schema, migration, deterministic reads, deduplication, atomic replacement, snapping, backup-by-database behavior, and device deletion. Tasks 3–4 cover all five markers, midpoint creation, neutral stacked pins, selection/edit/delete, platform drag gestures, rollback, accessibility, and UI parity. Task 5 covers required builds and confirms analytics, exports, and SleepMark remain untouched.

**Placeholder scan:** The required scan completed cleanly; every implementation and test step is concrete.

**Type consistency:** Swift uses SleepAnnotationRow(deviceId: String, tsMs: Int64, type: SleepAnnotationType). Kotlin uses the equivalent SleepAnnotationRow(deviceId: String, tsMs: Long, type: Int). Both use inclusive millisecond bounds, 30,000 ms snapping, and deviceId/tsMs/type keys.

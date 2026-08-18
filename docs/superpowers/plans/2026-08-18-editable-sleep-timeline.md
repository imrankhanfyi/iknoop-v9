# Editable Sleep Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag Asleep and Woke chart boundaries, including up to 90 minutes outside detected sleep, and durably re-stage the corrected session.

**Architecture:** A deterministic edit-domain model supplies the 90-minute visual corridor, coordinate conversion, snapping, and ordered pairs. Existing stage data renders in that domain; native overlays maintain only transient drag state and submit the final pair through the existing guarded repository edit path.

**Tech Stack:** Swift/SwiftUI/XCTest; Kotlin/Jetpack Compose/JUnit; XcodeGen; Gradle.

**Spec:** `docs/superpowers/specs/2026-08-18-editable-sleep-timeline-design.md`

## Global Constraints

- The corridor is exactly 90 minutes before Asleep and after Woke, with no fabricated stage data.
- Persist only through existing guarded re-stage methods; snap to 30 seconds and retain an ordered pair.
- Annotations remain descriptive notes and never change sleep, recovery, strain, or analytics.
- macOS and iOS share behavior; Android parity is intentionally deferred at the user's direction because this private live release is macOS/iOS-only.
- Preserve `com.noopapp.noop` / `NOOP` and no `com.apple.security.network.client` entitlement.
- Generate Xcode projects, release-build, and use `ditto` to install; never re-sign.

---

## File Structure

- Create `Strand/Data/SleepTimelineEditDomain.swift`: pure Apple coordinate/snap/order model.
- Create `StrandTests/SleepTimelineEditDomainTests.swift`: XCTest model coverage.
- Modify `Strand/Screens/SleepView.swift`: wider stage domain and native boundary overlay.
- Create `android/app/src/main/java/com/noop/ui/SleepTimelineEditDomain.kt`: Kotlin twin model.
- Create `android/app/src/test/java/com/noop/ui/SleepTimelineEditDomainTest.kt`: JUnit model coverage.
- Modify `android/app/src/main/java/com/noop/ui/SleepScreen.kt`: wider Compose timeline and long-press drag handles.

### Task 1: Apple edit-domain model

**Files:** Create `Strand/Data/SleepTimelineEditDomain.swift`; test `StrandTests/SleepTimelineEditDomainTests.swift`.

**Interfaces:** `SleepTimelineEditDomain(sessionStartTs:sessionEndTs:)` exposes `displayStartTs`, `displayEndTs`, `seconds(forX:width:)`, `x(for:width:)`, and `normalized(start:end:dragging:) -> (start: Int, end: Int)`. `SleepBoundary` has `.asleep` and `.woke`.

- [ ] **Step 1: Write the failing XCTest cases**

```swift
func testDomainAddsExactlyNinetyMinutesOnBothSides() {
    let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)
    XCTAssertEqual(domain.displayStartTs, 4_600)
    XCTAssertEqual(domain.displayEndTs, 25_400)
}
func testWokeNormalizationExtendsBeyondDetectedEndAndSnaps() {
    let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)
    XCTAssertEqual(domain.normalized(start: 10_000, end: 25_399, dragging: .woke), (start: 10_000, end: 25_380))
}
func testAsleepCannotCrossWoke() {
    let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)
    XCTAssertEqual(domain.normalized(start: 25_400, end: 20_000, dragging: .asleep), (start: 19_950, end: 20_000))
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/SleepTimelineEditDomainTests test`

Expected: FAIL because the type does not exist.

- [ ] **Step 3: Implement minimal model**

```swift
enum SleepBoundary { case asleep, woke }
struct SleepTimelineEditDomain: Equatable {
    static let marginSeconds = 90 * 60
    static let snapSeconds = 30
    let sessionStartTs: Int; let sessionEndTs: Int
    var displayStartTs: Int { sessionStartTs - Self.marginSeconds }
    var displayEndTs: Int { sessionEndTs + Self.marginSeconds }
}
```

Implement zero-width-safe conversion, edge clamp, absolute 30-second-grid rounding, and at least one snap interval between boundaries without moving the untouched boundary off-grid.

- [ ] **Step 4: Run focused tests**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/SleepTimelineEditDomainTests -only-testing:StrandTests/SleepAnnotationEditorModelTests test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Strand/Data/SleepTimelineEditDomain.swift StrandTests/SleepTimelineEditDomainTests.swift
git commit -m "feat: add sleep timeline edit domain"
```

### Task 2: Apple chart interaction

**Files:** Modify `Strand/Screens/SleepView.swift:1079-1130` and `Strand/Screens/SleepView.swift:2782-3143`; test `StrandTests/SleepTimelineEditDomainTests.swift`.

**Interfaces:** `SleepSessionBoundaryOverlay(startTs:endTs:domain:onCommit:)` holds drag state and emits one `(Int, Int)` pair on release. It consumes `Repository.editSleepTimes(detectedStartTs:oldEndTs:storedStagesJSON:newStartTs:newEndTs:)` through its caller.

- [ ] **Step 1: Add a failing coordinate test**

```swift
func testDetectedBoundsAreInsetByCorridorMargins() {
    let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)
    XCTAssertEqual(domain.x(for: 10_000, width: 208), 54, accuracy: 0.001)
    XCTAssertEqual(domain.x(for: 20_000, width: 208), 154, accuracy: 0.001)
}
```

- [ ] **Step 2: Run it before implementation**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/SleepTimelineEditDomainTests/testDetectedBoundsAreInsetByCorridorMargins test`

Expected: FAIL until coordinate conversion exists.

- [ ] **Step 3: Render the wider timeline and direct handles**

```swift
let domain = SleepTimelineEditDomain(sessionStartTs: night.session.effectiveStartTs, sessionEndTs: night.session.endTs)
```

Use display bounds for layout origin/span but preserve `intervals`. Draw Asleep/Woke labels and stems over the rows. macOS directly drags; iOS long-presses then drags. On release convert x, normalize, call the existing repository edit with detected key/current JSON, then execute the existing day re-score refresh. Use localized accessibility labels/hints. Do not write annotation storage.

- [ ] **Step 4: Build Apple targets**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: both builds succeed.

- [ ] **Step 5: Commit**

```bash
git add Strand/Screens/SleepView.swift StrandTests/SleepTimelineEditDomainTests.swift
git commit -m "feat: drag sleep timeline boundaries"
```

### Task 3: Kotlin edit-domain twin (deferred by user)

**Files:** Create `android/app/src/main/java/com/noop/ui/SleepTimelineEditDomain.kt`; test `android/app/src/test/java/com/noop/ui/SleepTimelineEditDomainTest.kt`.

**Interfaces:** `SleepTimelineEditDomain(sessionStartTs: Long, sessionEndTs: Long)` exposes `displayStartTs`, `displayEndTs`, `secondsForX`, `xFor`, and `normalized`, returning `Pair<Long, Long>`; `SleepBoundary` uses `Asleep` and `Woke`.

- [ ] **Step 1: Write failing JUnit cases matching Swift**

```kotlin
@Test fun domainAddsExactlyNinetyMinutesOnBothSides() {
    val domain = SleepTimelineEditDomain(10_000, 20_000)
    assertEquals(4_600, domain.displayStartTs)
    assertEquals(25_400, domain.displayEndTs)
}
@Test fun wokeNormalizationExtendsBeyondDetectedEndAndSnaps() {
    val domain = SleepTimelineEditDomain(10_000, 20_000)
    assertEquals(10_000L to 25_380L, domain.normalized(10_000, 25_399, SleepBoundary.Woke))
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.ui.SleepTimelineEditDomainTest'`

Expected: FAIL because the type does not exist.

- [ ] **Step 3: Implement framework-free Kotlin twin**

```kotlin
internal enum class SleepBoundary { Asleep, Woke }
internal data class SleepTimelineEditDomain(val sessionStartTs: Long, val sessionEndTs: Long) {
    companion object { const val marginSeconds = 90 * 60L; const val snapSeconds = 30L }
    val displayStartTs get() = sessionStartTs - marginSeconds
    val displayEndTs get() = sessionEndTs + marginSeconds
}
```

Match Swift's conversion, snap, clamp, and ordering rules without Compose imports.

- [ ] **Step 4: Run test and compiler**

Run: `cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.ui.SleepTimelineEditDomainTest' compileFullDebugKotlin`

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/noop/ui/SleepTimelineEditDomain.kt android/app/src/test/java/com/noop/ui/SleepTimelineEditDomainTest.kt
git commit -m "feat: add android sleep timeline edit domain"
```

### Task 4: Compose drag interaction (deferred by user)

**Files:** Modify `android/app/src/main/java/com/noop/ui/SleepScreen.kt:1517-1655` and `android/app/src/main/java/com/noop/ui/SleepScreen.kt:1879-2115`; test `android/app/src/test/java/com/noop/ui/SleepTimelineEditDomainTest.kt`.

**Interfaces:** `SleepSessionBoundaryHandles(startTs:endTs:domain:onCommit:)` emits a normalized pair once on release and routes it through existing atomic edit confirmation.

- [ ] **Step 1: Add coordinate/ordering tests**

```kotlin
@Test fun detectedBoundsAreInsetByCorridorMargins() {
    val domain = SleepTimelineEditDomain(10_000, 20_000)
    assertEquals(54f, domain.xFor(10_000, 208f), 0.001f)
    assertEquals(154f, domain.xFor(20_000, 208f), 0.001f)
}
@Test fun asleepCannotCrossWoke() {
    val domain = SleepTimelineEditDomain(10_000, 20_000)
    assertEquals(19_950L to 20_000L, domain.normalized(25_400, 20_000, SleepBoundary.Asleep))
}
```

- [ ] **Step 2: Run model tests**

Run: `cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.ui.SleepTimelineEditDomainTest'`

Expected: PASS before pointer wiring.

- [ ] **Step 3: Attach long-press drag handles**

```kotlin
SleepSessionBoundaryHandles(startTs = onsetTs, endTs = wakeTs, domain = domain) { start, end ->
    sleepEditDraft = SleepEditDraft(start, end)
    // invoke existing validated pair-save confirmation
}
```

Thread display bounds into stage spans and labels while retaining recorded segments. Use long-press then horizontal drag and `Palette`, `Metrics`, `NoopType`, with semantics for label/time/instruction. Normalize on release and use the existing atomic edit path. Do not change Room schema or annotation data.

- [ ] **Step 4: Verify Android**

Run: `cd android && ./gradlew testFullDebugUnitTest --tests 'com.noop.ui.SleepTimelineEditDomainTest' compileFullDebugKotlin`

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/noop/ui/SleepScreen.kt android/app/src/test/java/com/noop/ui/SleepTimelineEditDomainTest.kt
git commit -m "feat: drag android sleep timeline boundaries"
```

### Task 5: Release build and install

**Files:** No source changes; modify the approved spec only for a reviewed signature correction.

- [ ] **Step 1: Check production fork invariants**

Run: `rg -n 'PRODUCT_BUNDLE_IDENTIFIER|PRODUCT_NAME|com.apple.security.network.client' project.yml Strand/Resources/Strand.entitlements`

Expected: production identity present; network-client entitlement absent.

- [ ] **Step 2: Generate and compile all app targets**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build && cd android && ./gradlew testFullDebugUnitTest compileFullDebugKotlin`

Expected: every command succeeds.

- [ ] **Step 3: Release build and install without re-signing**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Release CODE_SIGN_IDENTITY="-" build`

Expected: `** BUILD SUCCEEDED **`.

Resolve the product and run `ditto '<Release NOOP.app>' /Applications/NOOP.app`; do not execute `codesign --force`.

- [ ] **Step 4: Verify installed app and commit docs**

Run: `mdls -name kMDItemCFBundleIdentifier /Applications/NOOP.app && codesign -dvv /Applications/NOOP.app && git diff --check && git status --short`

Expected: `com.noopapp.noop`, valid sandboxed signature, no whitespace errors, and intentional changes only.

```bash
git add docs/superpowers/specs/2026-08-18-editable-sleep-timeline-design.md docs/superpowers/plans/2026-08-18-editable-sleep-timeline.md
git commit -m "docs: specify editable sleep timeline"
```

## Self-Review

**Spec coverage:** Tasks 1/3 define the shared corridor math; Tasks 2/4 supply native controls, empty margins, and durable re-staging; Task 5 validates fork safety and live installation. Annotation isolation is explicit in both UI tasks.

**Placeholder scan:** No `TODO`, `TBD`, `implement later`, `fill in`, or undefined follow-up work appears here.

**Type consistency:** Both platforms have matching inputs, bounds, conversion, snap values, and normalized pairs; only case style differs by platform convention.

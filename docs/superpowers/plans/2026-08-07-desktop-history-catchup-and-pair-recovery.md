# Desktop History Catch-up and Pair Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS app promptly drain a current-night motion backlog and automatically, safely retry a missing encrypted WHOOP bond.

**Architecture:** Decisions stay pure and local to the Apple BLE layer. A motion-frontier policy determines bounded post-session catch-up attempts; a secure-pair retry policy determines the next full reconnect for a partial 5/MG link. `BLEManager` gathers state and schedules work while retaining the existing persist-before-ack offload path.

**Tech Stack:** Swift 5, XCTest, CoreBluetooth, SwiftUI, GRDB via `WhoopStore`.

**Execution record (2026-08-07):** Tasks 1–3 shipped in `230ec370`, `4fe11332`, and `bccecf81`.
Focused `HistoryCatchUpPolicyTests` plus `BondLoopHardeningTests` passed (20 tests, 0 failures); the
macOS target compiled and the user-run Release build was installed with `ditto` without re-signing.
Task 4's real-strap checks remain intentionally open: observe an automatic partial-pair retry and a
current-night motion backlog before declaring hardware validation complete.

## Global Constraints

- Do not add network access, telemetry, cloud services, or destructive BLE commands.
- Preserve protocol bytes, safe trim persistence, acknowledgement order, the no-network entitlement, and production identity.
- Require `LiveState.encryptedBond` for historical offload; standard HR alone is not history-capable.
- Compile the macOS app target and hardware-test with a real strap before claiming success.
- Do not change cross-platform stored data, decoding, or analytics values.

---

### Task 1: Add pure history catch-up and secure-pair retry policies

**Files:**

- Modify: `Strand/BLE/BLEManager.swift:280-405`
- Create: `StrandTests/HistoryCatchUpPolicyTests.swift`

**Interfaces:**

- `HistoryCatchUpPolicy.shouldContinue(connected:encryptedBond:gravityFrontierTs:hrFrontierTs:wallNowUnix:trimAdvanced:consecutiveCount:) -> Bool`
- `SecurePairRetryPolicy.nextDelay(partialLink:hasRecentStandardHR:automaticRetryPaused:attemptCount:) -> TimeInterval?`
- `SecurePairRetryPolicy.shouldStopForAuthFailure(insufficientAuth:peerRemovedPairing:bondLoopPaused:) -> Bool`

- [ ] **Step 1: Write failing motion-catch-up tests**

```swift
func testContinuesWhenEncryptedLinkHasMotionMoreThanFiveMinutesBehindHr() {
    XCTAssertTrue(HistoryCatchUpPolicy.shouldContinue(
        connected: true, encryptedBond: true,
        gravityFrontierTs: 1_800_000_000 - 3_600,
        hrFrontierTs: 1_800_000_000, wallNowUnix: 1_800_000_000,
        trimAdvanced: true, consecutiveCount: 0))
}

func testStopsWhenMotionCaughtUpOrTrimFrozen() {
    XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
        connected: true, encryptedBond: true,
        gravityFrontierTs: 1_800_000_000 - 120,
        hrFrontierTs: 1_800_000_000, wallNowUnix: 1_800_000_000,
        trimAdvanced: true, consecutiveCount: 0))
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests test`

Expected: FAIL because `HistoryCatchUpPolicy` does not exist.

- [ ] **Step 3: Write failing secure-pair-retry tests**

```swift
func testPartialLinkUsesBoundedBackoff() {
    XCTAssertEqual(SecurePairRetryPolicy.nextDelay(partialLink: true, hasRecentStandardHR: true,
        automaticRetryPaused: false, attemptCount: 0), 300)
    XCTAssertEqual(SecurePairRetryPolicy.nextDelay(partialLink: true, hasRecentStandardHR: true,
        automaticRetryPaused: false, attemptCount: 1), 900)
    XCTAssertEqual(SecurePairRetryPolicy.nextDelay(partialLink: true, hasRecentStandardHR: true,
        automaticRetryPaused: false, attemptCount: 2), 3600)
}
```

- [ ] **Step 4: Verify the tests fail**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests test`

Expected: FAIL because `SecurePairRetryPolicy` does not exist.

- [ ] **Step 5: Implement the minimal pure policies**

Add the policies beside `BackfillContinuation`. The motion policy requires connected + encrypted, a five-minute gravity lag against the newer of live HR and wall clock, trim progress, and a six-pass cap. It must not consult `strapNewestTs`. The retry policy returns 5 minutes, 15 minutes, then one hour for a partial nearby link and returns nil for a paused/no-HR link or an explicit pairing failure.

- [ ] **Step 6: Verify the policy tests pass**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests test`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Strand/BLE/BLEManager.swift StrandTests/HistoryCatchUpPolicyTests.swift
git commit -m "feat(ble): add history catch-up and pair retry policies"
```

### Task 2: Wire bounded motion catch-up into BLEManager

**Files:**

- Modify: `Strand/Collect/Collector.swift:96-107`
- Modify: `Strand/BLE/BLEManager.swift:617-625, 1665-1920, 3143-3260`
- Modify: `StrandTests/HistoryCatchUpPolicyTests.swift`

**Interfaces:**

- Add `Collector.latestGravitySampleTs() async -> Int?` beside the existing HR frontier read.
- `BLEManager` reads both frontiers after a completed or timed-out offload and consumes `HistoryCatchUpPolicy`.

- [ ] **Step 1: Write the failing stale-range regression test**

```swift
func testContinuesWhenGravityLagsLiveHrDespiteStaleRange() {
    XCTAssertTrue(HistoryCatchUpPolicy.shouldContinue(
        connected: true, encryptedBond: true,
        gravityFrontierTs: 1_800_000_000 - 4_200,
        hrFrontierTs: 1_800_000_000 - 30, wallNowUnix: 1_800_000_000,
        trimAdvanced: true, consecutiveCount: 0))
}
```

- [ ] **Step 2: Verify it fails, then add the collector read**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests test`

Expected: FAIL until the new policy and collector frontier are wired.

- [ ] **Step 3: Schedule safe catch-up retries**

Add a cancellable short-delay catch-up work item and per-connection counter. After completion or timeout, read gravity and HR, evaluate the pure policy, and call existing `requestSync(.autoContinue)` only when it allows. Cancel and reset the work item/counter on disconnect. Preserve the current stale-range continuation as a separate path and never reissue an offload synchronously from a timeout callback.

- [ ] **Step 4: Add cap and disconnect tests; verify green**

```swift
func testMotionCatchUpStopsAtCap() {
    XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
        connected: true, encryptedBond: true,
        gravityFrontierTs: 1_800_000_000 - 3_600,
        hrFrontierTs: 1_800_000_000, wallNowUnix: 1_800_000_000,
        trimAdvanced: true, consecutiveCount: 6))
}

func testMotionCatchUpStopsWhenDisconnected() {
    XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
        connected: false, encryptedBond: true,
        gravityFrontierTs: 1_800_000_000 - 3_600,
        hrFrontierTs: 1_800_000_000, wallNowUnix: 1_800_000_000,
        trimAdvanced: true, consecutiveCount: 0))
}
```

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Strand/Collect/Collector.swift Strand/BLE/BLEManager.swift StrandTests/HistoryCatchUpPolicyTests.swift
git commit -m "fix(ble): continue current-night motion catch-up"
```

### Task 3: Wire automatic secure-pair retry and honest sync gating

**Files:**

- Modify: `Strand/BLE/BLEManager.swift:500-760, 975-1090, 3143-3365, 3501-3715`
- Modify: `Strand/Screens/HealthView.swift:132-204`
- Modify: `StrandTests/HistoryCatchUpPolicyTests.swift`

**Interfaces:**

- `BLEManager` owns a cancellable secure-pair retry work item and retry count.
- Add `BLEManager.canStartHistorySync(connected:encryptedBond:backfilling:) -> Bool` for engine/UI parity.

- [ ] **Step 1: Write failing full-bond-gating tests**

```swift
func testHistorySyncRequiresEncryptedBond() {
    XCTAssertFalse(BLEManager.canStartHistorySync(connected: true, encryptedBond: false, backfilling: false))
    XCTAssertTrue(BLEManager.canStartHistorySync(connected: true, encryptedBond: true, backfilling: false))
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests test`

Expected: FAIL because `canStartHistorySync` does not exist.

- [ ] **Step 3: Implement secure-pair retry**

When standard HR establishes a 5/MG partial link, arm one retry from `SecurePairRetryPolicy`. On firing, cancel NOOP’s peripheral session and reconnect only from `didDisconnectPeripheral`; do not use scan-only retry. Cancel/reset it on genuine bond, explicit user disconnect, bond-loop pause, insufficient-authentication failure, peer-removed-pairing failure, and deinit. Retain the existing give-up behavior.

- [ ] **Step 4: Gate history sync and make diagnostics honest**

Use `canStartHistorySync` in `requestSync` and `syncNow`; make `HealthView.canSync` require `live.encryptedBond`. Log only partial detection, retry schedule/fire/cancel, and genuine-bond reset; never log IDs, pairing material, or raw biometrics.

- [ ] **Step 5: Verify focused tests pass**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests -only-testing:StrandTests/BondLoopHardeningTests test`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Strand/BLE/BLEManager.swift Strand/Screens/HealthView.swift StrandTests/HistoryCatchUpPolicyTests.swift
git commit -m "fix(ble): retry partial secure pairing safely"
```

### Task 4: Verify app target and hardware behavior

**Files:**

- Modify: `workspace/state.md` only if verification adds durable project knowledge.

- [ ] **Step 1: Run the Strand test target**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test`

Expected: PASS.

- [ ] **Step 2: Compile the macOS app target**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Hardware verification**

Verify a partial link gets one bounded full reconnect per backoff interval and stops on ownership/stale-pair errors. Verify a current-night motion backlog advances across catch-up attempts until gravity is within five minutes of HR/current time or the explicit six-pass safety budget is reached. Verify standard-HR-only partial links never begin historical offload.

- [ ] **Step 4: Record durable findings if needed and commit**

```bash
git add workspace/state.md
git commit -m "docs: record BLE catch-up verification"
```

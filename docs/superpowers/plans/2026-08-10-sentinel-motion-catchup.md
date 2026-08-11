# Sentinel Motion Catch-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a WHOOP 4.0 historical offload make up to three immediate motion catch-up requests when the strap returns the no-cursor sentinel but has durably persisted motion rows.

**Architecture:** The existing `HistoryCatchUpPolicy` stays pure. It accepts one additional, session-local fallback progress fact: motion rows persisted while the cursor was the `0xFFFFFFFF` sentinel. The `BLEManager` supplies that fact from the existing `Backfiller` session tally and retains all encrypted-bond, disconnect, and no-progress stops.

**Tech Stack:** Swift, XCTest, CoreBluetooth scheduler integration; no protocol or outbound-command changes.

## Global Constraints

- Preserve the existing CRC, handshake, encrypted-bond, and no-progress safety gates.
- Do not add or alter any outbound BLE command payload.
- Apply the fallback only to the no-cursor sentinel and cap it at three immediate retries.
- Verify focused XCTest coverage before real WHOOP 4.0 observation.

---

### Task 1: Pin sentinel fallback policy

**Files:**
- Modify: `StrandTests/HistoryCatchUpPolicyTests.swift`
- Modify: `Strand/BLE/BLEManager.swift`

**Interfaces:**
- Produces: `HistoryCatchUpPolicy.shouldContinue(..., sentinelMotionProgress: Bool, consecutiveCount: Int)`.

- [ ] **Step 1: Write failing tests**

```swift
XCTAssertTrue(HistoryCatchUpPolicy.shouldContinue(
    connected: true, encryptedBond: true,
    gravityFrontierTs: wallNow - 3_600, hrFrontierTs: wallNow,
    wallNowUnix: wallNow, trimAdvanced: false,
    sentinelMotionProgress: true, consecutiveCount: 0))
XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
    connected: true, encryptedBond: true,
    gravityFrontierTs: wallNow - 3_600, hrFrontierTs: wallNow,
    wallNowUnix: wallNow, trimAdvanced: false,
    sentinelMotionProgress: true, consecutiveCount: 3))
```

- [ ] **Step 2: Verify the tests fail**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/HistoryCatchUpPolicyTests test`

Expected: compile failure because `sentinelMotionProgress` does not yet exist.

- [ ] **Step 3: Implement the pure predicate and wiring**

Use `trimAdvanced || sentinelMotionProgress` only after proving the cursor is `0xFFFFFFFF`; pass the existing `Backfiller.sessionMotionRows > 0` tally on exit. Use a three-pass cap for this fallback, without weakening normal cursor-based catch-up.

- [ ] **Step 4: Verify the focused tests pass**

Run the command from Step 2 and confirm all policy tests pass.

- [ ] **Step 5: Real-strap validation**

Observe a sentinel-cursor morning: the strap log must show no more than three fallback follow-ups, each preceded by persisted motion rows; it must stop after an empty/no-motion session and must preserve normal connection behavior.

import XCTest
@testable import Strand

/// Pins the pure, bounded decisions used by later BLE scheduling work. These policies deliberately
/// depend only on facts supplied by their callers, keeping the safety-critical branches testable without
/// CoreBluetooth or a strap.
final class HistoryCatchUpPolicyTests: XCTestCase {
    private let wallNow = 1_800_000_000

    /// A partial standard-HR link must never start historical sync; only a genuine encrypted bond can.
    func testHistorySyncRequiresEncryptedBond() {
        XCTAssertFalse(BLEManager.canStartHistorySync(
            connected: true, encryptedBond: false, backfilling: false))
        XCTAssertTrue(BLEManager.canStartHistorySync(
            connected: true, encryptedBond: true, backfilling: false))
    }

    /// A gravity frontier more than five minutes behind the newer HR/wall-clock frontier needs another
    /// catch-up pass, but only across an encrypted live link that is still progressing.
    func testContinuesWhenEncryptedLinkHasMotionMoreThanFiveMinutesBehindHr() {
        XCTAssertTrue(HistoryCatchUpPolicy.shouldContinue(
            connected: true,
            encryptedBond: true,
            gravityFrontierTs: wallNow - 3_600,
            hrFrontierTs: wallNow,
            wallNowUnix: wallNow,
            trimAdvanced: true,
            consecutiveCount: 0))
    }

    /// A stale strap-reported range must not stop current-night motion catch-up when persisted live HR
    /// proves the gravity frontier is still behind.
    func testContinuesWhenGravityLagsLiveHrDespiteStaleRange() {
        XCTAssertTrue(HistoryCatchUpPolicy.shouldContinue(
            connected: true, encryptedBond: true,
            gravityFrontierTs: 1_800_000_000 - 4_200,
            hrFrontierTs: 1_800_000_000 - 30, wallNowUnix: 1_800_000_000,
            trimAdvanced: true, consecutiveCount: 0))
    }

    /// A legacy continuation can consume an otherwise productive offload before the motion check gets
    /// a turn. Its empty tail must not discard the pending current-night catch-up request.
    func testKeepsPendingMotionCatchUpAcrossNonAdvancingLegacyTail() {
        XCTAssertTrue(HistoryCatchUpPolicy.nextPendingIntent(
            existingIntent: true, exitedSessionAdvancedTrim: false))
        XCTAssertTrue(HistoryCatchUpPolicy.nextPendingIntent(
            existingIntent: false, exitedSessionAdvancedTrim: true))
        XCTAssertFalse(HistoryCatchUpPolicy.nextPendingIntent(
            existingIntent: false, exitedSessionAdvancedTrim: false))
    }

    /// A gravity gap at or below five minutes is caught up; a frozen trim must also halt a larger gap.
    func testStopsWhenMotionCaughtUpOrTrimFrozen() {
        XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
            connected: true,
            encryptedBond: true,
            gravityFrontierTs: wallNow - 120,
            hrFrontierTs: wallNow,
            wallNowUnix: wallNow,
            trimAdvanced: true,
            consecutiveCount: 0))
        XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
            connected: true,
            encryptedBond: true,
            gravityFrontierTs: wallNow - 3_600,
            hrFrontierTs: wallNow,
            wallNowUnix: wallNow,
            trimAdvanced: false,
            consecutiveCount: 0))
    }

    /// The catch-up path cannot run on a disconnected or unencrypted link and cannot exceed six passes.
    func testRequiresEncryptedConnectionAndStopsAtSixPassCap() {
        XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
            connected: false, encryptedBond: true, gravityFrontierTs: wallNow - 3_600,
            hrFrontierTs: wallNow, wallNowUnix: wallNow, trimAdvanced: true, consecutiveCount: 0))
        XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
            connected: true, encryptedBond: false, gravityFrontierTs: wallNow - 3_600,
            hrFrontierTs: wallNow, wallNowUnix: wallNow, trimAdvanced: true, consecutiveCount: 0))
        XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
            connected: true, encryptedBond: true, gravityFrontierTs: wallNow - 3_600,
            hrFrontierTs: wallNow, wallNowUnix: wallNow, trimAdvanced: true, consecutiveCount: 6))
    }

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

    /// WHOOP 4 can acknowledge a productive offload with the no-cursor sentinel repeatedly. In that
    /// narrow case, persisted motion rows are a bounded fallback progress signal; an empty retry stops.
    func testSentinelMotionProgressGetsThreeBoundedCatchUpsWithoutTrimAdvance() {
        XCTAssertTrue(HistoryCatchUpPolicy.shouldContinue(
            connected: true, encryptedBond: true,
            gravityFrontierTs: wallNow - 3_600, hrFrontierTs: wallNow,
            wallNowUnix: wallNow, trimAdvanced: false,
            sentinelMotionProgress: true, consecutiveCount: 0))
        XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
            connected: true, encryptedBond: true,
            gravityFrontierTs: wallNow - 3_600, hrFrontierTs: wallNow,
            wallNowUnix: wallNow, trimAdvanced: false,
            sentinelMotionProgress: false, consecutiveCount: 0))
        XCTAssertFalse(HistoryCatchUpPolicy.shouldContinue(
            connected: true, encryptedBond: true,
            gravityFrontierTs: wallNow - 3_600, hrFrontierTs: wallNow,
            wallNowUnix: wallNow, trimAdvanced: false,
            sentinelMotionProgress: true, consecutiveCount: 3))
    }

    /// When no live-HR frontier is available, wall time remains the newer reference frontier.
    func testUsesWallClockWhenItIsNewerThanHr() {
        XCTAssertTrue(HistoryCatchUpPolicy.shouldContinue(
            connected: true, encryptedBond: true, gravityFrontierTs: wallNow - 301,
            hrFrontierTs: wallNow - 3_600, wallNowUnix: wallNow, trimAdvanced: true, consecutiveCount: 0))
    }

    /// A nearby partial link gets a bounded retry cadence: five minutes, fifteen minutes, then hourly.
    func testPartialLinkUsesBoundedBackoff() {
        XCTAssertEqual(SecurePairRetryPolicy.nextDelay(
            partialLink: true, hasRecentStandardHR: true, automaticRetryPaused: false, attemptCount: 0), 300)
        XCTAssertEqual(SecurePairRetryPolicy.nextDelay(
            partialLink: true, hasRecentStandardHR: true, automaticRetryPaused: false, attemptCount: 1), 900)
        XCTAssertEqual(SecurePairRetryPolicy.nextDelay(
            partialLink: true, hasRecentStandardHR: true, automaticRetryPaused: false, attemptCount: 2), 3_600)
        XCTAssertEqual(SecurePairRetryPolicy.nextDelay(
            partialLink: true, hasRecentStandardHR: true, automaticRetryPaused: false, attemptCount: 99), 3_600)
    }

    /// No automatic retry is allowed without a partial nearby link and recent standard HR, or after pause.
    func testRetryRequiresEligibleUnpausedPartialLink() {
        XCTAssertNil(SecurePairRetryPolicy.nextDelay(
            partialLink: false, hasRecentStandardHR: true, automaticRetryPaused: false, attemptCount: 0))
        XCTAssertNil(SecurePairRetryPolicy.nextDelay(
            partialLink: true, hasRecentStandardHR: false, automaticRetryPaused: false, attemptCount: 0))
        XCTAssertNil(SecurePairRetryPolicy.nextDelay(
            partialLink: true, hasRecentStandardHR: true, automaticRetryPaused: true, attemptCount: 0))
    }

    /// Explicit pairing failures and a loop pause stop automatic retry; an otherwise clean partial link does not.
    func testStopsForExplicitAuthFailuresOrBondLoopPause() {
        XCTAssertTrue(SecurePairRetryPolicy.shouldStopForAuthFailure(
            insufficientAuth: true, peerRemovedPairing: false, bondLoopPaused: false))
        XCTAssertTrue(SecurePairRetryPolicy.shouldStopForAuthFailure(
            insufficientAuth: false, peerRemovedPairing: true, bondLoopPaused: false))
        XCTAssertTrue(SecurePairRetryPolicy.shouldStopForAuthFailure(
            insufficientAuth: false, peerRemovedPairing: false, bondLoopPaused: true))
        XCTAssertFalse(SecurePairRetryPolicy.shouldStopForAuthFailure(
            insufficientAuth: false, peerRemovedPairing: false, bondLoopPaused: false))
    }
}

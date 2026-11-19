import XCTest
@testable import Strand

/// Pins the WHOOP 4 bond watchdog's pure decisions and the Sync card's status resolution.
final class BondWatchdogAndSyncStatusTests: XCTestCase {

    // MARK: - Bond watchdog

    /// 30s first (long enough to answer a macOS pairing prompt), doubling, capped at 5 min.
    func testBondWatchdogFuseBacksOffAndCaps() {
        XCTAssertEqual((0...7).map { BLEManager.bondWatchdogFuseSeconds(consecutiveBounces: $0) },
                       [30, 60, 120, 240, 300, 300, 300, 300])
        XCTAssertEqual(BLEManager.bondWatchdogFuseSeconds(consecutiveBounces: -1), 30)
        XCTAssertEqual(BLEManager.bondWatchdogFuseSeconds(consecutiveBounces: Int.max), 300)
    }

    /// Only a live, still-unbonded link is bounced, and never while auto-reconnect is deliberately paused.
    func testBondWatchdogBouncesOnlyAStuckLiveLink() {
        XCTAssertTrue(BLEManager.bondWatchdogShouldBounce(connected: true, didBond: false, reconnectPaused: false))
        XCTAssertFalse(BLEManager.bondWatchdogShouldBounce(connected: true, didBond: true, reconnectPaused: false))
        XCTAssertFalse(BLEManager.bondWatchdogShouldBounce(connected: false, didBond: false, reconnectPaused: false))
        XCTAssertFalse(BLEManager.bondWatchdogShouldBounce(connected: true, didBond: false, reconnectPaused: true))
    }

    // MARK: - Sync card status

    private let now: TimeInterval = 1_800_000_000

    private func resolve(backfilling: Bool = false, connected: Bool = true, bonded: Bool = true,
                         last: TimeInterval?) -> SyncStatusPill {
        SyncStatusPill.resolve(backfilling: backfilling, connected: connected, encryptedBond: bonded,
                               lastSyncedAt: last, now: now)
    }

    /// The 2026-11-19 screen: connected, stuck pairing, last full drain 8 days earlier. It must say
    /// "Pairing…", not a green "History synced".
    func testPairingOutranksAnOldSyncStamp() {
        XCTAssertEqual(resolve(bonded: false, last: now - 8 * 86_400), .pairing)
        XCTAssertEqual(resolve(bonded: false, last: nil), .pairing)
    }

    func testRecentDrainIsHistorySynced() {
        XCTAssertEqual(resolve(last: now - 600), .synced(now - 600))
        XCTAssertEqual(resolve(last: now - SyncStatusPill.freshSeconds), .synced(now - SyncStatusPill.freshSeconds))
    }

    /// Bonded and idle, but the strap has not been fully drained for days: a neutral fact, not "synced".
    func testOldDrainIsLastFullSync() {
        XCTAssertEqual(resolve(last: now - 8 * 86_400), .lastFullSync(now - 8 * 86_400))
        XCTAssertEqual(resolve(last: now - SyncStatusPill.freshSeconds - 1),
                       .lastFullSync(now - SyncStatusPill.freshSeconds - 1))
    }

    func testOtherStatesKeepTheirPrecedence() {
        XCTAssertEqual(resolve(backfilling: true, bonded: false, last: now - 8 * 86_400), .syncing)
        XCTAssertEqual(resolve(connected: false, bonded: false, last: now - 600), .noStrap)
        XCTAssertEqual(resolve(last: nil), .readyToSync)
    }
}

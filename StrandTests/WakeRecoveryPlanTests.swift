import XCTest
@testable import Strand

final class WakeRecoveryPlanTests: XCTestCase {
    typealias Plan = BLEManager.WakeRecoveryPlan

    private func plan(_ c: Bool, _ b: Bool, _ bf: Bool, _ s: Double?) -> Plan {
        BLEManager.wakeRecoveryPlan(connected: c, encryptedBond: b, backfilling: bf, secondsSinceLastBackfillFrame: s)
    }

    func testDisconnectedIsEmpty() {
        XCTAssertEqual(plan(false, true, true, 500), Plan())
        XCTAssertEqual(plan(false, false, false, nil), Plan())
    }

    func testConnectedUnbondedBouncesOnly() {
        XCTAssertEqual(plan(true, false, false, nil), Plan(bounceUnbondedLink: true))
        XCTAssertEqual(plan(true, false, true, 500), Plan(bounceUnbondedLink: true))
    }

    func testStaleBackfillEndsAndKicks() {
        XCTAssertEqual(plan(true, true, true, 61), Plan(endStaleBackfill: true, kickSync: true))
        XCTAssertEqual(plan(true, true, true, nil), Plan(endStaleBackfill: true, kickSync: true))
    }

    func testHealthyBackfillIsEmpty() {
        XCTAssertEqual(plan(true, true, true, 60), Plan())
        XCTAssertEqual(plan(true, true, true, 5), Plan())
    }

    func testIdleBondedKicks() {
        XCTAssertEqual(plan(true, true, false, nil), Plan(kickSync: true))
        XCTAssertEqual(plan(true, true, false, 1000), Plan(kickSync: true))
    }
}

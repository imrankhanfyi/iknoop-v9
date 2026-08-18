import XCTest
@testable import Strand

final class SleepTimelineEditDomainTests: XCTestCase {
    func testDetectedDomainRemainsStableAfterBothMarkersAreCorrected() {
        let detected = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)
        let corrected = SleepTimelineEditDomain(detectedStartTs: 10_000, detectedEndTs: 20_000,
                                                adjustedStartTs: 7_300, adjustedEndTs: 24_200)

        XCTAssertEqual(corrected, detected)
    }

    func testBoundaryCommitChangesOnlyTheHandleThatWasDragged() {
        let asleep = SleepBoundaryCommit.window(changing: .asleep, to: 9_000,
                                                startTs: 10_000, endTs: 20_000)
        let woke = SleepBoundaryCommit.window(changing: .woke, to: 21_000,
                                              startTs: 10_000, endTs: 20_000)

        XCTAssertEqual(asleep.startTs, 9_000)
        XCTAssertEqual(asleep.endTs, 20_000)
        XCTAssertEqual(woke.startTs, 10_000)
        XCTAssertEqual(woke.endTs, 21_000)
    }

    func testHourTicksUseWholeClockHoursWithinTheFixedDisplayRange() {
        XCTAssertEqual(SleepTimelineEditDomain.hourTicks(from: 10_050, through: 22_000),
                       [10_800, 14_400, 18_000, 21_600])
    }

    func testDomainAddsExactlyNinetyMinutesOnBothSides() {
        let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)

        XCTAssertEqual(domain.displayStartTs, 4_600)
        XCTAssertEqual(domain.displayEndTs, 25_400)
    }

    func testWokeNormalizationExtendsBeyondDetectedEndAndSnaps() {
        let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)

        XCTAssertEqual(domain.normalized(start: 10_000, end: 25_399, dragging: .woke).start, 10_000)
        XCTAssertEqual(domain.normalized(start: 10_000, end: 25_399, dragging: .woke).end, 25_380)
    }

    func testAsleepCannotCrossWokeAndRemainsOnThirtySecondGrid() {
        let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)

        let result = domain.normalized(start: 25_400, end: 20_000, dragging: .asleep)
        XCTAssertEqual(result.start, 19_950)
        XCTAssertEqual(result.end, 20_000)
        XCTAssertEqual(result.start % SleepTimelineEditDomain.snapSeconds, 0)
    }

    func testDetectedBoundsAreInsetByCorridorMargins() {
        let domain = SleepTimelineEditDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)

        XCTAssertEqual(domain.x(for: 10_000, width: 208), 54, accuracy: 0.001)
        XCTAssertEqual(domain.x(for: 20_000, width: 208), 154, accuracy: 0.001)
    }

    func testDisplayWindowRemainsFixedWhenThisNightsBoundariesChange() {
        var cache = SleepTimelineDisplayDomainCache()
        let first = cache.domain(for: 10_000, sessionStartTs: 10_000, sessionEndTs: 20_000)
        let afterAsleepCorrection = cache.domain(for: 10_000, sessionStartTs: 7_300, sessionEndTs: 20_000)
        let afterWakeCorrection = cache.domain(for: 10_000, sessionStartTs: 7_300, sessionEndTs: 24_200)

        XCTAssertEqual(afterAsleepCorrection, first)
        XCTAssertEqual(afterWakeCorrection, first)
    }

    func testHeartRateDomainUsesObservedSleepWindowWithoutEditingMargins() {
        let domain = SleepObservedTimelineDomain(sessionStartTs: 10_000, sessionEndTs: 20_000)

        XCTAssertEqual(domain.originSeconds, 0)
        XCTAssertEqual(domain.spanSeconds, 10_000)
    }
}

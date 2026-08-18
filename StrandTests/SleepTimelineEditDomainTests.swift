import XCTest
@testable import Strand

final class SleepTimelineEditDomainTests: XCTestCase {
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
}

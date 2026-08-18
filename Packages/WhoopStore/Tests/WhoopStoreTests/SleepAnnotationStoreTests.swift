import XCTest
@testable import WhoopStore

final class SleepAnnotationStoreTests: XCTestCase {
    // Catches a missing composite key, non-inclusive query, or ordering that ignores annotation type.
    func testAnnotationsDeduplicateAndOrderInsideInclusiveWindow() async throws {
        let store = try await WhoopStore.inMemory()
        let fell = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .fellAsleep)
        let awake = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .awakeInBed)
        let arose = SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .arose)
        for row in [arose, awake, fell, awake] { try await store.insertSleepAnnotation(row) }

        let annotations = try await store.sleepAnnotations(deviceId: "a", fromTsMs: 60_000, toTsMs: 90_000)
        XCTAssertEqual(annotations, [fell, awake, arose])
    }

    // Catches move/replace operations that retain the old natural key or overwrite an existing target.
    func testMoveAndReplaceCollapseAnExistingTarget() async throws {
        let store = try await WhoopStore.inMemory()
        let old = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let target = SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .inBed)
        try await store.insertSleepAnnotation(old)
        try await store.insertSleepAnnotation(target)

        try await store.moveSleepAnnotation(old, toTsMs: 90_000)
        try await store.replaceSleepAnnotation(target, with: .arose)

        let annotations = try await store.sleepAnnotations(deviceId: "a", fromTsMs: 0, toTsMs: 120_000)
        XCTAssertEqual(annotations, [SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .arose)])
    }

    // Catches the half-epoch tie rule rounding down instead of upward.
    func testSnapUsesNearestThirtySecondEpoch() {
        XCTAssertEqual(WhoopStore.snappedTsMs(44_999), 30_000)
        XCTAssertEqual(WhoopStore.snappedTsMs(45_000), 60_000)
    }
}

import XCTest
import StrandDesign
import WhoopStore
@testable import Strand

@MainActor
final class SleepAnnotationEditorModelTests: XCTestCase {
    func testTimelineDomainUsesEntireInclusiveInBedWindow() {
        let domain = SleepAnnotationTimelineDomain(startTsMs: 1_000_000, endTsMs: 1_600_000)

        XCTAssertEqual(domain.bounds, 1_000_000...1_600_000)
        XCTAssertEqual(domain.originSeconds, 0)
        XCTAssertEqual(domain.spanSeconds, 600)
        XCTAssertEqual(domain.startDate, Date(timeIntervalSince1970: 1_000))
    }

    func testDragTimestampClampsAndSnaps() {
        XCTAssertEqual(SleepAnnotationEditorModel.snappedTimestamp(
            x: 50, width: 100, startTsMs: 0, endTsMs: 120_000), 60_000)
        XCTAssertEqual(SleepAnnotationEditorModel.snappedTimestamp(
            x: -5, width: 100, startTsMs: 0, endTsMs: 120_000), 0)
        XCTAssertEqual(SleepAnnotationEditorModel.snappedTimestamp(
            x: 105, width: 100, startTsMs: 0, endTsMs: 120_000), 120_000)
        XCTAssertEqual(SleepAnnotationEditorModel.clampedX(-5, width: 100), 0)
        XCTAssertEqual(SleepAnnotationEditorModel.clampedX(105, width: 100), 100)
    }

    func testEqualTimestampLabelsStackByType() {
        let rows = [
            SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed),
            SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .fellAsleep),
        ]
        XCTAssertEqual(SleepAnnotationEditorModel.stackedLabelLevel(for: rows[0], in: rows), 0)
        XCTAssertEqual(SleepAnnotationEditorModel.stackedLabelLevel(for: rows[1], in: rows), 1)
        XCTAssertNotEqual(rows[0].naturalKey, rows[1].naturalKey)
    }

    func testFailedLoadClearsPriorWindowAndRejectsItsMutations() async {
        let prior = SleepAnnotationRow(deviceId: "old", tsMs: 60_000, type: .inBed)
        let model = SleepAnnotationEditorModel(annotations: [prior])
        model.selected = prior

        await model.load(deviceId: "new", fromTsMs: 120_000, toTsMs: 240_000) { _, _, _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, [])
        XCTAssertNil(model.selected)

        var staleMutationRan = false
        await model.move(prior, toTsMs: 150_000) { _, _ in
            staleMutationRan = true
        }
        XCTAssertFalse(staleMutationRan)
        XCTAssertEqual(model.annotations, [])
    }

    func testSameDeviceRowFromOverlappingPreviousWindowCannotMutateCurrentWindow() async {
        let stale = SleepAnnotationRow(deviceId: "a", tsMs: 180_000, type: .inBed)
        let current = SleepAnnotationRow(deviceId: "a", tsMs: 210_000, type: .arose)
        let model = SleepAnnotationEditorModel()
        await model.load(deviceId: "a", fromTsMs: 0, toTsMs: 200_000) { _, _, _ in [stale] }
        await model.load(deviceId: "a", fromTsMs: 120_000, toTsMs: 300_000) { _, _, _ in [current] }

        var staleMutationRan = false
        await model.move(stale, toTsMs: 240_000) { _, _ in
            staleMutationRan = true
        }

        XCTAssertFalse(staleMutationRan)
        XCTAssertEqual(model.annotations, [current])
        XCTAssertNil(model.selected)
    }

    func testSlowerPriorWindowLoadCannotReplaceNewerWindow() async {
        let oldRow = SleepAnnotationRow(deviceId: "old", tsMs: 60_000, type: .inBed)
        let newRow = SleepAnnotationRow(deviceId: "new", tsMs: 180_000, type: .arose)
        let gate = AnnotationLoadGate()
        let oldLoadStarted = expectation(description: "old load started")
        let model = SleepAnnotationEditorModel()

        let oldLoad = Task { @MainActor in
            await model.load(deviceId: "old", fromTsMs: 0, toTsMs: 120_000) { _, _, _ in
                oldLoadStarted.fulfill()
                return await gate.wait()
            }
        }
        await fulfillment(of: [oldLoadStarted], timeout: 1)

        await model.load(deviceId: "new", fromTsMs: 120_000, toTsMs: 240_000) { _, _, _ in
            [newRow]
        }
        await gate.resume(returning: [oldRow])
        await oldLoad.value

        XCTAssertEqual(model.annotations, [newRow])
    }

    func testOverlappingMutationsSerializeSoEarlierFailureCannotEraseLaterSuccess() async {
        let prior = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let later = SleepAnnotationRow(deviceId: "a", tsMs: 120_000, type: .arose)
        let model = await loadedModel([prior], selected: prior)
        let gate = AnnotationMutationGate()
        let firstStarted = expectation(description: "first mutation started")
        let secondStartedTooSoon = expectation(description: "second mutation remained queued")
        secondStartedTooSoon.isInverted = true

        let first = Task { @MainActor in
            await model.add(deviceId: "a", type: .fellAsleep, tsMs: 90_000) { _ in
                firstStarted.fulfill()
                await gate.wait()
                throw MutationError.rejected
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let second = Task { @MainActor in
            await model.add(deviceId: "a", type: .arose, tsMs: 120_000) { _ in
                secondStartedTooSoon.fulfill()
            }
        }
        await fulfillment(of: [secondStartedTooSoon], timeout: 0.05)
        await gate.resume()
        await first.value
        await second.value

        XCTAssertEqual(model.annotations, [prior, later])
        XCTAssertEqual(model.selected, later)
    }

    func testProductionStageTimelineLayoutIsInvariantAcrossSuccessfulAnnotationMutations() async {
        let initial = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let model = await loadedModel([initial], selected: initial)
        let intervals = stageIntervalInput()
        let expected = StageTimelineOutput(
            intervals: [
                StageOutput(stage: .light, start: 0, end: 120),
                StageOutput(stage: .deep, start: 120, end: 300),
            ],
            originSeconds: 0,
            spanSeconds: 300
        )
        XCTAssertEqual(productionStageTimelineOutput(using: model, intervals: intervals), expected)

        let added = SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .fellAsleep)
        await model.add(deviceId: "a", type: .fellAsleep, tsMs: 90_000) { _ in }
        XCTAssertEqual(model.annotations, [initial, added])
        XCTAssertEqual(model.selected, added)
        XCTAssertEqual(productionStageTimelineOutput(using: model, intervals: intervals), expected)

        let moved = SleepAnnotationRow(deviceId: "a", tsMs: 120_000, type: .fellAsleep)
        await model.move(added, toTsMs: 120_000) { _, _ in }
        XCTAssertEqual(model.annotations, [initial, moved])
        XCTAssertEqual(model.selected, moved)
        XCTAssertEqual(productionStageTimelineOutput(using: model, intervals: intervals), expected)

        let replaced = SleepAnnotationRow(deviceId: "a", tsMs: 120_000, type: .awakeInBed)
        await model.replace(moved, with: .awakeInBed) { _, _ in }
        XCTAssertEqual(model.annotations, [initial, replaced])
        XCTAssertEqual(model.selected, replaced)
        XCTAssertEqual(productionStageTimelineOutput(using: model, intervals: intervals), expected)

        await model.delete(replaced) { _ in }
        XCTAssertEqual(model.annotations, [initial])
        XCTAssertNil(model.selected)
        XCTAssertEqual(productionStageTimelineOutput(using: model, intervals: intervals), expected)
    }

    func testFailedAddRestoresExactPriorAnnotationsAndSelection() async {
        let prior = [SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)]
        let model = await loadedModel(prior, selected: prior[0])

        await model.add(deviceId: "a", type: .arose, tsMs: 90_000) { _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(model.selected, prior[0])
    }

    func testFailedMoveRestoresExactPriorAnnotationsAndSelection() async {
        let row = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let prior = [row, SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .arose)]
        let model = await loadedModel(prior, selected: row)

        await model.move(row, toTsMs: 120_000) { _, _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(model.selected, row)
    }

    func testFailedReplaceRestoresExactPriorAnnotationsAndSelection() async {
        let row = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let prior = [row]
        let model = await loadedModel(prior, selected: row)

        await model.replace(row, with: .fellAsleep) { _, _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(model.selected, row)
    }

    func testFailedDeleteRestoresExactPriorAnnotationsAndSelection() async {
        let row = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let prior = [row]
        let model = await loadedModel(prior, selected: row)

        await model.delete(row) { _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(model.selected, row)
    }

    private enum MutationError: Error {
        case rejected
    }

    private func loadedModel(_ rows: [SleepAnnotationRow], selected: SleepAnnotationRow?) async -> SleepAnnotationEditorModel {
        let model = SleepAnnotationEditorModel()
        await model.load(deviceId: "a", fromTsMs: 0, toTsMs: 300_000) { _, _, _ in rows }
        model.selected = selected
        return model
    }

    private func stageIntervalInput() -> [SleepInterval] {
        [
            SleepInterval(stage: .light, start: 0, end: 120),
            SleepInterval(stage: .awake, start: 120, end: 150),
            SleepInterval(stage: .deep, start: 150, end: 300),
        ]
    }

    private func productionStageTimelineOutput(
        using model: SleepAnnotationEditorModel,
        intervals: [SleepInterval]
    ) -> StageTimelineOutput {
        let domain = SleepAnnotationTimelineDomain(startTsMs: 0, endTsMs: 300_000)
        let layout = model.stageTimelineLayout(intervals: intervals, domain: domain)
        return StageTimelineOutput(
            intervals: layout.intervals.map {
                StageOutput(stage: $0.stage, start: $0.start, end: $0.end)
            },
            originSeconds: layout.originSeconds,
            spanSeconds: layout.spanSeconds
        )
    }

    private struct StageTimelineOutput: Equatable {
        let intervals: [StageOutput]
        let originSeconds: TimeInterval
        let spanSeconds: TimeInterval
    }

    private struct StageOutput: Equatable {
        let stage: SleepStage
        let start: TimeInterval
        let end: TimeInterval
    }
}

private actor AnnotationLoadGate {
    private var continuation: CheckedContinuation<[SleepAnnotationRow], Never>?

    func wait() async -> [SleepAnnotationRow] {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning rows: [SleepAnnotationRow]) {
        continuation?.resume(returning: rows)
        continuation = nil
    }
}

private actor AnnotationMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

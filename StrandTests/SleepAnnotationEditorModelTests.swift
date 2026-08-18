import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class SleepAnnotationEditorModelTests: XCTestCase {
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
    }

    func testFailedAddRestoresExactPriorAnnotationsAndDoesNotChangeStages() async {
        let prior = [SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)]
        let model = SleepAnnotationEditorModel(annotations: prior)
        let stages = StagesFixture(awake: 30, light: 240, deep: 90, rem: 80)
        let stagesBefore = stages

        await model.add(deviceId: "a", type: .arose, tsMs: 90_000) { _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(stages, stagesBefore)
    }

    func testFailedMoveRestoresExactPriorAnnotationsAndDoesNotChangeStages() async {
        let row = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let prior = [row, SleepAnnotationRow(deviceId: "a", tsMs: 90_000, type: .arose)]
        let model = SleepAnnotationEditorModel(annotations: prior)
        let stages = StagesFixture(awake: 30, light: 240, deep: 90, rem: 80)
        let stagesBefore = stages

        await model.move(row, toTsMs: 120_000) { _, _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(stages, stagesBefore)
    }

    func testFailedReplaceRestoresExactPriorAnnotationsAndDoesNotChangeStages() async {
        let row = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let prior = [row]
        let model = SleepAnnotationEditorModel(annotations: prior)
        let stages = StagesFixture(awake: 30, light: 240, deep: 90, rem: 80)
        let stagesBefore = stages

        await model.replace(row, with: .fellAsleep) { _, _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(stages, stagesBefore)
    }

    func testFailedDeleteRestoresExactPriorAnnotationsAndDoesNotChangeStages() async {
        let row = SleepAnnotationRow(deviceId: "a", tsMs: 60_000, type: .inBed)
        let prior = [row]
        let model = SleepAnnotationEditorModel(annotations: prior)
        let stages = StagesFixture(awake: 30, light: 240, deep: 90, rem: 80)
        let stagesBefore = stages

        await model.delete(row) { _ in
            throw MutationError.rejected
        }

        XCTAssertEqual(model.annotations, prior)
        XCTAssertEqual(stages, stagesBefore)
    }

    private enum MutationError: Error {
        case rejected
    }

    /// A stage-metric fixture proving annotation mutations have no non-local effects on graph inputs.
    private struct StagesFixture: Equatable {
        let awake: Double
        let light: Double
        let deep: Double
        let rem: Double
    }
}

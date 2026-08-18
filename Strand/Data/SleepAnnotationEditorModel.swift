import CoreGraphics
import Foundation
import WhoopStore

/// One coordinate domain shared by sleep stages, annotations, and clock labels.
struct SleepAnnotationTimelineDomain {
    let bounds: ClosedRange<Int64>

    init(startTsMs: Int64, endTsMs: Int64) {
        bounds = min(startTsMs, endTsMs)...max(startTsMs, endTsMs)
    }

    var originSeconds: TimeInterval { 0 }
    var spanSeconds: TimeInterval {
        max(1, TimeInterval(bounds.upperBound - bounds.lowerBound) / 1_000)
    }
    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(bounds.lowerBound) / 1_000)
    }
}

/// Stable SwiftUI identity matching the store's natural annotation key.
struct SleepAnnotationNaturalKey: Hashable {
    let deviceId: String
    let tsMs: Int64
    let typeRawValue: Int
}

/// Owns the sleep-timeline annotation draft and keeps storage failures invisible to the graph.
///
/// Mutations are optimistic so a marker follows the pointer immediately. Every operation snapshots the
/// complete prior array and selection, then restores both verbatim if the on-device write throws.
@MainActor
final class SleepAnnotationEditorModel: ObservableObject {
    typealias LoadMutation = (String, Int64, Int64) async throws -> [SleepAnnotationRow]
    typealias InsertMutation = (SleepAnnotationRow) async throws -> Void
    typealias MoveMutation = (SleepAnnotationRow, Int64) async throws -> Void
    typealias ReplaceMutation = (SleepAnnotationRow, SleepAnnotationType) async throws -> Void
    typealias DeleteMutation = (SleepAnnotationRow) async throws -> Void

    @Published private(set) var annotations: [SleepAnnotationRow]
    @Published var selected: SleepAnnotationRow?

    private var store: WhoopStore?
    private var activeWindow: Window?
    private var contextRevision = 0
    private var mutationTail: Task<Void, Never>?

    private struct Window: Equatable {
        let deviceId: String
        let bounds: ClosedRange<Int64>
    }

    init(annotations: [SleepAnnotationRow] = []) {
        self.annotations = annotations
    }

    static func clampedX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(0, x), width)
    }

    /// Maps a graph coordinate into its inclusive sleep window and rounds to the nearest 30 seconds.
    static func snappedTimestamp(x: CGFloat, width: CGFloat, startTsMs: Int64, endTsMs: Int64) -> Int64 {
        guard width > 0, endTsMs > startTsMs else { return startTsMs }
        let fraction = Double(clampedX(x, width: width) / width)
        let raw = startTsMs + Int64((Double(endTsMs - startTsMs) * fraction).rounded())
        return min(endTsMs, max(startTsMs, WhoopStore.snappedTsMs(raw)))
    }

    /// Equal-time labels use their canonical type order, matching the store's deterministic ordering.
    static func stackedLabelLevel(for row: SleepAnnotationRow, in rows: [SleepAnnotationRow]) -> Int {
        rows.filter { $0.deviceId == row.deviceId && $0.tsMs == row.tsMs && $0.type.rawValue < row.type.rawValue }.count
    }

    func load(deviceId: String, fromTsMs: Int64, toTsMs: Int64,
              fetch: LoadMutation? = nil) async {
        let window = Window(
            deviceId: deviceId,
            bounds: min(fromTsMs, toTsMs)...max(fromTsMs, toTsMs)
        )
        contextRevision += 1
        let requestedRevision = contextRevision
        activeWindow = window
        annotations = []
        selected = nil

        do {
            let loaded: [SleepAnnotationRow]
            if let fetch {
                loaded = try await fetch(deviceId, window.bounds.lowerBound, window.bounds.upperBound)
            } else {
                let store = try await ensureStore()
                loaded = try await store.sleepAnnotations(
                    deviceId: deviceId,
                    fromTsMs: window.bounds.lowerBound,
                    toTsMs: window.bounds.upperBound
                )
            }
            guard !Task.isCancelled,
                  requestedRevision == contextRevision,
                  activeWindow == window else { return }
            annotations = normalized(loaded.filter {
                $0.deviceId == window.deviceId && window.bounds.contains($0.tsMs)
            })
        } catch {
            guard requestedRevision == contextRevision, activeWindow == window else { return }
            NSLog("SleepAnnotationEditorModel: load failed: \(error)")
        }
    }

    func add(deviceId: String, type: SleepAnnotationType, tsMs: Int64,
             mutation: InsertMutation? = nil) async {
        let requestedRevision = contextRevision
        await enqueueMutation { [weak self] in
            guard let self, self.contextRevision == requestedRevision else { return }
            await self.performAdd(deviceId: deviceId, type: type, tsMs: tsMs, mutation: mutation,
                                  requestedRevision: requestedRevision)
        }
    }

    private func performAdd(deviceId: String, type: SleepAnnotationType, tsMs: Int64,
                            mutation: InsertMutation?, requestedRevision: Int) async {
        guard accepts(deviceId: deviceId, tsMs: tsMs) else { return }
        let row = SleepAnnotationRow(deviceId: deviceId, tsMs: tsMs, type: type)
        let snapshot = snapshot()
        annotations = normalized(annotations + [row])
        selected = row
        do {
            if let mutation {
                try await mutation(row)
            } else {
                try await (try await ensureStore()).insertSleepAnnotation(row)
            }
        } catch {
            if contextRevision == requestedRevision { restore(snapshot) }
        }
    }

    func move(_ row: SleepAnnotationRow, toTsMs: Int64, mutation: MoveMutation? = nil) async {
        let requestedRevision = contextRevision
        await enqueueMutation { [weak self] in
            guard let self, self.contextRevision == requestedRevision else { return }
            await self.performMove(row, toTsMs: toTsMs, mutation: mutation,
                                   requestedRevision: requestedRevision)
        }
    }

    private func performMove(_ row: SleepAnnotationRow, toTsMs: Int64, mutation: MoveMutation?,
                             requestedRevision: Int) async {
        guard accepts(row), accepts(deviceId: row.deviceId, tsMs: toTsMs) else { return }
        guard row.tsMs != toTsMs else { return }
        let replacement = SleepAnnotationRow(deviceId: row.deviceId, tsMs: toTsMs, type: row.type)
        let snapshot = snapshot()
        annotations = normalized(annotations.filter { $0 != row } + [replacement])
        selected = replacement
        do {
            if let mutation {
                try await mutation(row, toTsMs)
            } else {
                try await (try await ensureStore()).moveSleepAnnotation(row, toTsMs: toTsMs)
            }
        } catch {
            if contextRevision == requestedRevision { restore(snapshot) }
        }
    }

    func replace(_ row: SleepAnnotationRow, with type: SleepAnnotationType,
                 mutation: ReplaceMutation? = nil) async {
        let requestedRevision = contextRevision
        await enqueueMutation { [weak self] in
            guard let self, self.contextRevision == requestedRevision else { return }
            await self.performReplace(row, with: type, mutation: mutation,
                                      requestedRevision: requestedRevision)
        }
    }

    private func performReplace(_ row: SleepAnnotationRow, with type: SleepAnnotationType,
                                mutation: ReplaceMutation?, requestedRevision: Int) async {
        guard accepts(row) else { return }
        guard row.type != type else { return }
        let replacement = SleepAnnotationRow(deviceId: row.deviceId, tsMs: row.tsMs, type: type)
        let snapshot = snapshot()
        annotations = normalized(annotations.filter { $0 != row } + [replacement])
        selected = replacement
        do {
            if let mutation {
                try await mutation(row, type)
            } else {
                try await (try await ensureStore()).replaceSleepAnnotation(row, with: type)
            }
        } catch {
            if contextRevision == requestedRevision { restore(snapshot) }
        }
    }

    func delete(_ row: SleepAnnotationRow, mutation: DeleteMutation? = nil) async {
        let requestedRevision = contextRevision
        await enqueueMutation { [weak self] in
            guard let self, self.contextRevision == requestedRevision else { return }
            await self.performDelete(row, mutation: mutation, requestedRevision: requestedRevision)
        }
    }

    private func performDelete(_ row: SleepAnnotationRow, mutation: DeleteMutation?,
                               requestedRevision: Int) async {
        guard accepts(row) else { return }
        let snapshot = snapshot()
        annotations.removeAll { $0 == row }
        if selected == row { selected = nil }
        do {
            if let mutation {
                try await mutation(row)
            } else {
                try await (try await ensureStore()).deleteSleepAnnotation(row)
            }
        } catch {
            if contextRevision == requestedRevision { restore(snapshot) }
        }
    }

    private func ensureStore() async throws -> WhoopStore {
        if let store { return store }
        let opened = try await WhoopStore(path: StorePaths.defaultDatabasePath())
        store = opened
        return opened
    }

    private func accepts(_ row: SleepAnnotationRow) -> Bool {
        accepts(deviceId: row.deviceId, tsMs: row.tsMs)
    }

    private func accepts(deviceId: String, tsMs: Int64) -> Bool {
        activeWindow?.deviceId == deviceId && activeWindow?.bounds.contains(tsMs) == true
    }

    /// Store writes run in invocation order so an older rollback can never erase a newer success.
    private func enqueueMutation(_ operation: @escaping @MainActor () async -> Void) async {
        let predecessor = mutationTail
        let task = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        mutationTail = task
        await task.value
    }

    private func normalized(_ rows: [SleepAnnotationRow]) -> [SleepAnnotationRow] {
        var result: [SleepAnnotationRow] = []
        for row in rows.sorted(by: Self.isOrdered) where !result.contains(row) { result.append(row) }
        return result
    }

    nonisolated private static func isOrdered(_ lhs: SleepAnnotationRow, _ rhs: SleepAnnotationRow) -> Bool {
        if lhs.tsMs != rhs.tsMs { return lhs.tsMs < rhs.tsMs }
        if lhs.type.rawValue != rhs.type.rawValue { return lhs.type.rawValue < rhs.type.rawValue }
        return lhs.deviceId < rhs.deviceId
    }

    private func snapshot() -> (annotations: [SleepAnnotationRow], selected: SleepAnnotationRow?) {
        (annotations, selected)
    }

    private func restore(_ snapshot: (annotations: [SleepAnnotationRow], selected: SleepAnnotationRow?)) {
        annotations = snapshot.annotations
        selected = snapshot.selected
    }
}

extension SleepAnnotationType {
    var displayLabel: String {
        switch self {
        case .inBed: return String(localized: "In bed")
        case .fellAsleep: return String(localized: "Fell asleep")
        case .awakeInBed: return String(localized: "Awake in bed")
        case .brieflyGotUp: return String(localized: "Briefly got up")
        case .arose: return String(localized: "Arose")
        }
    }
}

extension SleepAnnotationRow {
    var naturalKey: SleepAnnotationNaturalKey {
        SleepAnnotationNaturalKey(deviceId: deviceId, tsMs: tsMs, typeRawValue: type.rawValue)
    }
}

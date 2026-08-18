import CoreGraphics
import Foundation
import WhoopStore

/// Owns the sleep-timeline annotation draft and keeps storage failures invisible to the graph.
///
/// Mutations are optimistic so a marker follows the pointer immediately. Every operation snapshots the
/// complete prior array and selection, then restores both verbatim if the on-device write throws.
@MainActor
final class SleepAnnotationEditorModel: ObservableObject {
    typealias InsertMutation = (SleepAnnotationRow) async throws -> Void
    typealias MoveMutation = (SleepAnnotationRow, Int64) async throws -> Void
    typealias ReplaceMutation = (SleepAnnotationRow, SleepAnnotationType) async throws -> Void
    typealias DeleteMutation = (SleepAnnotationRow) async throws -> Void

    @Published private(set) var annotations: [SleepAnnotationRow]
    @Published var selected: SleepAnnotationRow?

    private var store: WhoopStore?

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

    func load(deviceId: String, fromTsMs: Int64, toTsMs: Int64) async {
        do {
            let store = try await ensureStore()
            let loaded = try await store.sleepAnnotations(
                deviceId: deviceId,
                fromTsMs: min(fromTsMs, toTsMs),
                toTsMs: max(fromTsMs, toTsMs)
            )
            guard !Task.isCancelled else { return }
            annotations = loaded
            if let selected, !annotations.contains(selected) { self.selected = nil }
        } catch {
            NSLog("SleepAnnotationEditorModel: load failed: \(error)")
        }
    }

    func add(deviceId: String, type: SleepAnnotationType, tsMs: Int64,
             mutation: InsertMutation? = nil) async {
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
            restore(snapshot)
        }
    }

    func move(_ row: SleepAnnotationRow, toTsMs: Int64, mutation: MoveMutation? = nil) async {
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
            restore(snapshot)
        }
    }

    func replace(_ row: SleepAnnotationRow, with type: SleepAnnotationType,
                 mutation: ReplaceMutation? = nil) async {
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
            restore(snapshot)
        }
    }

    func delete(_ row: SleepAnnotationRow, mutation: DeleteMutation? = nil) async {
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
            restore(snapshot)
        }
    }

    private func ensureStore() async throws -> WhoopStore {
        if let store { return store }
        let opened = try await WhoopStore(path: StorePaths.defaultDatabasePath())
        store = opened
        return opened
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

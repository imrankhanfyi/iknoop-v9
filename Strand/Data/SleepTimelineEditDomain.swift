import CoreGraphics
import Foundation

/// The editable display range for a sleep session. The outer corridor supports corrections without
/// inventing stage data: stage intervals remain in their recorded time range.
enum SleepBoundary {
    case asleep
    case woke
}

/// A single-handle save command. The stationary bound is copied verbatim, preventing a drag on one
/// marker from accidentally committing a change to the other marker.
struct SleepBoundaryCommit: Equatable {
    let startTs: Int
    let endTs: Int

    static func window(changing boundary: SleepBoundary, to timestamp: Int,
                       startTs: Int, endTs: Int) -> SleepBoundaryCommit {
        switch boundary {
        case .asleep:
            SleepBoundaryCommit(startTs: timestamp, endTs: endTs)
        case .woke:
            SleepBoundaryCommit(startTs: startTs, endTs: timestamp)
        }
    }
}

struct SleepTimelineEditDomain: Equatable {
    static let marginSeconds = 90 * 60
    static let snapSeconds = 30

    let sessionStartTs: Int
    let sessionEndTs: Int

    init(sessionStartTs: Int, sessionEndTs: Int) {
        self.sessionStartTs = min(sessionStartTs, sessionEndTs)
        self.sessionEndTs = max(sessionStartTs, sessionEndTs)
    }

    /// The correction values are deliberately ignored: this coordinate space is anchored to the
    /// detector's immutable observed window, so a saved marker never makes its graph resize.
    init(detectedStartTs: Int, detectedEndTs: Int, adjustedStartTs: Int, adjustedEndTs: Int) {
        self.init(sessionStartTs: detectedStartTs, sessionEndTs: detectedEndTs)
    }

    var displayStartTs: Int { sessionStartTs - Self.marginSeconds }
    var displayEndTs: Int { sessionEndTs + Self.marginSeconds }
    var spanSeconds: Int { max(1, displayEndTs - displayStartTs) }

    /// Whole-clock-hour anchors for the drag ruler. The range is detected-data anchored, so these
    /// labels remain visually stable while either marker moves.
    static func hourTicks(from startTs: Int, through endTs: Int) -> [Int] {
        let first = ((startTs / 3_600) + 1) * 3_600
        guard first <= endTs else { return [] }
        return Array(stride(from: first, through: endTs, by: 3_600))
    }

    func x(for timestamp: Int, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let fraction = Double(clamp(timestamp, lower: displayStartTs, upper: displayEndTs) - displayStartTs)
            / Double(spanSeconds)
        return CGFloat(fraction) * width
    }

    func seconds(forX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return displayStartTs }
        let fraction = min(1, max(0, Double(x / width)))
        return displayStartTs + Int((fraction * Double(spanSeconds)).rounded())
    }

    /// Snaps only the boundary being dragged. The stationary boundary remains the stored value;
    /// the moved boundary is clamped to a valid absolute 30-second grid point before/after it.
    func normalized(start: Int, end: Int, dragging: SleepBoundary) -> (start: Int, end: Int) {
        switch dragging {
        case .asleep:
            let lower = firstGrid(atOrAfter: displayStartTs)
            let upper = lastGrid(atOrBefore: min(displayEndTs, end - Self.snapSeconds))
            return (clampGrid(start, lower: lower, upper: max(lower, upper)), end)
        case .woke:
            let lower = firstGrid(atOrAfter: max(displayStartTs, start + Self.snapSeconds))
            let upper = lastGrid(atOrBefore: displayEndTs)
            return (start, clampGrid(end, lower: min(lower, upper), upper: upper))
        }
    }

    private func clampGrid(_ timestamp: Int, lower: Int, upper: Int) -> Int {
        let nearest = Int((Double(timestamp) / Double(Self.snapSeconds)).rounded()) * Self.snapSeconds
        return clamp(nearest, lower: lower, upper: upper)
    }

    private func firstGrid(atOrAfter timestamp: Int) -> Int {
        let remainder = timestamp % Self.snapSeconds
        return remainder == 0 ? timestamp : timestamp + (Self.snapSeconds - remainder)
    }

    private func lastGrid(atOrBefore timestamp: Int) -> Int {
        timestamp - (timestamp % Self.snapSeconds)
    }

    private func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

/// Retains the display corridor initially shown for each immutable detected-session key. A correction
/// changes the sleep window, but must not make its already-visible graph stretch or shift beneath it.
struct SleepTimelineDisplayDomainCache {
    private var domains: [Int: SleepTimelineEditDomain] = [:]

    mutating func domain(for sessionKey: Int, sessionStartTs: Int, sessionEndTs: Int) -> SleepTimelineEditDomain {
        if let domain = domains[sessionKey] { return domain }
        let domain = SleepTimelineEditDomain(sessionStartTs: sessionStartTs, sessionEndTs: sessionEndTs)
        domains[sessionKey] = domain
        return domain
    }

    func cachedDomain(for sessionKey: Int) -> SleepTimelineEditDomain? {
        domains[sessionKey]
    }
}

/// The observed-data axis for the heart-rate trace. Unlike the editable stage corridor, it has no
/// synthetic leading/trailing margin: a missing sample must not turn into an empty-looking chart.
struct SleepObservedTimelineDomain: Equatable {
    let originSeconds: TimeInterval = 0
    let spanSeconds: TimeInterval

    init(sessionStartTs: Int, sessionEndTs: Int) {
        spanSeconds = TimeInterval(max(1, abs(sessionEndTs - sessionStartTs)))
    }
}

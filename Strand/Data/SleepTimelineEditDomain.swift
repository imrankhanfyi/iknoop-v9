import CoreGraphics
import Foundation

/// The editable display range for a sleep session. The outer corridor supports corrections without
/// inventing stage data: stage intervals remain in their recorded time range.
enum SleepBoundary {
    case asleep
    case woke
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

    var displayStartTs: Int { sessionStartTs - Self.marginSeconds }
    var displayEndTs: Int { sessionEndTs + Self.marginSeconds }
    var spanSeconds: Int { max(1, displayEndTs - displayStartTs) }

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

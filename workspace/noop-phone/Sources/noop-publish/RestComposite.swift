import Foundation

/// Port of `AnalyticsEngine.Rest.composite` (Packages/StrandAnalytics) — the sleep-performance
/// score (0–100).
///
/// WHY PORTED: the app computes this at render time in two places that agree —
/// `SleepView.performanceSeries` calls `composite(daily:)` with defaults, and `TodayView` reads the
/// persisted `metricSeries['<computed>','sleep_performance']` row. Verified against the live store:
/// with neutral consistency this reproduces the stored values exactly (2026-07-28 → 90.54,
/// 2026-07-13 → 49.09). `Checks.verifySleepPerformance` asserts that agreement on every publish, so
/// a future formula change upstream surfaces as a loud failure rather than a silently wrong viewer.
///
/// The persisted series exists for only some days; the app computes the rest. We do the same: prefer
/// the stored value where present (it is what Today shows), fall back to this computation.
enum RestComposite {
    static let defaultNeedHours: Double = 8.0
    static let restorativeTarget: Double = 0.50
    static let deepShareTarget: Double = 0.13
    static let deepFloorFactor: Double = 0.5
    static let neutralConsistency: Double = 0.5

    static let wDuration: Double = 0.50
    static let wEfficiency: Double = 0.20
    static let wRestorative: Double = 0.20
    static let wConsistency: Double = 0.10

    private static func clamp01(_ x: Double) -> Double { max(0.0, min(1.0, x)) }

    static func composite(tstSeconds: Double,
                          efficiency: Double,
                          restorativeSeconds: Double,
                          deepSeconds: Double?,
                          needHours: Double = defaultNeedHours,
                          consistency: Double? = nil) -> Double {
        let needSeconds = max(needHours, 0.1) * 3600.0
        let durationScore = clamp01(tstSeconds / needSeconds)
        let efficiencyScore = clamp01(efficiency)
        // Deep-adequacy factor in [deepFloorFactor, 1]: 1.0 once deep >= target share, ramping down
        // to the floor as deep -> 0. nil deep (unknown split) => 1.0, no adjustment.
        let deepFactor: Double = {
            guard let deep = deepSeconds, tstSeconds > 0, deepShareTarget > 0 else { return 1.0 }
            let adequacy = clamp01((deep / tstSeconds) / deepShareTarget)
            return deepFloorFactor + (1.0 - deepFloorFactor) * adequacy
        }()
        let restorativeScore = tstSeconds > 0
            ? clamp01((restorativeSeconds / tstSeconds) / restorativeTarget) * deepFactor
            : 0.0
        let consistencyScore = clamp01(consistency ?? neutralConsistency)

        let weighted = wDuration * durationScore
            + wEfficiency * efficiencyScore
            + wRestorative * restorativeScore
            + wConsistency * consistencyScore
        return (weighted * 10000.0).rounded() / 100.0
    }

    /// The `composite(daily:)` overload: derived from a persisted daily row. nil when there is no sleep.
    static func composite(totalSleepMin: Double?, efficiency: Double?,
                          deepMin: Double?, remMin: Double?) -> Double? {
        guard let tstMin = totalSleepMin, tstMin > 0, let eff = efficiency else { return nil }
        let tstSec = tstMin * 60.0
        let deepSec = (deepMin ?? 0) * 60.0
        let restorativeSec = ((deepMin ?? 0) + (remMin ?? 0)) * 60.0
        return composite(tstSeconds: tstSec, efficiency: eff,
                         restorativeSeconds: restorativeSec, deepSeconds: deepSec)
    }
}

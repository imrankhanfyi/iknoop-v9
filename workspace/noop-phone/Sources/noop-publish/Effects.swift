import Foundation

/// Lifestyle effects for the phone's Lifestyle tab: for every checklist item × outcome, NOOP's own
/// lag-aware EffectRanker math (vendored verbatim in Vendored/, drift-checked by
/// scripts/check-vendored.sh), restricted to days the item was EXPLICITLY answered (AnsweredEffects).
///
/// Alignment: a check-in is keyed by the MORNING it leads into (journal convention), and NOOP's daily
/// outcomes are keyed by wake day, so lag 0 = "the night right after the behaviour", lag 1 = the night
/// after that. Outcomes span ALL history (not the 21-day window): the legacy journal is Jul–Aug 2026.
///
/// Honesty: rows carry effect size, n on both sides, lag and confidence. Items that never clear the
/// group gate (min(nWith, nWithout) ≥ 5 at some lag) are reported as `insufficient` with their counts,
/// never dropped silently and never shown as an effect.
enum Effects {
    static let outcomes: [(key: String, label: String)] = [
        ("sleepPerformance", "Sleep performance"),
        ("hrv", "HRV"),
        ("restingHr", "Resting HR"),
    ]

    static func build(model: ReadModel, side: SideStore, items: [LifestyleItem]) throws -> [[String: Any]] {
        let answers = try Lifestyle.merged(model: model, side: side, items: items,
                                           from: "0000-01-01", to: "9999-12-31")
        let series = try outcomeSeries(model: model)

        var out: [[String: Any]] = []
        for it in items {
            var yes = Set<String>(), answered = Set<String>()
            for (day, m) in answers { if let v = m[it.id] { answered.insert(day); if v { yes.insert(day) } } }
            for o in outcomes {
                let byDay = series[o.key] ?? [:]
                if let r = AnsweredEffects.answeredBestLag(yesDays: yes, answeredDays: answered,
                                                           outcomeByDay: byDay, behavior: it.id, outcome: o.key) {
                    let e = r.effect
                    out.append(["item": it.id, "outcome": o.key, "outcomeLabel": o.label, "status": "ok",
                                "lag": r.lag, "meanWith": round1(e.meanWith), "meanWithout": round1(e.meanWithout),
                                "delta": round1(e.delta), "cohensD": round2(e.cohensD),
                                "nWith": e.nWith, "nWithout": e.nWithout, "significant": e.significant,
                                "confidence": r.confidence.rawValue])
                } else {
                    // Counts at lag 0 so the phone can say how far each side is from the gate.
                    let paired = byDay.filter { answered.contains($0.key) }
                    let nWith = paired.keys.filter { yes.contains($0) }.count
                    out.append(["item": it.id, "outcome": o.key, "outcomeLabel": o.label, "status": "insufficient",
                                "nWith": nWith, "nWithout": paired.count - nWith,
                                "needPerSide": BehaviorInsights.minGroupForSignificance])
                }
            }
        }
        return out
    }

    /// Daily outcome maps keyed by wake day, from the computed (NOOP-native) source only.
    static func outcomeSeries(model: ReadModel) throws -> [String: [String: Double]] {
        let ids = "(" + model.computedReadIds.map(sqlQuote).joined(separator: ",") + ")"
        var s: [String: [String: Double]] = [:]
        try model.db.query("SELECT day, value FROM metricSeries WHERE deviceId IN \(ids) AND key = 'sleep_performance';") { r in
            if let d = r.text(0), let v = r.double(1) { s["sleepPerformance", default: [:]][d] = v }
        }
        try model.db.query("SELECT day, avgHrv, restingHr FROM dailyMetric WHERE deviceId IN \(ids);") { r in
            guard let d = r.text(0) else { return }
            if let v = r.double(1) { s["hrv", default: [:]][d] = v }
            if let v = r.double(2) { s["restingHr", default: [:]][d] = v }
        }
        return s
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

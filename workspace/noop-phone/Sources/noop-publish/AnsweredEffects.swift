import Foundation

/// Effects for the phone viewer: EffectRanker's lag search, but each behaviour's comparison is
/// restricted to days on which that behaviour was EXPLICITLY ANSWERED (yes or no).
///
/// Why an adapter and not EffectRanker.rank: `BehaviorInsights.effect` puts every outcome day that
/// is not a "yes" day into the WITHOUT group (BehaviorInsights.swift:92-94). With a journal that went
/// unlogged for months, every unlogged day would count as "no alcohol, no caffeine…". The filter must
/// apply on the BEHAVIOUR day, i.e. AFTER the lag shift — filtering the outcome map before shifting
/// would filter on the outcome day, the wrong day for lags 1 and 2.
///
/// Mirrors `EffectRanker.bestLag` exactly (same lag set, group gate, tie-break, confidence); the
/// self-test pins `answeredBestLag(answered: all days) == EffectRanker.bestLag`.
enum AnsweredEffects {
    static func answeredBestLag(yesDays: Set<String>, answeredDays: Set<String>,
                                outcomeByDay: [String: Double],
                                behavior: String, outcome: String) -> RankedEffect? {
        var best: (lag: Int, effect: BehaviorEffect)?
        for lag in EffectRanker.lagSet {
            let shifted = EffectRanker.shiftedOutcome(outcomeByDay, byLag: lag)
                .filter { answeredDays.contains($0.key) }
            guard let e = BehaviorInsights.effect(behaviorDays: yesDays, outcomeByDay: shifted,
                                                  behavior: behavior, outcome: outcome) else { continue }
            guard Swift.min(e.nWith, e.nWithout) >= BehaviorInsights.minGroupForSignificance else { continue }
            if let cur = best {
                let better = abs(e.cohensD) > abs(cur.effect.cohensD)
                    || (abs(e.cohensD) == abs(cur.effect.cohensD) && lag < cur.lag)
                if better { best = (lag, e) }
            } else {
                best = (lag, e)
            }
        }
        guard let chosen = best else { return nil }
        let pairs = Swift.min(chosen.effect.nWith, chosen.effect.nWithout)
        return RankedEffect(behavior: behavior, outcome: outcome, lag: chosen.lag,
                            effect: chosen.effect, confidence: EffectRanker.confidence(forPairs: pairs))
    }
}

extension SelfTest {
    /// Pins the answered-days adapter to the vendored EffectRanker: with EVERY behaviour day answered
    /// it must equal `EffectRanker.bestLag` exactly (deterministic pseudo-random fixtures, 300 trials);
    /// and an unanswered day must NOT enter the "without" group.
    static func effectsChecks() -> [String] {
        var failures: [String] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 11 }
        for trial in 0..<300 {
            var outcome: [String: Double] = [:]; var yes: Set<String> = []
            for d in 0..<60 {
                guard let day = CorrelationEngine.shiftDay("2026-07-01", by: d) else { continue }
                if next() % 10 < 8 { outcome[day] = 30 + Double(next() % 6500) / 100 }
                if next() % 2 == 0 { yes.insert(day) }
            }
            var all = Set(outcome.keys)
            for lag in [1, 2] { all.formUnion(outcome.keys.compactMap { CorrelationEngine.shiftDay($0, by: -lag) }) }
            let a = EffectRanker.bestLag(behaviorDays: yes, outcomeByDay: outcome, behavior: "b", outcome: "o")
            let b = AnsweredEffects.answeredBestLag(yesDays: yes, answeredDays: all, outcomeByDay: outcome,
                                                    behavior: "b", outcome: "o")
            // Tolerant compare: BehaviorInsights sums over a Dictionary, whose iteration order Swift
            // randomizes per process, so means/variances can differ in the last bits between two maps
            // with equal contents. Same lag, same counts, values equal to 1e-9 = same result.
            let same: Bool = {
                switch (a, b) {
                case (nil, nil): return true
                case let (x?, y?):
                    return x.lag == y.lag && x.confidence == y.confidence
                        && x.effect.nWith == y.effect.nWith && x.effect.nWithout == y.effect.nWithout
                        && abs(x.effect.meanWith - y.effect.meanWith) < 1e-9
                        && abs(x.effect.meanWithout - y.effect.meanWithout) < 1e-9
                        && abs(x.effect.cohensD - y.effect.cohensD) < 1e-9
                default: return false
                }
            }()
            if !same { failures.append("effects adapter != EffectRanker.bestLag (trial \(trial))"); break }
        }
        // 6 yes days (high), 6 answered-no days (low), 10 UNANSWERED days (very low): the unanswered
        // days must not drag meanWithout down.
        var outcome: [String: Double] = [:]; var yes: Set<String> = []; var answered: Set<String> = []
        for d in 0..<22 {
            let day = CorrelationEngine.shiftDay("2026-07-01", by: d)!
            if d < 6 { yes.insert(day); answered.insert(day); outcome[day] = 80 + Double(d) }
            else if d < 12 { answered.insert(day); outcome[day] = 60 + Double(d % 3) }
            else { outcome[day] = 10 }
        }
        if let r = AnsweredEffects.answeredBestLag(yesDays: yes, answeredDays: answered, outcomeByDay: outcome,
                                                   behavior: "b", outcome: "o") {
            if r.lag != 0 || r.effect.nWithout != 6 || r.effect.meanWithout < 59 {
                failures.append("effects: unanswered days leaked into the without group (lag \(r.lag), nWithout \(r.effect.nWithout), meanWithout \(r.effect.meanWithout))")
            }
        } else { failures.append("effects: answered fixture produced no effect") }
        return failures
    }
}

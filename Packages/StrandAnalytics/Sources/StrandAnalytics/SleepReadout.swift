import Foundation
import WhoopProtocol

// SleepReadout.swift - pure values for the Sleep & Rest live-readout panel.
//
// hrDensityNow + gravityCoverageNow are computed from the same streams detection reads, so the
// panel shows what the detector sees. lastNightGateFired is parsed from the tagged log tail
// (the gate-trace lines E2/E3 emit), so the panel reflects exactly which gate fired tonight.
// No state, no side effects, no em-dashes.

public enum SleepReadout {

    /// HR samples per minute over the stream's own span. 0 when fewer than 2 samples.
    public static func hrDensityPerMinute(hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return 0 }
        let sorted = hr.sorted { $0.ts < $1.ts }
        let spanS = Double(sorted.last!.ts - sorted.first!.ts)
        if spanS <= 0 { return 0 }
        return Double(sorted.count) / (spanS / 60.0)
    }

    /// Fraction of the HR window the gravity stream spans, in [0, 1]. The same ratio the
    /// sparse-gravity gate keys on (`SleepStager.sparseGravitySpanFrac`); a value below that
    /// constant means tonight's gravity is sparse.
    public static func gravityCoverageFraction(gravity: [GravitySample], hr: [HRSample]) -> Double {
        guard gravity.count >= 2, hr.count >= 2 else { return 0 }
        let g = gravity.sorted { $0.ts < $1.ts }
        let h = hr.sorted { $0.ts < $1.ts }
        let hrSpan = Double(h.last!.ts - h.first!.ts)
        if hrSpan <= 0 { return 0 }
        let gravSpan = Double(g.last!.ts - g.first!.ts)
        return max(0.0, min(1.0, gravSpan / hrSpan))
    }

    /// How far the MOTION frontier may trail the HR frontier before the newest night is treated as
    /// provisional.
    ///
    /// A caught-up strap does NOT hold the two frontiers level. Measured on a real strap
    /// (2026-07-27): while catching up the lag fell steadily from 5007 s to 18 s, then climbed again
    /// (49, 82, 109, 136, 178 s) because gravity had stopped at the end of an offload burst while HR
    /// kept streaming live over 0x2A37. So the caught-up state is a SAWTOOTH whose peak is the
    /// interval between offload bursts, and the threshold has to clear that peak or a finished night
    /// gets badged for the tail of every cycle.
    ///
    /// That peak is set by the app's periodic-offload cadence: 900 s normally, but stretched to
    /// 2700 s when the strap is low on battery (`BLEManager.backfillIntervalSeconds` /
    /// `lowBatteryBackfillIntervalSeconds`). One hour clears the low-battery case plus the burst's own
    /// duration, and stays far below the multi-hour lags that motivate this (a real truncated-night
    /// case measured 29 880 s). The cost of the wide bar is that a STALLED offload is only called out
    /// after an hour; an offload that is merely running is covered by the `backfilling` term instead.
    ///
    /// Cannot reference the BLE constants directly: this module is app-free and CoreBluetooth-free.
    /// If that cadence changes, this must be re-derived.
    public static let provisionalMotionLagS = 60 * 60

    /// Whether the NEWEST night should be presented as still-syncing rather than final.
    ///
    /// Why this is needed at all: `gravitySample` reaches the database only through the strap's
    /// historical offload, while `hrSample` also arrives live over the standard 0x2A37 profile.
    /// Sleep detection derives its still-spine from gravity, so the detected wake time can never
    /// run past the motion frontier. Mid-offload the newest night is therefore routinely truncated
    /// at whatever hour the offload has reached, and looks like an early wake. Left unlabelled it
    /// reads as final, and inviting a hand-correction is actively harmful: an edited session is
    /// marked `userEdited`, which pins its end timestamp against every later recompute.
    ///
    /// Two independent terms, either of which is sufficient:
    ///
    /// 1. `backfilling` - an offload is running right now.
    /// 2. The motion frontier trails the HR frontier by more than `provisionalMotionLagS`.
    ///
    /// Neither term subsumes the other. Term 1 covers a burst whose gap has already closed below
    /// the threshold, but it describes a SINGLE offload session and goes false in the gaps between
    /// the chained sessions of a long catch-up, so on its own it flickers across exactly the window
    /// that matters, and it says nothing about an offload that has stalled with hours outstanding.
    /// Term 2 covers both of those, and being a comparison of two DATA frontiers it carries no
    /// wall-clock term, so a skewed strap clock cannot trip it.
    ///
    /// Term 1 is additionally qualified on `nightCouldStillGrow`. Unqualified it fires on EVERY
    /// periodic offload (every `backfillIntervalSeconds` while connected), so on a caught-up strap it
    /// would label a correct wake time all day long and the badge would be trained into background
    /// noise before the morning it actually matters. Term 2 is deliberately NOT qualified the same
    /// way: the recompute lags the frontier, so on the real case the night still read 01:46 while the
    /// motion frontier had already reached 03:13, a delta of 87 minutes against the 90-minute bound.
    /// Gating term 2 on that delta would have come within 3 minutes of suppressing the very signal
    /// this exists for. The cost is that a night which is genuinely final but sits behind a STALLED
    /// offload can still be badged; that is the safe direction to err.
    ///
    /// Returns false when either frontier is absent, so a fresh install with no samples yet is not
    /// labelled. Callers must apply this only to the newest night: the offload replays
    /// chronologically, so older nights are already complete.
    public static func isNightProvisional(nightEndTs: Int?, motionFrontierTs: Int?,
                                         hrFrontierTs: Int?, backfilling: Bool) -> Bool {
        if backfilling,
           nightCouldStillGrow(nightEndTs: nightEndTs, motionFrontierTs: motionFrontierTs) {
            return true
        }
        guard let motionFrontierTs, let hrFrontierTs else { return false }
        return hrFrontierTs - motionFrontierTs > provisionalMotionLagS
    }

    /// Whether more offloaded motion could still EXTEND this night, rather than only add a separate
    /// later session.
    ///
    /// `SleepStager.nightContinuationGapMin` is the bound the detector itself uses: a still-run that
    /// begins more than that far after the previous accepted run does not continue the overnight
    /// chain, it faces the full nap guard as isolated daytime stillness. So once the motion frontier
    /// has advanced further than that past the night's end WITHOUT the night having grown, the window
    /// in which an extension could have been found is fully covered and this night is settled.
    ///
    /// Conservative when either input is absent: an unknown night end cannot be ruled out, so it
    /// returns true rather than silently suppressing the badge.
    static func nightCouldStillGrow(nightEndTs: Int?, motionFrontierTs: Int?) -> Bool {
        guard let nightEndTs, let motionFrontierTs else { return true }
        return motionFrontierTs - nightEndTs <= SleepStager.nightContinuationGapMin * 60
    }

    /// The gate named by the most recent gate-trace line in the tagged log tail, or nil.
    /// Lines look like "[sleep] gate run=1 ... gate=accepted ...".
    public static func lastGateFired(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() where line.contains("gate=") {
            guard let range = line.range(of: "gate=") else { continue }
            let after = line[range.upperBound...]
            let token = after.prefix { $0 != " " }
            if !token.isEmpty { return String(token) }
        }
        return nil
    }
}

/// Pure values for the Recovery (Charge) and HRV live-readout panels (Group G). Each parses the tagged
/// log tail the Recovery / HRV test-mode emitters write, so the panel reflects exactly the last Charge
/// breakdown or HRV computation. No state, no side effects, no em-dashes.
public enum TestReadout {

    /// The Charge outcome for the MOST RECENT day from the `.recovery`-tagged tail, or nil. The emitter
    /// writes "[recovery] charge day=<yyyy-MM-dd> ... score=<n> band=<b> ..." (or a "nilScore reason=..."
    /// line when that day could not be scored). Returns the score/band fragment so the panel reads the same
    /// number the dashboard shows; falls back to the nil-reason only when the NEWEST day genuinely has none.
    ///
    /// #343: the engine emits days NEWEST-FIRST (and may replay several passes), so the LAST line in the
    /// tail is the OLDEST window-edge day — which is routinely a cold-start `nilScore missingInput` (no
    /// baseline history at the window's far edge). Scanning the tail in reverse therefore surfaced that
    /// stale edge day and read "no score (input missing)" even when today's Charge was a healthy green.
    /// Instead select by the newest `day=` (ISO dates compare lexicographically), order-independently, and
    /// prefer the last pass for that day. Mirrors the Kotlin twin `TestReadout.lastChargeBreakdown`.
    public static func lastChargeBreakdown(taggedTail: [String]) -> String? {
        var bestDay = ""
        var outcome: String?
        for line in taggedTail {
            guard let dr = line.range(of: "day=") else { continue }
            let day = String(line[dr.upperBound...].prefix(10))
            guard day.count == 10, day >= bestDay else { continue }
            let parsed: String?
            if let r = line.range(of: "score=") {
                let upto = line[r.lowerBound...].prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                parsed = upto.isEmpty ? nil : String(upto)
            } else if let r = line.range(of: "nilScore reason=") {
                let token = line[r.upperBound...].prefix { $0 != " " }
                parsed = token.isEmpty ? nil : "no score (\(token))"
            } else {
                parsed = nil   // a baseline/term line for this day carries no outcome — skip it
            }
            guard let parsed else { continue }
            if day > bestDay { bestDay = day }   // a strictly newer day with an outcome resets the winner
            outcome = parsed                     // newest day (or a later pass of it) → its outcome wins
        }
        return outcome
    }

    /// The most recent HRV result fragment from the `.hrv`-tagged tail, or nil. The emitter writes
    /// "[hrv] hrv rmssd=<n>ms sdnn=<n>ms meanNN=<n>ms" on success, or "[hrv] hrv result=nil (..)" when a
    /// gate refused the reading. Returns the rmssd/sdnn fragment, or the nil note, so the panel reads the
    /// same outcome the snapshot screen showed.
    public static func lastHrvComputation(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "rmssd=") {
                let frag = String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
            if line.contains("result=nil") { return "no reading (filtered out)" }
        }
        return nil
    }
}

/// Pure values for the Steps live-readout panel. Each parses the `.steps`-tagged log tail the Steps
/// test-mode emitters write, so the panel reflects exactly the last step estimate and calibration state
/// without the engine having to expose new published properties. No state, no side effects, no em-dashes.
/// The Kotlin twin is the StepsReadout object in StepsEstimateEngineTrace.kt.
public enum StepsReadout {

    /// Today's steps for the `stepsToday` id: the most recent scaled-steps figure in the tagged tail. The
    /// 5/MG raw emitter writes "[steps] stepsRaw total ... scaledSteps=<n> ...", and the WHOOP-4 path's
    /// estimate is surfaced the same way ("stepsEst day=... steps=<n>"). Returns the most recent of either,
    /// so the panel reads the same number the Today tile shows. nil when no step line is present yet.
    public static func stepsToday(taggedTail: [String]) -> Int? {
        for line in taggedTail.reversed() {
            if let n = intField(line, key: "scaledSteps=") { return n }
            if line.contains("stepsEst "), let n = intField(line, key: "steps=") { return n }
        }
        return nil
    }

    /// Calibration state for the `calibrationState` id: the most recent calibration outcome fragment the
    /// WHOOP-4 calibration emitter writes ("k=<n> sampleDays=<n> confidence=<n> manual=<bool>" on a fit, or
    /// "needsMoreDays have=<n> need=<n>" when withheld). Returns the parsed fragment so the panel reads the
    /// same state Settings shows. nil when no calibration line is present yet (e.g. a 5/MG-only session).
    public static func calibrationState(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "stepsCal fit ") {
                let frag = String(line[r.upperBound...]).prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
            if let r = line.range(of: "stepsCal withheld reason=") {
                let frag = String(line[r.upperBound...]).prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return "not calibrated (\(frag))" }
            }
        }
        return nil
    }

    /// Parse a `key=<int>` field out of a line (the value runs up to the next space). nil when absent or
    /// non-numeric. Shared by both readout ids.
    static func intField(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let token = line[r.upperBound...].prefix { $0 != " " }
        return Int(token)
    }
}

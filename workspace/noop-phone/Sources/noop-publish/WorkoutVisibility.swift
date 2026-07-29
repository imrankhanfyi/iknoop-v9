import Foundation

/// Faithful port of the workout read-time visibility rules the macOS app applies, so the viewer's
/// workout list matches the app's exactly.
///
/// SOURCE OF TRUTH: `Strand/Data/WorkoutSource.swift` (`classify`, `sportKey`, `richness`,
/// `detectedShadowsReal`, `dropDetectedShadows`, `preferred`, `collapseCrossSource`) and
/// `Repository.workoutRows` for the read-id set. If that file changes, change this in step —
/// the whole point of the port is that the two agree.
///
/// WHY A PORT AND NOT A REUSE: `WorkoutSource` lives in the app target (`Strand/`), not in
/// `Packages/`, so a standalone SPM executable cannot import it without dragging the app in.
/// The port is pinned by `verifyWorkoutVisibility()` in Checks.swift against the live store.
enum WorkoutClass: String {
    case whoop, apple, detected, manual, lifting, activityFile

    /// Order matters: "-noop" is tested BEFORE "whoop" because the computed id "my-whoop-noop" also
    /// contains "whoop". Note the deliberate quirk this reproduces: a bare source of "noop" has no
    /// "-noop" suffix and does not contain "whoop", so it falls through to `.apple` — which makes it
    /// a "real" (non-detected) row and therefore a valid shadow-killer. That is the app's behaviour.
    static func classify(_ source: String) -> WorkoutClass {
        let s = source.lowercased()
        if s.hasSuffix("-noop") { return .detected }
        if s == "manual" { return .manual }
        if s == "lifting" { return .lifting }
        if s == "activity-file" { return .activityFile }
        if s == "apple-health" || s == "apple_health" { return .apple }
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// Strap-native rows are the ones whose avg/max HR the app OVERRIDES from the strap's own
    /// hrSample trace (`Repository.reconcileWorkoutHrWithTrace` phase 3). Imported rows only get a
    /// nil avg filled and keep their own max.
    var isStrapNative: Bool { self == .manual || self == .detected }
}

struct RawWorkout {
    var deviceId: String
    var startTs: Int
    var endTs: Int
    var sport: String
    var source: String
    var durationS: Double?
    var energyKcal: Double?
    var avgHr: Int?
    var maxHr: Int?
    var strain: Double?
    var distanceM: Double?
    var zonesJSON: String?

    var cls: WorkoutClass { WorkoutClass.classify(source) }
}

enum WorkoutVisibility {
    /// `Repository.workoutRows` reads importedReadIds + computedReadIds + apple-health + lifting +
    /// activity-file. On this install the active strap id IS the canonical id, so those collapse to
    /// "my-whoop" and "my-whoop-noop". Note what is ABSENT: `my-whoop-manual` — legacy orphan rows
    /// no current writer produces and no read path includes. They must not appear in the viewer.
    static func readDeviceIds(activeStrapId: String, canonicalId: String) -> [String] {
        var ids = Set<String>([activeStrapId, canonicalId])
        ids.formUnion([activeStrapId + "-noop", canonicalId + "-noop"])
        ids.formUnion(["apple-health", "lifting", "activity-file"])
        return ids.sorted()
    }

    /// Normalised sport key for cross-source matching. Locale-stable by construction.
    static func sportKey(_ sport: String) -> String {
        editableSport(sport).lowercased().filter { !$0.isWhitespace }
    }

    static func editableSport(_ sport: String) -> String {
        sport == "detected" ? "Activity" : splitCamelCase(sport)
    }

    static func displaySport(_ sport: String) -> String {
        sport == "detected" ? "Activity" : splitCamelCase(sport)
    }

    private static func splitCamelCase(_ sport: String) -> String {
        if sport.isEmpty || sport.contains(" ") { return sport }
        var out = ""
        var prev: Character?
        for ch in sport {
            if let p = prev, ch.isUppercase, !p.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    /// How many "rich" captured signals a row carries — the duplicate tiebreak.
    static func richness(_ r: RawWorkout) -> Int {
        var n = 0
        if r.avgHr != nil { n += 1 }
        if r.maxHr != nil { n += 1 }
        if r.strain != nil { n += 1 }
        if let z = r.zonesJSON, !z.isEmpty { n += 1 }
        if let d = r.distanceM, d > 0 { n += 1 }
        if let k = r.energyKcal, k > 0 { n += 1 }
        return n
    }

    /// Windows overlap by MORE THAN HALF of the shorter session. The >50%-of-shorter test (rather
    /// than bare touching) keeps genuinely back-to-back sessions distinct.
    static func overlapsMajority(_ a: RawWorkout, _ b: RawWorkout) -> Bool {
        let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Drop every DETECTED row whose window shadows a REAL (non-detected) session, mirroring the
    /// engine's own rule so a live/manual session and its detected twin never both show.
    static func dropDetectedShadows(_ rows: [RawWorkout]) -> [RawWorkout] {
        let reals = rows.filter { $0.cls != .detected }
        guard !reals.isEmpty else { return rows }
        return rows.filter { row in
            guard row.cls == .detected else { return true }
            return !reals.contains { overlapsMajority(row, $0) }
        }
    }

    /// Of two same-activity rows, the one to KEEP: richer first, then non-import, then longer, then `a`.
    static func preferred(_ a: RawWorkout, _ b: RawWorkout) -> RawWorkout {
        let ra = richness(a), rb = richness(b)
        if ra != rb { return ra > rb ? a : b }
        let ia = a.cls == .apple, ib = b.cls == .apple
        if ia != ib { return ia ? b : a }
        let da = a.endTs - a.startTs, db = b.endTs - b.startTs
        if da != db { return da > db ? a : b }
        return a
    }

    /// Collapse cross-source duplicates of the same activity (same normalised sport + majority time
    /// overlap), keeping the richer row. Order-stable; bucketed by sport key so a cross-sport pair is
    /// never compared.
    static func collapseCrossSource(_ rows: [RawWorkout]) -> [RawWorkout] {
        var keptIndicesBySport: [String: [Int]] = [:]
        var kept: [RawWorkout?] = []
        for row in rows {
            let key = sportKey(row.sport)
            var replacedExisting = false
            for idx in keptIndicesBySport[key] ?? [] {
                guard let existing = kept[idx] else { continue }
                if overlapsMajority(existing, row) {
                    kept[idx] = preferred(existing, row)
                    replacedExisting = true
                    break
                }
            }
            if !replacedExisting {
                kept.append(row)
                keptIndicesBySport[key, default: []].append(kept.count - 1)
            }
        }
        return kept.compactMap { $0 }
    }

    /// The full read-time pipeline: dismissed filter → detected-shadow drop → cross-source collapse.
    /// `dismissedSpans` come from the UserDefaults key `workouts.dismissedDetected` (see Tombstones).
    static func visible(_ rows: [RawWorkout], dismissedSpans: [(start: Int, end: Int)]) -> [RawWorkout] {
        let afterDismiss = rows.filter { row in
            guard row.cls == .detected else { return true }
            return !dismissedSpans.contains { row.startTs < $0.end && $0.start < row.endTs }
        }
        return collapseCrossSource(dropDetectedShadows(afterDismiss))
    }
}

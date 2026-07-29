import Foundation

/// Extracts the summary tier the phone viewer renders, using the SAME read rules the macOS app
/// applies. Every rule here is a deliberate match to a specific app code path; the comment names it.
struct ReadModel {

    /// `Repository.whoopSource` — the canonical imported/measured device id.
    static let canonicalId = "my-whoop"
    /// `Repository.appleHealthSource`.
    static let appleHealthId = "apple-health"

    let db: ReadOnlyDatabase
    /// The ACTIVE strap id from the registry (`pairedDevice.status = 'active'`), not a raw BLE address.
    let activeStrapId: String
    var computedId: String { activeStrapId + "-noop" }
    var canonicalComputedId: String { Self.canonicalId + "-noop" }

    init(db: ReadOnlyDatabase) throws {
        self.db = db
        // Resolve the active strap through the registry, mirroring the app. Fall back to the canonical
        // id only if the registry has no active row (a store that has never paired).
        let active = try db.scalar(
            "SELECT id FROM pairedDevice WHERE status = 'active' ORDER BY lastSeenAt DESC LIMIT 1;"
        )?.text
        self.activeStrapId = active ?? Self.canonicalId
    }

    /// The union of computed ids to read for daily/sleep. On a single-device install this collapses to
    /// one id, byte-identical to the app's union (`Repository.computedReadIds`).
    var computedReadIds: [String] {
        computedId == canonicalComputedId ? [computedId] : [computedId, canonicalComputedId]
    }
    /// `Repository.importedReadIds`.
    var importedReadIds: [String] {
        activeStrapId == Self.canonicalId ? [activeStrapId] : [activeStrapId, Self.canonicalId]
    }

    private func inList(_ ids: [String]) -> String {
        "(" + ids.map(sqlQuote).joined(separator: ",") + ")"
    }

    // MARK: - Daily rows

    struct Day {
        var day: String
        var totalSleepMin: Double?
        var efficiency: Double?
        var deepMin: Double?
        var remMin: Double?
        var lightMin: Double?
        var disturbances: Int?
        var restingHr: Int?
        var avgHrv: Double?
        var recovery: Double?
        var strain: Double?
        var exerciseCount: Int?
        var spo2Pct: Double?
        var skinTempDevC: Double?
        var respRateBpm: Double?
        var steps: Int?
        var activeKcalEst: Double?
        var sleepPerformance: Double?
    }

    /// `Repository.refresh` builds `days` as mergeDaily(imported, computed) then fills steps-only from
    /// `activity-file`. It reads `apple-health` too, but that list feeds ONLY the vitals/freshness
    /// paths — it never reaches `days`. So we must NOT union apple-health here: doing so would add
    /// 4,214 rows and ~3,000 nights of sleep back to 2016 that Today / Trends / Sleep never show.
    ///
    /// `mergeDaily` seeds from `computed`, then each imported row overwrites field-by-field with the
    /// computed row filling nils ("imports win field-by-field"). On this install there are zero
    /// imported (`my-whoop`) dailyMetric rows and zero activity-file rows, so the merge reduces to
    /// the computed rows — but the merge is implemented anyway so a future import doesn't silently
    /// diverge.
    func days() throws -> [Day] {
        let cols = """
        day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances, restingHr, avgHrv,
        recovery, strain, exerciseCount, spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst
        """
        func load(_ ids: [String]) throws -> [String: Day] {
            var out: [String: Day] = [:]
            try db.query("SELECT \(cols) FROM dailyMetric WHERE deviceId IN \(inList(ids)) ORDER BY day;") { r in
                guard let day = r.text(0) else { return }
                let d = Day(day: day,
                            totalSleepMin: r.double(1), efficiency: r.double(2),
                            deepMin: r.double(3), remMin: r.double(4), lightMin: r.double(5),
                            disturbances: r.int(6), restingHr: r.int(7), avgHrv: r.double(8),
                            recovery: r.double(9), strain: r.double(10), exerciseCount: r.int(11),
                            spo2Pct: r.double(12), skinTempDevC: r.double(13), respRateBpm: r.double(14),
                            steps: r.int(15), activeKcalEst: r.double(16),
                            sleepPerformance: nil)
                // A later row for the same day (possible only across a multi-id union) wins, matching
                // the app's "active strap first, per-day dedup lets the live row win" ordering.
                out[day] = d
            }
            return out
        }

        let computed = try load(computedReadIds)
        let imported = try load(importedReadIds)

        // mergeDaily: seed from computed, imported wins field-by-field, computed fills nils.
        var merged = computed
        for (day, imp) in imported {
            guard let base = merged[day] else { merged[day] = imp; continue }
            merged[day] = Day(day: day,
                              totalSleepMin: imp.totalSleepMin ?? base.totalSleepMin,
                              efficiency: imp.efficiency ?? base.efficiency,
                              deepMin: imp.deepMin ?? base.deepMin,
                              remMin: imp.remMin ?? base.remMin,
                              lightMin: imp.lightMin ?? base.lightMin,
                              disturbances: imp.disturbances ?? base.disturbances,
                              restingHr: imp.restingHr ?? base.restingHr,
                              avgHrv: imp.avgHrv ?? base.avgHrv,
                              recovery: imp.recovery ?? base.recovery,
                              strain: imp.strain ?? base.strain,
                              exerciseCount: imp.exerciseCount ?? base.exerciseCount,
                              spo2Pct: imp.spo2Pct ?? base.spo2Pct,
                              skinTempDevC: imp.skinTempDevC ?? base.skinTempDevC,
                              respRateBpm: imp.respRateBpm ?? base.respRateBpm,
                              steps: imp.steps ?? base.steps,
                              activeKcalEst: imp.activeKcalEst ?? base.activeKcalEst,
                              sleepPerformance: nil)
        }

        // Steps-only fill from imported activity files (`Repository.mergeActivityFileSteps`).
        try db.query("SELECT day, steps FROM dailyMetric WHERE deviceId = 'activity-file';") { r in
            guard let day = r.text(0), let steps = r.int(1), var d = merged[day], d.steps == nil else { return }
            d.steps = steps
            merged[day] = d
        }

        // Sleep performance: prefer the persisted series (what TodayView reads), else compute the
        // same composite SleepView computes. Both agree — asserted in Checks.
        let stored = try storedSleepPerformance()
        var out = merged.values.map { d -> Day in
            var d = d
            d.sleepPerformance = stored[d.day]
                ?? RestComposite.composite(totalSleepMin: d.totalSleepMin, efficiency: d.efficiency,
                                           deepMin: d.deepMin, remMin: d.remMin)
            return d
        }
        out.sort { $0.day < $1.day }
        return out
    }

    /// `metricSeries` rows for the computed source, keyed by day.
    func storedSleepPerformance() throws -> [String: Double] {
        var out: [String: Double] = [:]
        try db.query("""
        SELECT day, value FROM metricSeries
        WHERE deviceId IN \(inList(computedReadIds)) AND key = 'sleep_performance';
        """) { r in
            if let d = r.text(0), let v = r.double(1) { out[d] = v }
        }
        return out
    }

    /// Every NOOP-native `metricSeries` key, for the Trends screen. Deliberately excludes
    /// `apple-health` keys: `deep_min`/`rem_min`/`core_min` are 0.0 across ~3,000 days there, so
    /// plotting them would draw a flat line that is simply false.
    func series() throws -> [String: [(day: String, value: Double)]] {
        var out: [String: [(day: String, value: Double)]] = [:]
        try db.query("""
        SELECT key, day, value FROM metricSeries
        WHERE deviceId IN \(inList(computedReadIds)) ORDER BY key, day;
        """) { r in
            guard let k = r.text(0), let d = r.text(1), let v = r.double(2) else { return }
            out[k, default: []].append((day: d, value: v))
        }
        return out
    }

    // MARK: - Sleep sessions

    struct Sleep {
        var startTs: Int
        var effectiveStartTs: Int
        var endTs: Int
        var userEdited: Bool
        var efficiency: Double?
        var restingHr: Int?
        var avgHrv: Double?
        var stagesJSON: String?
    }

    /// `Repository.allSleepSessions`: union imported + computed, dedup identical start-end keys, and
    /// drop a computed block on any wake-day an imported block already covers.
    ///
    /// `effectiveStartTs` is `startTsAdjusted ?? startTs` (`MetricsCache.swift:30`). This is
    /// load-bearing: on this store one night (2026-07-18) carries a 43-minute onset correction, and
    /// reading raw `startTs` would disagree with every app screen. Note `NoopLocalAccess`'s
    /// `SleepSessionRow` deliberately omits the column, so it must NOT be reused here.
    func sleeps(timeZone: TimeZone) throws -> [Sleep] {
        func load(_ ids: [String]) throws -> [Sleep] {
            var rows: [Sleep] = []
            try db.query("""
            SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited, startTsAdjusted
            FROM sleepSession WHERE deviceId IN \(inList(ids)) ORDER BY startTs;
            """) { r in
                guard let start = r.int(0), let end = r.int(1) else { return }
                rows.append(Sleep(startTs: start,
                                  effectiveStartTs: r.int(7) ?? start,
                                  endTs: end,
                                  userEdited: r.bool(6),
                                  efficiency: r.double(2),
                                  restingHr: r.int(3),
                                  avgHrv: r.double(4),
                                  stagesJSON: r.text(5)))
            }
            // dedupBlocks: drop repeats of the same "start-end" key.
            var seen = Set<String>()
            return rows.filter { seen.insert("\($0.startTs)-\($0.endTs)").inserted }
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        func wakeDay(_ s: Sleep) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }

        let imported = try load(importedReadIds)
        let computed = try load(computedReadIds)
        let importedDays = Set(imported.map(wakeDay))
        let computedKept = computed.filter { !importedDays.contains(wakeDay($0)) }
        return (imported + computedKept).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    // MARK: - Workouts

    /// Raw rows for every device id the app reads. Note `my-whoop-manual` is excluded by construction
    /// — it is not in the read-id set — matching the app, which never shows those legacy rows.
    func rawWorkouts() throws -> [RawWorkout] {
        let ids = WorkoutVisibility.readDeviceIds(activeStrapId: activeStrapId, canonicalId: Self.canonicalId)
        var rows: [RawWorkout] = []
        try db.query("""
        SELECT deviceId, startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
               strain, distanceM, zonesJSON
        FROM workout WHERE deviceId IN \(inList(ids)) ORDER BY startTs;
        """) { r in
            guard let dev = r.text(0), let s = r.int(1), let e = r.int(2),
                  let sport = r.text(3), let source = r.text(4) else { return }
            rows.append(RawWorkout(deviceId: dev, startTs: s, endTs: e, sport: sport, source: source,
                                   durationS: r.double(5), energyKcal: r.double(6),
                                   avgHr: r.int(7), maxHr: r.int(8), strain: r.double(9),
                                   distanceM: r.double(10), zonesJSON: r.text(11)))
        }
        return rows
    }

    /// `Repository.workoutHrDeviceId` (#510): a DETECTED row's `source` IS its computed strap id, so
    /// strip the "-noop" suffix to read HR under the raw strap. Manual/imported rows reconcile against
    /// the active strap.
    func hrDeviceId(forSource source: String) -> String {
        source.lowercased().hasSuffix("-noop") ? String(source.dropLast(5)) : activeStrapId
    }

    /// Mean and peak HR over a window, from the strap's own `hrSample` trace.
    ///
    /// WHY THIS EXISTS: `Repository.reconcileWorkoutHrWithTrace` recomputes avg/max HR at RENDER time
    /// and never persists it. For a strap-native row the trace IS the source — both avg and max are
    /// overridden. So a viewer that ships the stored `avgHr`/`maxHr` columns disagrees with the app on
    /// every live/detected session. We precompute here, where `hrSample` is available; the phone only
    /// ever sees the reconciled numbers.
    ///
    /// Matches the app's gate: at least `minSamples` (60) readings, at most `limit` (8000) rows, and
    /// the same PPG-derived fallback UNION `WhoopStore.hrSamples` uses (`Reads.swift:33`) — a
    /// `ppgHrSample` row is included only when no `hrSample` exists at that exact ts. `ppgHrSample`
    /// is empty on this store today, so the union is currently inert; it is mirrored anyway so the
    /// numbers cannot silently diverge once PPG HR is populated.
    ///
    /// The reduction is byte-identical to `Repository.reduceWorkoutHr`: rounded arithmetic mean, and
    /// the max.
    func reconciledHr(deviceId: String, from: Int, to: Int,
                      minSamples: Int = 60, limit: Int = 8000) throws -> (avg: Int, peak: Int)? {
        let q = sqlQuote(deviceId)
        var values: [Int] = []
        values.reserveCapacity(min(limit, 8000))
        try db.query("""
        SELECT bpm FROM (
            SELECT ts, bpm FROM hrSample
            WHERE deviceId = \(q) AND ts >= \(from) AND ts <= \(to)
            UNION ALL
            SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) AS bpm FROM ppgHrSample p
            WHERE p.deviceId = \(q) AND p.ts >= \(from) AND p.ts <= \(to)
              AND NOT EXISTS (
                SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
        )
        ORDER BY ts ASC LIMIT \(limit);
        """) { r in
            if let v = r.int(0) { values.append(v) }
        }
        guard values.count >= minSamples else { return nil }
        var sum = 0, peak = 0
        for v in values { sum += v; if v > peak { peak = v } }
        return (avg: Int((Double(sum) / Double(values.count)).rounded()), peak: peak)
    }
}

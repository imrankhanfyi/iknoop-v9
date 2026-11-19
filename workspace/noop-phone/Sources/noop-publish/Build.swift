import Foundation

/// The plaintext payload the viewer renders, plus JSON serialization and file output.
struct PayloadDoc {
    var generatedAt: Int
    var dataMaxTs: Int
    var timeZone: String
    var days: [ReadModel.Day]
    var sleeps: [ReadModel.Sleep]
    var workouts: [BuiltWorkout]
    var series: [String: [(day: String, value: Double)]]
    /// Phase 2 (additive): checklist items + answers for the 21-day window, and the last 500 inbox
    /// entry ids the Mac has committed (the phone clears a pending entry once its id appears here).
    var lifestyleItems: [LifestyleItem] = []
    var lifestyleAnswers: [String: [String: Bool]] = [:]
    var lifestyleEffects: [[String: Any]] = []
    var ingestedEntryIds: [String] = []
    var orphanOverrides = 0
}

struct BuiltWorkout {
    var startTs: Int
    var endTs: Int
    var sport: String
    var displaySport: String
    var sourceClass: String
    var durationS: Double?
    var energyKcal: Double?
    var avgHr: Int?
    var maxHr: Int?
    var strain: Double?
    var distanceM: Double?
    var hrReconciled: Bool
    /// Additive v2 field: ~5 s bucket integer-mean bpm from `startTs`; nil entries are gaps.
    var hrTrace: [Int?]? = nil
    /// Raw store `source` (the HR device id derives from it).
    var source: String = ""
    /// Phase 2: a phone-side override was applied. `orig` is the span/sport the phone echoes on re-edit.
    var edited: Bool = false
    var orig: (startTs: Int, endTs: Int, sport: String)? = nil
}

enum Build {

    static func payload(model: ReadModel, timeZone: TimeZone, dataMaxTs: Int,
                        side: SideStore? = nil, stateDir: URL? = nil, now: Date = Date()) throws -> PayloadDoc {
        let tombstones = Tombstones.load()

        var days = try model.days()
        let allSleeps = try model.sleeps(timeZone: timeZone)
        // Sleep dismissals are stored spans; a session overlapping one was deleted by the user and the
        // engine may have re-detected it. Half-open overlap test, matching the app.
        let sleeps = allSleeps.filter { s in
            !tombstones.dismissedSleepSpans.contains { s.startTs < $0.end && $0.start < s.endTs }
        }

        var visible = WorkoutVisibility.visible(try model.rawWorkouts(),
                                                dismissedSpans: tombstones.dismissedWorkoutSpans)

        // Phone-side workout overrides, applied BEFORE the HR reconcile so an edited span re-derives
        // avg/max HR and the trace from the strap's own samples.
        var orphanOverrides = 0
        if let side {
            (visible, orphanOverrides) = Overrides.apply(try side.overrides(), to: visible)
        }
        let profile = WorkoutCalories.loadProfile()

        // Reconcile HR exactly as `Repository.reconcileWorkoutHrWithTrace` does.
        //
        // ORDER IS LOAD-BEARING. The app sorts NEWEST-FIRST before reconciling
        // (`Repository.workoutRows`: `let visible = deduped.sorted { $0.startTs > $1.startTs }`, then
        // `reconcileWorkoutHrWithTrace(visible, ...)`), and the reconcile spends its `cap` budget of
        // 300 rows in that order. Iterating oldest-first instead burns the entire budget on the 834
        // imported Apple rows — every one of which has `avgHr IS NULL` and is therefore eligible —
        // so the recent strap sessions, the only rows whose HR the app actually overrides, never get
        // reconciled at all. Sort descending here, then sort ascending for output.
        var budget = 300
        var workouts: [BuiltWorkout] = []
        for row in visible.sorted(by: { $0.startTs > $1.startTs }) {
            var avg = row.avgHr
            var max = row.maxHr
            var reconciled = false
            let strapNative = row.cls.isStrapNative
            let isEdited = row.original != nil
            if isEdited {
                // An edited span's stored HR describes the OLD span: take both from the strap trace
                // (outside the render budget — edits are few), and null them when the trace is too thin.
                avg = nil; max = nil
            }
            let eligible = row.endTs > row.startTs && (isEdited || (budget > 0 && (strapNative || row.avgHr == nil)))
            if eligible {
                if !isEdited { budget -= 1 }
                let hrId = model.hrDeviceId(forSource: row.source)
                if let r = try model.reconciledHr(deviceId: hrId, from: row.startTs, to: row.endTs) {
                    // Strap-native: the trace IS the source, override both. Imported: fill a nil avg
                    // only and keep the imported max.
                    avg = r.avg
                    max = (strapNative || isEdited) ? r.peak : (row.maxHr ?? r.peak)
                    reconciled = true
                }
            }
            // Energy for an edited span: re-derived ONLY for detected / manual rows with the ported
            // estimator and the engine's own inputs; imported rows and a missing profile give nil.
            // Never a guess. (Strain no longer describes the edited span, so it is nil too.)
            var kcal = row.energyKcal
            if isEdited {
                kcal = nil
                if let profile {
                    switch row.cls {
                    case .detected:
                        kcal = try model.detectedBoutKcal(source: row.source, start: row.startTs, end: row.endTs,
                                                          timeZone: timeZone, profile: profile)
                    case .manual:
                        kcal = try model.manualBoutKcal(source: row.source, start: row.startTs, end: row.endTs,
                                                        profile: profile)
                    default: break
                    }
                }
            }
            workouts.append(BuiltWorkout(
                startTs: row.startTs, endTs: row.endTs,
                sport: row.sport,
                displaySport: WorkoutVisibility.displaySport(row.sport),
                sourceClass: row.cls.rawValue,
                durationS: row.durationS, energyKcal: kcal,
                avgHr: avg, maxHr: max, strain: isEdited ? nil : row.strain, distanceM: row.distanceM,
                hrReconciled: reconciled,
                source: row.source, edited: isEdited, orig: row.original))
        }
        workouts.sort { $0.startTs < $1.startTs }

        // v2 additions (additive only). Window = 21 days back from the offload frontier.
        let windowStart = dataMaxTs - 21 * 86400
        for i in workouts.indices where workouts[i].endTs > workouts[i].startTs
                                       && workouts[i].endTs >= windowStart {
            let hrId = model.hrDeviceId(forSource: workouts[i].source)
            workouts[i].hrTrace = try model.hrTrace(deviceId: hrId, from: workouts[i].startTs,
                                                    to: workouts[i].endTs)
        }

        // Whole-day mean HR, bucketed by LOCAL day in `timeZone`, for the trailing 30 daily rows.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        for i in days.indices.suffix(30) {
            let parts = days[i].day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let start = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            // Only COMPLETE days: the day must have ended before the offload frontier, and ≥80% of its
            // seconds must carry a sample (hrSample is ~1 Hz; full days read ~85k rows). Otherwise a partial
            // day — today's few live hours, or the frontier day — becomes a confident, wrong headline.
            guard Int(end.timeIntervalSince1970) <= dataMaxTs else { continue }
            days[i].meanHr = try model.meanHr(deviceId: model.activeStrapId,
                                              from: Int(start.timeIntervalSince1970),
                                              to: Int(end.timeIntervalSince1970),
                                              minSamples: Int(0.8 * end.timeIntervalSince(start)))
        }

        var doc = PayloadDoc(generatedAt: Int(Date().timeIntervalSince1970),
                          dataMaxTs: dataMaxTs,
                          timeZone: timeZone.identifier,
                          days: days, sleeps: sleeps, workouts: workouts,
                          series: try model.series())
        doc.orphanOverrides = orphanOverrides
        if let side, let stateDir {
            let l = try Lifestyle.build(model: model, side: side, stateDir: stateDir, timeZone: timeZone, now: now)
            doc.lifestyleItems = l.items
            doc.lifestyleAnswers = l.answers
            doc.lifestyleEffects = try Effects.build(model: model, side: side, items: l.items)
            doc.ingestedEntryIds = try side.lastIngestedIds(500)
        }
        return doc
    }

    /// JSON with nulls PRESENT (never omitted). The viewer must distinguish "no data" from zero — on
    /// this store `spo2Pct` and `skinTempDevC` are null on every row and `steps` is always null, and
    /// rendering any of those as 0 would be a fabrication.
    static func serialize(_ p: PayloadDoc) throws -> Data {
        func num(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
        func num(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }

        let days: [[String: Any]] = p.days.map { d in
            [
                "day": d.day,
                "totalSleepMin": num(d.totalSleepMin), "efficiency": num(d.efficiency),
                "deepMin": num(d.deepMin), "remMin": num(d.remMin), "lightMin": num(d.lightMin),
                "disturbances": num(d.disturbances), "restingHr": num(d.restingHr),
                "avgHrv": num(d.avgHrv), "recovery": num(d.recovery), "strain": num(d.strain),
                "exerciseCount": num(d.exerciseCount), "spo2Pct": num(d.spo2Pct),
                "skinTempDevC": num(d.skinTempDevC), "respRateBpm": num(d.respRateBpm),
                "steps": num(d.steps), "activeKcalEst": num(d.activeKcalEst),
                "sleepPerformance": num(d.sleepPerformance), "meanHr": num(d.meanHr),
            ]
        }

        let sleeps: [[String: Any]] = p.sleeps.map { s in
            // stagesJSON is stored as either an array of {start,end,stage} segments (strap-staged, the
            // only shape present here) or a dict of stage->minutes (import path). Parse the array shape
            // and pass it through as structured segments; anything else becomes null so the viewer shows
            // an honest empty hypnogram rather than a fabricated one.
            var stages: Any = NSNull()
            if let raw = s.stagesJSON, let data = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let arr = parsed as? [[String: Any]] {
                stages = arr.compactMap { seg -> [String: Any]? in
                    guard let st = seg["start"] as? Int ?? (seg["start"] as? Double).map(Int.init),
                          let en = seg["end"] as? Int ?? (seg["end"] as? Double).map(Int.init),
                          let stage = seg["stage"] as? String else { return nil }
                    return ["start": st, "end": en, "stage": stage]
                }
            }
            return [
                "startTs": s.startTs, "effectiveStartTs": s.effectiveStartTs, "endTs": s.endTs,
                "userEdited": s.userEdited, "efficiency": num(s.efficiency),
                "restingHr": num(s.restingHr), "avgHrv": num(s.avgHrv), "stages": stages,
            ]
        }

        let workouts: [[String: Any]] = p.workouts.map { w in
            [
                "startTs": w.startTs, "endTs": w.endTs,
                "sport": w.sport, "displaySport": w.displaySport, "sourceClass": w.sourceClass,
                "durationS": num(w.durationS), "energyKcal": num(w.energyKcal),
                "avgHr": num(w.avgHr), "maxHr": num(w.maxHr), "strain": num(w.strain),
                "distanceM": num(w.distanceM), "hrReconciled": w.hrReconciled,
                "hrTrace": w.hrTrace.map { t in t.map { $0.map { $0 as Any } ?? NSNull() } as Any } ?? NSNull(),
            ].merging(w.edited ? [
                "edited": true as Any,
                "orig": ["startTs": w.orig?.startTs ?? w.startTs, "endTs": w.orig?.endTs ?? w.endTs,
                         "sport": w.orig?.sport ?? w.sport] as Any,
            ] : [:]) { a, _ in a }
        }

        var series: [String: [[String: Any]]] = [:]
        for (k, pts) in p.series {
            series[k] = pts.map { ["day": $0.day, "value": $0.value] }
        }

        let root: [String: Any] = [
            "v": Payload.formatVersion,
            "generatedAt": p.generatedAt, "dataMaxTs": p.dataMaxTs, "tz": p.timeZone,
            "days": days, "sleeps": sleeps, "workouts": workouts, "series": series,
            "lifestyle": ["items": p.lifestyleItems.map { ["id": $0.id, "label": $0.label] },
                          "answers": p.lifestyleAnswers,
                          "effects": p.lifestyleEffects] as [String: Any],
            "ingestedEntryIds": p.ingestedEntryIds,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Write the envelope. `generatedAt` / `dataMaxTs` / `tz` are deliberately OUTSIDE the ciphertext so
    /// the viewer can warn about stale data before a passphrase is entered; they leak only timestamps.
    static func write(sealed: Payload.Sealed, payload: PayloadDoc, plaintext: Data,
                      outDir: URL, plaintextOut: URL?) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let envelope: [String: Any] = [
            "v": Payload.formatVersion,
            "generatedAt": payload.generatedAt,
            "dataMaxTs": payload.dataMaxTs,
            "tz": payload.timeZone,
            "kdf": ["alg": Payload.kdfAlg, "saltB64": sealed.saltB64],
            "cipher": ["alg": "AES-256-GCM", "nonceB64": sealed.nonceB64, "tagBits": 128],
            "aad": sealed.aad,
            "ctB64": sealed.ciphertextB64,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])

        // Write to a temp file then rename: an in-place overwrite is not atomic, and a phone fetching
        // mid-write would get a short file whose GCM tag then fails — surfacing to the user as the
        // actively misleading "wrong passphrase".
        let dest = outDir.appendingPathComponent("noop-data.json")
        let tmp = outDir.appendingPathComponent("noop-data.json.tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmp)

        if let plaintextOut {
            try plaintext.write(to: plaintextOut, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: plaintextOut.path)
            FileHandle.standardError.write(Data("""
            warning: wrote UNENCRYPTED biometrics to \(plaintextOut.path) — delete it when done, and
                     never let it reach a git remote.\n
            """.utf8))
        }
    }
}

/// Applies phone-side workout overrides to the visible rows.
enum Overrides {
    /// Match each override to a visible workout by time overlap: the largest overlap with the override's
    /// ORIGINAL span, and at least 50% of that span. Returns the rows with overrides applied and the
    /// number of orphan overrides (no match). When several overrides match one row, the newest wins.
    static func apply(_ overrides: [WorkoutOverride], to rows: [RawWorkout]) -> ([RawWorkout], Int) {
        var chosen: [Int: WorkoutOverride] = [:]
        var orphans = 0
        for o in overrides {
            let span = o.origEnd - o.origStart
            var best: (idx: Int, overlap: Int)?
            for (i, r) in rows.enumerated() where r.original == nil {
                let ov = min(r.endTs, o.origEnd) - max(r.startTs, o.origStart)
                guard ov > 0, Double(ov) >= 0.5 * Double(span) else { continue }
                if best == nil || ov > best!.overlap { best = (i, ov) }
            }
            guard let b = best else { orphans += 1; continue }
            if let cur = chosen[b.idx], cur.enteredAt >= o.enteredAt { continue }
            chosen[b.idx] = o
        }
        var out: [RawWorkout] = []
        for (i, r) in rows.enumerated() {
            guard let o = chosen[i] else { out.append(r); continue }
            if o.deleted { continue }
            var e = r
            e.original = (r.startTs, r.endTs, r.sport)
            if let s = o.sport { e.sport = s }
            if let s = o.startTs, let en = o.endTs { e.startTs = s; e.endTs = en }
            e.durationS = Double(e.endTs - e.startTs)
            out.append(e)
        }
        return (out, orphans)
    }
}

enum Lifestyle {
    struct Result { var items: [LifestyleItem]; var answers: [String: [String: Bool]] }

    /// Items + answers for the 21-day window ending LOCAL TOMORROW (a "Tonight" answer is filed under
    /// tomorrow's morning and must survive the round trip). Legacy NOOP `journal` rows (mapped through
    /// each item's `legacy` question) are the base; side-store check-ins win, and a cleared check-in
    /// removes a legacy answer. Day key = the morning the answer leads into.
    static func build(model: ReadModel, side: SideStore, stateDir: URL, timeZone: TimeZone, now: Date) throws -> Result {
        let items = LifestyleItems.load(stateDir: stateDir)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let f = DateFormatter(); f.calendar = cal; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let from = f.string(from: cal.date(byAdding: .day, value: -20, to: tomorrow)!)
        let to = f.string(from: tomorrow)
        let answers = try merged(model: model, side: side, items: items, from: from, to: to)
        return Result(items: items, answers: answers)
    }

    /// Legacy journal (mapped via `legacy`) as the base, side-store check-ins win, cleared check-ins
    /// remove. `from`/`to` are inclusive "yyyy-MM-dd" morning keys. Used for the 21-day checklist window
    /// and, with the full range, for Effects.
    static func merged(model: ReadModel, side: SideStore, items: [LifestyleItem],
                       from: String, to: String) throws -> [String: [String: Bool]] {
        var answers: [String: [String: Bool]] = [:]
        var byQuestion: [String: String] = [:]
        for it in items { if let q = it.legacy { byQuestion[q] = it.id } }
        if !byQuestion.isEmpty {
            try model.db.query("SELECT day, question, answeredYes FROM journal WHERE day >= \(sqlQuote(from)) AND day <= \(sqlQuote(to));") { r in
                guard let d = r.text(0), let q = r.text(1), let id = byQuestion[q], let y = r.int(2) else { return }
                answers[d, default: [:]][id] = y != 0
            }
        }
        let s = try side.checkins(fromDay: from)
        for (d, m) in s.answers where d <= to { for (i, v) in m { answers[d, default: [:]][i] = v } }
        for (d, i) in s.cleared { answers[d]?[i] = nil }
        return answers.filter { !$0.value.isEmpty }
    }
}

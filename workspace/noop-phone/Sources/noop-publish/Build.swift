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
}

enum Build {

    static func payload(model: ReadModel, timeZone: TimeZone, dataMaxTs: Int) throws -> PayloadDoc {
        let tombstones = Tombstones.load()

        let days = try model.days()
        let allSleeps = try model.sleeps(timeZone: timeZone)
        // Sleep dismissals are stored spans; a session overlapping one was deleted by the user and the
        // engine may have re-detected it. Half-open overlap test, matching the app.
        let sleeps = allSleeps.filter { s in
            !tombstones.dismissedSleepSpans.contains { s.startTs < $0.end && $0.start < s.endTs }
        }

        let visible = WorkoutVisibility.visible(try model.rawWorkouts(),
                                                dismissedSpans: tombstones.dismissedWorkoutSpans)

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
            let eligible = row.endTs > row.startTs && budget > 0 && (strapNative || row.avgHr == nil)
            if eligible {
                budget -= 1
                let hrId = model.hrDeviceId(forSource: row.source)
                if let r = try model.reconciledHr(deviceId: hrId, from: row.startTs, to: row.endTs) {
                    // Strap-native: the trace IS the source, override both. Imported: fill a nil avg
                    // only and keep the imported max.
                    avg = r.avg
                    max = strapNative ? r.peak : (row.maxHr ?? r.peak)
                    reconciled = true
                }
            }
            workouts.append(BuiltWorkout(
                startTs: row.startTs, endTs: row.endTs,
                sport: row.sport,
                displaySport: WorkoutVisibility.displaySport(row.sport),
                sourceClass: row.cls.rawValue,
                durationS: row.durationS, energyKcal: row.energyKcal,
                avgHr: avg, maxHr: max, strain: row.strain, distanceM: row.distanceM,
                hrReconciled: reconciled))
        }
        workouts.sort { $0.startTs < $1.startTs }

        return PayloadDoc(generatedAt: Int(Date().timeIntervalSince1970),
                          dataMaxTs: dataMaxTs,
                          timeZone: timeZone.identifier,
                          days: days, sleeps: sleeps, workouts: workouts,
                          series: try model.series())
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
                "sleepPerformance": num(d.sleepPerformance),
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
            ]
        }

        var series: [String: [[String: Any]]] = [:]
        for (k, pts) in p.series {
            series[k] = pts.map { ["day": $0.day, "value": $0.value] }
        }

        let root: [String: Any] = [
            "v": Payload.formatVersion,
            "generatedAt": p.generatedAt, "dataMaxTs": p.dataMaxTs, "tz": p.timeZone,
            "days": days, "sleeps": sleeps, "workouts": workouts, "series": series,
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
            "kdf": ["alg": "PBKDF2-HMAC-SHA256",
                    "iterations": Payload.pbkdf2Iterations,
                    "saltB64": sealed.saltB64],
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

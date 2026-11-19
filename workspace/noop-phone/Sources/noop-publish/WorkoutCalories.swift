import Foundation

/// Port of `Calories.estimateBoutCalories` (Packages/StrandAnalytics/.../WorkoutDetector.swift, the
/// Keytel 2005 active-rate / Harris-Benedict resting-rate bout estimator) plus the helpers it needs
/// (`resolveCoeffs`, `restingKcalPerS`, `activeKcalPerS`, constants).
///
/// WHY A PORT: StrandAnalytics depends on WhoopStore -> GRDB; see the dependency decision in the v2 spec.
/// It is used ONLY to re-derive kcal for a workout the user edited on the phone. `--calorie-check`
/// compares it against the stored kcal of unedited detected workouts; if it does not reproduce them,
/// edited workouts ship `energyKcal: null` rather than a guess.
enum WorkoutCalories {
    struct Profile {
        var weightKg: Double, heightCm: Double, age: Double, sex: String
        /// `profile.hrMaxOverride` (0 = none).
        var hrMaxOverride: Double
    }

    struct Coeffs {
        let restingAlpha, restingWeight, restingHeight, restingAge: Double
        let workoutHR, workoutWeight, workoutAge, workoutAlpha: Double
    }
    static let male = Coeffs(restingAlpha: 88.362, restingWeight: 13.397, restingHeight: 479.9,
                             restingAge: 5.677, workoutHR: 0.6309, workoutWeight: 0.1988,
                             workoutAge: 0.2017, workoutAlpha: -55.0969)
    static let female = Coeffs(restingAlpha: 447.593, restingWeight: 9.247, restingHeight: 309.8,
                               restingAge: 4.33, workoutHR: 0.4472, workoutWeight: -0.1263,
                               workoutAge: 0.0740, workoutAlpha: -20.4022)
    static let nonbinary = Coeffs(restingAlpha: 267.9775, restingWeight: 11.322, restingHeight: 394.85,
                                  restingAge: 5.0035, workoutHR: 0.53905, workoutWeight: 0.03625,
                                  workoutAge: 0.13785, workoutAlpha: -37.74955)
    static let activeHRRFraction = 0.30
    static let workoutDivisor = 251.04
    static let mergeGapS = 150.0
    // StrainScorer / WorkoutDetector constants used by the detected-bout inputs.
    static let hrmaxMinSamples = 600
    static let hrmaxPercentile = 99.5
    static let restingPercentile = 10.0

    static func resolveCoeffs(_ sex: String) -> Coeffs {
        switch sex.lowercased() {
        case "male": return male
        case "female": return female
        default: return nonbinary
        }
    }
    static func restingKcalPerS(_ c: Coeffs, weightKg: Double, heightCm: Double, age: Double) -> Double {
        let bmr = c.restingAlpha + c.restingWeight * weightKg + c.restingHeight * (heightCm / 100.0) - c.restingAge * age
        return max(0.0, bmr) / 86_400.0
    }
    static func activeKcalPerS(_ c: Coeffs, hr: Double, hrmax: Double, weightKg: Double, age: Double) -> Double {
        let eeKjMin = c.workoutHR * min(hr, hrmax) + c.workoutWeight * weightKg + c.workoutAge * age + c.workoutAlpha
        return max(0.0, eeKjMin) / workoutDivisor
    }

    /// kcal for a bout. `samples` are (ts, bpm) pairs.
    static func estimateBoutCalories(_ samples: [(ts: Int, bpm: Int)], profile: Profile,
                                     hrmax: Double?, restingHR: Double?) -> Double {
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let c = resolveCoeffs(profile.sex)
        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        let activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)
        let restingRate = restingKcalPerS(c, weightKg: weightKg, heightCm: heightCm, age: age)
        let ordered = samples.sorted { $0.ts < $1.ts }
        var total = 0.0
        for i in ordered.indices {
            let bpm = Double(ordered[i].bpm)
            let dur: Double
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - ordered[i].ts)
                dur = gap > 0 ? min(gap, mergeGapS) : 1.0
            } else { dur = 1.0 }
            total += bpm < activeThreshold ? restingRate * dur
                : activeKcalPerS(c, hr: bpm, hrmax: effHRmax, weightKg: weightKg, age: age) * dur
        }
        return total
    }

    /// `StrainScorer.percentile` (linear interpolation) as used by `estimateHRmax`.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = p / 100.0 * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// `StrainScorer.estimateHRmax(day HR, age)`.
    static func estimateHRmax(_ hr: [Double], age: Double) -> Double {
        let tanaka = 208.0 - 0.7 * age
        if hr.count >= hrmaxMinSamples {
            let obs = percentile(hr.sorted(), hrmaxPercentile)
            return obs >= tanaka ? obs : tanaka
        }
        return tanaka
    }

    /// `WorkoutDetector.deriveRestingHR`: nearest-rank 10th percentile.
    static func derivedResting(_ hr: [Double]) -> Double? {
        guard !hr.isEmpty else { return nil }
        let s = hr.sorted()
        let rank = max(1, Int((restingPercentile / 100.0 * Double(s.count)).rounded(.up)))
        return s[rank - 1]
    }

    /// Profile from the sandboxed container's preferences plist (same route as `Tombstones.load`).
    /// Keys: Strand/Data/Profile.swift `K`. Returns nil when the plist has no usable profile.
    static func loadProfile(bundleId: String = "com.noopapp.noop") -> Profile? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Containers/\(bundleId)/Data/Library/Preferences/\(bundleId).plist"),
            home.appendingPathComponent("Library/Preferences/\(bundleId).plist"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let d = plist as? [String: Any] else { continue }
            func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
            guard let weight = num("profile.weightKg"), let height = num("profile.heightCm"),
                  let sex = d["profile.sex"] as? String else { continue }
            let age: Double
            if let dob = d["profile.dateOfBirth"] as? Date {
                age = Double(Calendar.current.dateComponents([.year], from: dob, to: Date()).year ?? 0)
            } else if let a = num("profile.age") { age = a } else { continue }
            return Profile(weightKg: weight, heightCm: height, age: age, sex: sex,
                           hrMaxOverride: num("profile.hrMaxOverride") ?? 0)
        }
        return nil
    }
}

extension ReadModel {
    /// Uncapped HR window (hrSample + the PPG fallback union), ts ASC.
    func hrWindow(deviceId: String, from: Int, to: Int) throws -> [(ts: Int, bpm: Int)] {
        let q = sqlQuote(deviceId)
        var out: [(ts: Int, bpm: Int)] = []
        try db.query("""
        SELECT ts, bpm FROM (
            SELECT ts, bpm FROM hrSample WHERE deviceId = \(q) AND ts >= \(from) AND ts <= \(to)
            UNION ALL
            SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) AS bpm FROM ppgHrSample p
            WHERE p.deviceId = \(q) AND p.ts >= \(from) AND p.ts <= \(to)
              AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
        ) ORDER BY ts ASC;
        """) { r in
            if let t = r.int(0), let b = r.int(1) { out.append((t, b)) }
        }
        return out
    }

    func dailyRestingHr(day: String) throws -> Double? {
        try db.scalar("SELECT restingHr FROM dailyMetric WHERE day = \(sqlQuote(day)) AND deviceId IN (\(computedReadIds.map(sqlQuote).joined(separator: ","))) AND restingHr IS NOT NULL ORDER BY restingHr LIMIT 1;")?.double
    }

    /// kcal for the bout [start,end] using the SAME inputs the engine passes for a DETECTED bout:
    /// day-HR-estimated (or overridden) HRmax, the day's resting HR (else the day's 10th percentile).
    func detectedBoutKcal(source: String, start: Int, end: Int, timeZone: TimeZone,
                          profile: WorkoutCalories.Profile) throws -> Double? {
        let hrId = hrDeviceId(forSource: source)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(start)))
        let from = Int(dayStart.timeIntervalSince1970)
        let to = Int(cal.date(byAdding: .day, value: 1, to: dayStart)!.timeIntervalSince1970) - 1
        let dayHr = try hrWindow(deviceId: hrId, from: from, to: to)
        let window = dayHr.filter { $0.ts >= start && $0.ts <= end }
        guard window.count >= 2 else { return nil }
        let dayBpm = dayHr.map { Double($0.bpm) }
        let hrmax = profile.hrMaxOverride > 0 ? profile.hrMaxOverride
            : WorkoutCalories.estimateHRmax(dayBpm, age: profile.age)
        let f = DateFormatter(); f.calendar = cal; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        let resting = try dailyRestingHr(day: f.string(from: dayStart)) ?? WorkoutCalories.derivedResting(dayBpm)
        return WorkoutCalories.estimateBoutCalories(window, profile: profile, hrmax: hrmax, restingHR: resting)
    }

    /// kcal for a MANUAL bout, as `AppModel.endWorkout` computes it: profile HRmax (Tanaka unless
    /// overridden), no resting HR.
    func manualBoutKcal(source: String, start: Int, end: Int, profile: WorkoutCalories.Profile) throws -> Double? {
        let w = try hrWindow(deviceId: hrDeviceId(forSource: source), from: start, to: end)
        guard w.count >= 2 else { return nil }
        let hrmax = profile.hrMaxOverride > 0 ? profile.hrMaxOverride : (208 - 0.7 * profile.age).rounded()
        let k = WorkoutCalories.estimateBoutCalories(w, profile: profile, hrmax: hrmax, restingHR: nil)
        return k > 0 ? k : nil
    }
}

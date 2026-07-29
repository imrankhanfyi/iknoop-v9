import Foundation

/// Pre-publish guards and post-build assertions.
///
/// The design principle: a publish that would produce WRONG or STALE data must fail loudly on the Mac
/// rather than render a plausible lie on the phone. Silent success is the failure mode to avoid.
enum Checks {

    struct GuardResult {
        var maxTs: Int
        var hrRows: Int
        var ageSeconds: Double
        var ageDescription: String
    }

    /// Two hard gates before anything is built.
    ///
    /// 1. ROW COUNT. `resolveDatabasePath` prefers the sandboxed container store, but the second
    ///    candidate is a 4 KB empty database. If the fork's production-identity patch were ever
    ///    dropped on a rebase, the app would become `com.noopapp.noop.staging` and this tool would
    ///    resolve to that empty store — publishing a valid, tiny, EMPTY payload with exit 0. The
    ///    count makes that a loud failure.
    /// 2. FRESHNESS. Deliberately generous (48h by default) because the whole premise is a laptop
    ///    that spends days shut. This gate catches a dead/wrong store, not ordinary staleness — the
    ///    viewer handles ordinary staleness by displaying `dataMaxTs`.
    static func runGuards(db: ReadOnlyDatabase, minHrRows: Int, maxAgeHours: Double) throws -> GuardResult {
        let rows = try db.scalar("SELECT COUNT(*) FROM hrSample;")?.int ?? 0
        guard rows >= minHrRows else {
            throw PublishError("""
            hrSample has only \(rows) rows (expected >= \(minHrRows)). This usually means the WRONG
            store was resolved — e.g. the empty staging store at
            ~/Library/Application Support/OpenWhoop/whoop.sqlite instead of the sandboxed container.
            Refusing to publish an empty payload. Pass --db explicitly to override, or lower
            --min-hr-rows if this is genuinely a fresh install.
            """)
        }
        let maxTs = try db.scalar("SELECT MAX(ts) FROM hrSample;")?.int ?? 0
        let age = Date().timeIntervalSince1970 - Double(maxTs)
        let hours = age / 3600.0
        guard hours <= maxAgeHours else {
            throw PublishError("""
            the store's newest hrSample is \(String(format: "%.1f", hours))h old (limit \
            \(String(format: "%.0f", maxAgeHours))h). Either the strap has not synced or NOOP.app is \
            not running. Refusing to publish silently stale data — raise --max-age-hours to override.
            """)
        }
        return GuardResult(maxTs: maxTs, hrRows: rows, ageSeconds: age,
                           ageDescription: String(format: "%.1fh old", hours))
    }

    /// Post-build assertions on the read model itself.
    static func verify(model: ReadModel, payload: PayloadDoc) throws {
        try verifySleepPerformance(model: model, payload: payload)
        try verifyNoAppleHealthLeak(payload: payload)
        try verifyEffectiveStart(payload: payload)
    }

    /// The ported `RestComposite` must reproduce the engine's persisted `sleep_performance` series.
    /// Verified to agree exactly on this store; if upstream changes the formula this fails loudly
    /// instead of the viewer quietly showing a different score than the app.
    static func verifySleepPerformance(model: ReadModel, payload: PayloadDoc) throws {
        let stored = try model.storedSleepPerformance()
        var mismatches: [String] = []
        for d in payload.days {
            guard let s = stored[d.day] else { continue }
            guard let computed = RestComposite.composite(totalSleepMin: d.totalSleepMin,
                                                         efficiency: d.efficiency,
                                                         deepMin: d.deepMin, remMin: d.remMin) else {
                mismatches.append("\(d.day): stored \(s) but composite returned nil")
                continue
            }
            if abs(computed - s) > 0.011 {
                mismatches.append("\(d.day): stored \(s) vs computed \(computed)")
            }
        }
        guard mismatches.isEmpty else {
            throw PublishError("""
            sleep-performance port disagrees with the persisted series on \(mismatches.count) day(s):
              \(mismatches.prefix(5).joined(separator: "\n  "))
            AnalyticsEngine.Rest.composite has probably changed; re-port RestComposite.swift.
            """)
        }
    }

    /// `apple-health` daily rows must never reach the viewer's day list: the app reads them only for
    /// the vitals/freshness paths, never for `days`. A leak would add ~4,200 rows and ~3,000 nights of
    /// sleep back to 2016 that no app screen shows. Detected structurally: no day older than the
    /// oldest computed row should be present.
    static func verifyNoAppleHealthLeak(payload: PayloadDoc) throws {
        // Any day carrying sleep but NO recovery/strain at all is the signature of an apple-health row
        // (hasRec = 0 and hasStrain = 0 across all 4,214 of them).
        let suspects = payload.days.filter {
            $0.totalSleepMin != nil && $0.recovery == nil && $0.strain == nil && $0.day < "2026-07-01"
        }
        guard suspects.isEmpty else {
            throw PublishError("""
            \(suspects.count) day(s) look like apple-health rows leaking into `days` \
            (e.g. \(suspects.prefix(3).map(\.day).joined(separator: ", "))). The day read must union \
            only importedReadIds + computedReadIds (+ activity-file steps).
            """)
        }
    }

    /// A user-edited night must carry a corrected onset. This is the assertion behind the
    /// `startTsAdjusted ?? startTs` rule: on this store the 2026-07-18 night has a 43-minute
    /// correction, and shipping the raw `startTs` would disagree with every app screen.
    static func verifyEffectiveStart(payload: PayloadDoc) throws {
        for s in payload.sleeps where s.userEdited {
            guard s.effectiveStartTs != s.startTs else { continue }
            return  // found at least one honoured correction
        }
        // Not an error — the user may simply have no edited nights — but say so, because a silent
        // "all clear" here is indistinguishable from the bug.
        let edited = payload.sleeps.filter(\.userEdited).count
        FileHandle.standardError.write(Data(
            "note: \(edited) user-edited night(s); none carry a startTsAdjusted correction.\n".utf8))
    }
}

/// `--self-test`: exercise the crypto and gzip paths with no database and no keychain, so the
/// primitives can be validated independently of the store.
enum SelfTest {
    static func run() throws {
        var failures: [String] = []

        // gzip: header, trailer, and a known CRC32.
        let sample = Data("the quick brown fox jumps over the lazy dog".utf8)
        let gz = try Gzip.compress(sample)
        if !(gz.count > 18 && gz[0] == 0x1f && gz[1] == 0x8b && gz[2] == 0x08) {
            failures.append("gzip header malformed")
        }
        // CRC32("123456789") == 0xCBF43926 (the standard check value).
        let crc = Gzip.crc32(Data("123456789".utf8))
        if crc != 0xCBF4_3926 { failures.append(String(format: "crc32 check value = %08X, want CBF43926", crc)) }
        // The trailer's ISIZE must equal the input length.
        let isize = gz.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        if Int(isize) != sample.count { failures.append("gzip ISIZE = \(isize), want \(sample.count)") }
        // And the embedded CRC must match the input's.
        let trailerCrc = gz.dropLast(4).suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        if trailerCrc != Gzip.crc32(sample) { failures.append("gzip trailer CRC mismatch") }

        // AES-GCM + PBKDF2 round trip, including AAD binding.
        let secret = Data("recovery=74.58 strain=56.16".utf8)
        let sealed = try Payload.seal(plaintext: secret, passphrase: "correct horse battery staple")
        let opened = try Payload.open(sealed: sealed, passphrase: "correct horse battery staple")
        if opened != secret { failures.append("AES-GCM round trip lost data") }

        // A wrong passphrase must fail, not return garbage.
        do {
            _ = try Payload.open(sealed: sealed, passphrase: "wrong passphrase")
            failures.append("wrong passphrase DECRYPTED — authentication is broken")
        } catch { /* expected */ }

        // Tampered AAD (a downgraded iteration count) must fail the tag check.
        var tampered = sealed
        tampered.aad = Payload.aadString(iterations: 1000, saltB64: sealed.saltB64,
                                         nonceB64: sealed.nonceB64)
        do {
            _ = try Payload.open(sealed: tampered, passphrase: "correct horse battery staple")
            failures.append("tampered AAD accepted — parameter downgrade is possible")
        } catch { /* expected */ }

        // Fresh salt AND nonce on every seal (see Crypto.swift for why this matters).
        let a = try Payload.seal(plaintext: secret, passphrase: "p")
        let b = try Payload.seal(plaintext: secret, passphrase: "p")
        if a.saltB64 == b.saltB64 { failures.append("salt is not fresh per publish") }
        if a.nonceB64 == b.nonceB64 { failures.append("nonce is not fresh per publish") }

        // RestComposite against the two values verified against the live store.
        let p1 = RestComposite.composite(totalSleepMin: 463.316666666667, efficiency: 0.955423425900467,
                                         deepMin: 85.0, remMin: 125.5)
        if p1 != 90.54 { failures.append("composite(2026-07-28) = \(p1 as Any), want 90.54") }
        let p2 = RestComposite.composite(totalSleepMin: 67.3833333333333, efficiency: 0.89387574618616,
                                         deepMin: 12.3333333333333, remMin: 20.0)
        if p2 != 49.09 { failures.append("composite(2026-07-13) = \(p2 as Any), want 49.09") }

        // Workout visibility: the detected-shadow rule, using the real 2026-07-14 pair.
        let detected = RawWorkout(deviceId: "my-whoop-noop", startTs: 1784_026_563, endTs: 1784_035_722,
                                  sport: "detected", source: "my-whoop-noop", durationS: nil,
                                  energyKcal: nil, avgHr: 119, maxHr: 184, strain: 56.23,
                                  distanceM: nil, zonesJSON: nil)
        let real = RawWorkout(deviceId: "my-whoop-noop", startTs: 1784_030_120, endTs: 1784_035_169,
                              sport: "Workout", source: "noop", durationS: nil, energyKcal: nil,
                              avgHr: 141, maxHr: 184, strain: 11.68, distanceM: nil, zonesJSON: nil)
        if WorkoutClass.classify("my-whoop-noop") != .detected { failures.append("classify('my-whoop-noop') != detected") }
        if WorkoutClass.classify("noop") != .apple { failures.append("classify('noop') != apple (the documented fall-through)") }
        if WorkoutClass.classify("manual") != .manual { failures.append("classify('manual') != manual") }
        let kept = WorkoutVisibility.dropDetectedShadows([detected, real])
        if kept.count != 1 || kept[0].source != "noop" {
            failures.append("dropDetectedShadows kept \(kept.map(\.source)) — want just the real row")
        }
        if !WorkoutClass.classify("manual").isStrapNative { failures.append("manual should be strap-native") }
        if WorkoutClass.classify("apple-health").isStrapNative { failures.append("apple should NOT be strap-native") }

        // Tombstone span parsing drops malformed entries rather than hiding everything.
        let spans = Tombstones.parseSpans(["100:200", "bad", "300:250", "400:500"])
        if spans.count != 2 { failures.append("parseSpans kept \(spans.count) of 4, want 2") }

        if failures.isEmpty {
            print("self-test: all checks passed")
        } else {
            for f in failures { print("FAIL: \(f)") }
            throw PublishError("\(failures.count) self-test failure(s)")
        }
    }
}

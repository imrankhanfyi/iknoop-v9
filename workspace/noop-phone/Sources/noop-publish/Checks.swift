import Foundation
import CryptoKit

/// Pre-publish guards and post-build assertions.
///
/// The design principle: a publish that would produce WRONG or STALE data must fail loudly on the Mac
/// rather than render a plausible lie on the phone. Silent success is the failure mode to avoid.
enum Checks {

    struct GuardResult {
        /// The OFFLOAD FRONTIER: newest `gravitySample.ts`. Gravity arrives only via history offload, so
        /// this says how far the strap's banked history has reached the store. It is the publish's
        /// `dataMaxTs`. NOT `hrSample`: live HR streams in real time while the offload can lag by days
        /// (2026-11-18: hrSample max 16:57 today, gravity max 2026-11-11), so an HR-keyed gate passes and
        /// ships week-stale nights that look fresh.
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
            """, reason: "too-few-hr-rows rows=\(rows)")
        }
        let maxTs = try db.scalar("SELECT MAX(ts) FROM gravitySample;")?.int ?? 0
        let age = Date().timeIntervalSince1970 - Double(maxTs)
        let hours = age / 3600.0
        guard hours <= maxAgeHours else {
            throw PublishError("""
            the offload frontier (newest gravitySample) is \(String(format: "%.1f", hours))h old (limit \
            \(String(format: "%.0f", maxAgeHours))h). Either NOOP.app is not running or the strap's history \
            has not offloaded yet (live HR can be current while this lags). Refusing to publish silently \
            stale data — raise --max-age-hours to override.
            """, reason: String(format: "stale-frontier age=%.1fh", hours))
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

        failures += inboxChecks()
        failures += effectsChecks()

        if failures.isEmpty {
            print("self-test: all checks passed")
        } else {
            for f in failures { print("FAIL: \(f)") }
            throw PublishError("\(failures.count) self-test failure(s)")
        }
    }
}

/// `--calorie-check`: does the ported kcal estimator reproduce the stored `energyKcal` of unedited
/// DETECTED workouts? Prints only relative errors (never the kcal or profile values themselves).
enum CalorieCheck {
    static func run(model: ReadModel, timeZone: TimeZone) throws {
        guard let profile = WorkoutCalories.loadProfile() else { throw PublishError("no profile in container prefs") }
        var rows: [RawWorkout] = []
        for r in try model.rawWorkouts() where r.cls == .detected && (r.energyKcal ?? 0) > 0 { rows.append(r) }
        rows.sort { $0.startTs > $1.startTs }
        let sample = Array(rows.prefix(20))
        var within = 0
        for (i, r) in sample.enumerated() {
            guard let k = try model.detectedBoutKcal(source: r.source, start: r.startTs, end: r.endTs,
                                                     timeZone: timeZone, profile: profile) else {
                print("#\(i + 1): no HR window"); continue
            }
            let err = (k - r.energyKcal!) / r.energyKcal! * 100
            if abs(err) <= 2 { within += 1 }
            print(String(format: "#%d: relative error %+.2f%%", i + 1, err))
        }
        print("sample=\(sample.count) within2pct=\(within) (\(sample.isEmpty ? 0 : within * 100 / sample.count)%)")
    }
}

extension SelfTest {
    /// Phase 2: the inbox contract, the side store, and the workout-override matcher.
    static func inboxChecks() -> [String] {
        var failures: [String] = []
        do {
            // Derivation vectors (identical in receiver/token_hash.py --selftest and viewer/app.js).
            let keys = try InboxCrypto.derive(passphrase: "phase1-test")
            if keys.authToken != "d5b926ba1a6ad66e62133d5c1bd31857b577809737459212a7cde0a473fbd92b" {
                failures.append("inbox authToken vector mismatch")
            }
            if keys.entryKeyHex != "13bfc24aab3da2fa145ee1fa4eeaaee9810ec32dab1852e96067f34143a4fd82" {
                failures.append("inbox entryKey vector mismatch")
            }
            // Seal/open round trip, bound to the id via AAD.
            let id = "11111111-2222-4333-8444-555555555555"
            let pt = Data("hello entry".utf8)
            let box = try InboxCrypto.seal(pt, id: id, key: keys.entryKey)
            if try InboxCrypto.open(nonceB64: box.nonceB64, ciphertextB64: box.ciphertextB64, id: id, key: keys.entryKey) != pt {
                failures.append("entry round trip lost data")
            }
            if (try? InboxCrypto.open(nonceB64: box.nonceB64, ciphertextB64: box.ciphertextB64,
                                      id: "11111111-2222-4333-8444-555555555556", key: keys.entryKey)) != nil {
                failures.append("entry opened under a different id (AAD not bound)")
            }
            let other = try InboxCrypto.derive(passphrase: "not-the-passphrase", iterations: 1000)
            if (try? InboxCrypto.open(nonceB64: box.nonceB64, ciphertextB64: box.ciphertextB64, id: id, key: other.entryKey)) != nil {
                failures.append("entry opened under the wrong key")
            }
            // A fixed entry produced by the BROWSER's WebCrypto (Node 25) — pins the JS side of the contract.
            let jsId = "3f2b8a14-5c6d-4e7f-8a9b-0c1d2e3f4a5b"
            let js = try InboxCrypto.open(
                nonceB64: "AQIDBAUGBwgJCgsM",
                ciphertextB64: "bUD3r3I6sei+g/vHO3EoDn5zl+At+zVQE505d4sOloJb7fM+KJCdLqjy71Z1kz4S5kz2OdNZzlJgUsf2G0wAZa3YSz1pncHO/EhivxDI9DXIkxHQVQDnN6kV8fJD2Vq/ZfORqKIxCRjs9j0qE90K",
                id: jsId, key: keys.entryKey)
            if case .checkin(let d, let i, let v, let at)? = EntryParser.parse(js) {
                if d != "2026-11-17" || i != "item_a" || v != true || at != 1763400000 { failures.append("JS entry vector fields wrong") }
            } else { failures.append("JS entry vector did not parse") }

            // Entry validation.
            func p(_ s: String) -> InboxEntry? { EntryParser.parse(Data(s.utf8)) }
            if p(#"{"v":1,"kind":"checkin","day":"2026-11-17","item":"a","value":"yes","enteredAt":5}"#) != nil { failures.append("string value accepted") }
            if p(#"{"v":1,"kind":"checkin","day":"2026-11-17","item":"a","value":1,"enteredAt":5}"#) != nil { failures.append("numeric value accepted as bool") }
            if p(#"{"v":1,"kind":"checkin","day":"17-11-2026","item":"a","value":true,"enteredAt":5}"#) != nil { failures.append("bad day accepted") }
            if p(#"{"v":2,"kind":"checkin","day":"2026-11-17","item":"a","value":true,"enteredAt":5}"#) != nil { failures.append("v2 accepted") }
            if case .checkin(_, _, let v, _)? = p(#"{"v":1,"kind":"checkin","day":"2026-11-17","item":"a","value":null,"enteredAt":5}"#), v == nil {} else { failures.append("null (clear) not parsed") }
            if p(#"{"v":1,"kind":"workoutOverride","orig":{"startTs":10,"endTs":5,"sport":"X"},"deleted":true,"enteredAt":5}"#) != nil { failures.append("inverted orig span accepted") }

            // Side store: last-write-wins independent of arrival order; clear overrides an older yes;
            // an older yes cannot resurrect a clear; every authenticated id is logged.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noop-selftest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = try SideStore(stateDir: dir)
            try store.apply(.checkin(day: "2026-11-17", item: "a", value: nil, enteredAt: 20), id: "id-clear")
            try store.apply(.checkin(day: "2026-11-17", item: "a", value: true, enteredAt: 10), id: "id-old-yes")
            try store.apply(.checkin(day: "2026-11-17", item: "b", value: true, enteredAt: 10), id: "id-b")
            let c = try store.checkins(fromDay: "2026-11-01")
            if c.answers["2026-11-17"]?["a"] != nil || c.cleared.count != 1 { failures.append("stale yes resurrected a cleared answer") }
            if c.answers["2026-11-17"]?["b"] != true { failures.append("side store lost an answer") }
            if try store.lastIngestedIds(500) != ["id-clear", "id-old-yes", "id-b"] { failures.append("ingested log incomplete") }

            // Inbox pass: one good entry, one sealed with the wrong key, one with a mismatched id.
            let inbox = dir.appendingPathComponent("inbox")
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            func drop(_ id: String, plaintext: String, key: SymmetricKey, bodyId: String? = nil) throws {
                let b = try InboxCrypto.seal(Data(plaintext.utf8), id: id, key: key)
                let body: [String: Any] = ["v": 1, "id": bodyId ?? id, "nonceB64": b.nonceB64, "ciphertextB64": b.ciphertextB64]
                try JSONSerialization.data(withJSONObject: body).write(to: inbox.appendingPathComponent("\(id).json"))
            }
            let good = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", bad = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeef", mism = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeee00"
            try drop(good, plaintext: #"{"v":1,"kind":"checkin","day":"2026-11-18","item":"c","value":false,"enteredAt":30}"#, key: keys.entryKey)
            try drop(bad, plaintext: #"{"v":1,"kind":"checkin","day":"2026-11-18","item":"d","value":true,"enteredAt":30}"#, key: other.entryKey)
            try drop(mism, plaintext: #"{"v":1,"kind":"checkin","day":"2026-11-18","item":"e","value":true,"enteredAt":30}"#, key: keys.entryKey, bodyId: good)
            let sum = try Inbox.process(dir: inbox, key: keys.entryKey, store: store)
            if sum.committed != 1 || sum.rejected != 2 || Set(sum.processedIds) != [good, bad, mism] {
                failures.append("inbox pass counted committed=\(sum.committed) rejected=\(sum.rejected) ids=\(sum.processedIds.count)")
            }
            if try store.checkins(fromDay: "2026-11-18").answers["2026-11-18"]?["c"] != false { failures.append("inbox entry not committed") }
            let again = try Inbox.process(dir: inbox, key: keys.entryKey, store: store)
            if again.committed != 0 || again.duplicate != 1 { failures.append("re-delivered entry counted as new") }

            // Override matching: largest overlap, >= 50% of the original span; orphans counted.
            func row(_ s: Int, _ e: Int) -> RawWorkout {
                RawWorkout(deviceId: "d", startTs: s, endTs: e, sport: "detected", source: "my-whoop-noop",
                           durationS: Double(e - s), energyKcal: 100, avgHr: 100, maxHr: 150, strain: 5,
                           distanceM: nil, zonesJSON: nil)
            }
            let ov = WorkoutOverride(origStart: 1000, origEnd: 2000, origSport: "detected", sport: "Running",
                                     startTs: nil, endTs: nil, deleted: false, enteredAt: 1)
            var (out, orphans) = Overrides.apply([ov], to: [row(900, 1900), row(5000, 6000)])
            if orphans != 0 || out.count != 2 || out[0].sport != "Running" || out[0].original?.startTs != 900 { failures.append("override not matched by overlap") }
            (out, orphans) = Overrides.apply([ov], to: [row(1600, 2600)])
            if orphans != 1 || out[0].original != nil { failures.append("override below 50% overlap was applied") }
            var del = ov; del.deleted = true
            (out, orphans) = Overrides.apply([del], to: [row(1000, 2000)])
            if !out.isEmpty { failures.append("deleted override did not hide the workout") }
        } catch {
            failures.append("inbox self-test threw: \(error)")
        }
        return failures
    }
}

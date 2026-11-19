import Foundation

// noop-publish — build the phone viewer's encrypted payload from the live NOOP store.
//
// Usage:
//   noop-publish --out <dir> [--db <path>] [--passphrase-from keychain|stdin|env]
//                [--max-age-hours N] [--min-hr-rows N] [--plaintext-out <path>] [--self-test]
//                [--skip-unless-after <unix>] [--inbox-dir <dir>] [--calorie-check]
//
// Writes <dir>/noop-data.json (the envelope) and <dir>/frontier (the offload frontier it was built at).
// Read-only with respect to the NOOP store.
//
// --inbox-dir: decrypt + commit the phone's write-back entries (checklist answers, workout edits) into the
// side store BEFORE the store guards, then write <out>/processed-ids (every well-named file, committed or
// rejected) and <out>/inbox-summary. The wrapper deletes exactly those ids on the server.
//
// Exit codes: 0 published · 1 failed · 3 skipped (frontier not past --skip-unless-after AND no new entries).
// On failure the LAST stderr line is `noop-publish-reason: <category>` — safe to log unattended.

struct Options {
    var outDir: URL?
    var dbPath: String?
    var passphraseSource = "keychain"
    var maxAgeHours = 48.0
    var minHrRows = 100_000
    var plaintextOut: URL?
    var selfTest = false
    var timeZone = TimeZone.current
    var skipUnlessAfter: Int?
    var inboxDir: URL?
    var calorieCheck = false
}

let exitSkipped: Int32 = 3

func parseArgs() throws -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--out":
            guard let v = it.next() else { throw PublishError("--out needs a directory") }
            o.outDir = URL(fileURLWithPath: v, isDirectory: true)
        case "--db":
            o.dbPath = it.next()
        case "--passphrase-from":
            guard let v = it.next(), ["keychain", "stdin", "env"].contains(v) else {
                throw PublishError("--passphrase-from must be keychain, stdin or env")
            }
            o.passphraseSource = v
        case "--max-age-hours":
            guard let v = it.next(), let d = Double(v) else { throw PublishError("--max-age-hours needs a number") }
            o.maxAgeHours = d
        case "--min-hr-rows":
            guard let v = it.next(), let n = Int(v) else { throw PublishError("--min-hr-rows needs a number") }
            o.minHrRows = n
        case "--plaintext-out":
            guard let v = it.next() else { throw PublishError("--plaintext-out needs a path") }
            o.plaintextOut = URL(fileURLWithPath: v)
        case "--timezone":
            guard let v = it.next(), let tz = TimeZone(identifier: v) else {
                throw PublishError("--timezone needs a valid IANA identifier")
            }
            o.timeZone = tz
        case "--self-test":
            o.selfTest = true
        case "--inbox-dir":
            guard let v = it.next() else { throw PublishError("--inbox-dir needs a directory") }
            o.inboxDir = URL(fileURLWithPath: v, isDirectory: true)
        case "--calorie-check":
            o.calorieCheck = true
        case "--skip-unless-after":
            guard let v = it.next(), let n = Int(v) else { throw PublishError("--skip-unless-after needs a unix time") }
            o.skipUnlessAfter = n
        case "-h", "--help":
            print("""
            noop-publish — build the phone viewer's encrypted payload.

              --out <dir>                 where to write noop-data.json (required unless --self-test)
              --db <path>                 override the store path (default: resolve the container)
              --passphrase-from <src>     keychain (default) | stdin | env
              --max-age-hours <n>         fail if the store's newest sample is older (default 48)
              --min-hr-rows <n>           fail if hrSample has fewer rows (default 100000)
              --plaintext-out <path>      ALSO write the unencrypted JSON (debugging; keep out of git)
              --timezone <IANA>           day/'today' resolution timezone (default: system)
              --self-test                 run the crypto + gzip round-trip checks and exit
              --skip-unless-after <unix>  exit 3 without building unless the offload frontier is newer
                                          or the inbox committed new entries
              --inbox-dir <dir>           decrypt + commit phone entries first; writes <out>/processed-ids
              --calorie-check             dev: compare the ported kcal estimator to stored detected workouts
            State dir: $NOOP_PHONE_STATE_DIR (default ~/Library/Application Support/noop-phone).

            The passphrase is NEVER accepted as a command-line argument: argv is visible to every
            process running as this user. `keychain` reads:
              security find-generic-password -w -s noop-publish -a <user>
            """)
            exit(0)
        default:
            throw PublishError("unknown argument: \(a)")
        }
    }
    return o
}

/// Resolve the store path the way the app does. Mirrors `DatabasePathResolver.candidates`
/// (Packages/NoopLocalAccess) — the sandboxed container FIRST, then the unsandboxed location.
///
/// NEVER falls back silently: if the container store exists it is used, full stop. The staging /
/// unsandboxed store is a 4 KB empty database on this machine, and quietly publishing *that* would
/// produce a valid, tiny, empty payload and exit 0. The row-count guard below is the backstop.
func resolveDatabasePath(override: String?) throws -> String {
    if let override {
        guard FileManager.default.fileExists(atPath: override) else {
            throw PublishError("--db path does not exist: \(override)")
        }
        return override
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent("Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite").path,
        home.appendingPathComponent("Library/Application Support/OpenWhoop/whoop.sqlite").path,
    ]
    for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
    throw PublishError("no NOOP store found. Looked in:\n  " + candidates.joined(separator: "\n  "))
}

func readPassphrase(_ source: String) throws -> String {
    switch source {
    case "stdin":
        FileHandle.standardError.write(Data("Passphrase: ".utf8))
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw PublishError("no passphrase on stdin")
        }
        return line
    case "env":
        guard let v = ProcessInfo.processInfo.environment["NOOP_PUBLISH_PASSPHRASE"], !v.isEmpty else {
            throw PublishError("NOOP_PUBLISH_PASSPHRASE is not set")
        }
        FileHandle.standardError.write(Data("""
        warning: reading the passphrase from the environment. Fine for a manual run; do NOT put it in
                 a launchd plist (those are world-readable on disk). Use the keychain for scheduled runs.\n
        """.utf8))
        return v
    default:
        let user = NSUserName()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-w", "-s", "noop-publish", "-a", user]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else {
            throw PublishError("""
            no passphrase in the keychain. Create one with:
              security add-generic-password -s noop-publish -a \(user) -w
            (omit -w and it prompts, so the passphrase never lands in shell history)
            """)
        }
        return s
    }
}

// MARK: - Run

do {
    let opts = try parseArgs()

    if opts.selfTest {
        try SelfTest.run()
        exit(0)
    }
    let stateDir: URL = {
        if let e = ProcessInfo.processInfo.environment["NOOP_PHONE_STATE_DIR"], !e.isEmpty {
            return URL(fileURLWithPath: e, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/noop-phone", isDirectory: true)
    }()

    if opts.calorieCheck {
        let db = try ReadOnlyDatabase(path: try resolveDatabasePath(override: opts.dbPath))
        try CalorieCheck.run(model: try ReadModel(db: db), timeZone: opts.timeZone)
        exit(0)
    }
    guard let outDir = opts.outDir else { throw PublishError("--out is required (or use --self-test)") }

    // Inbox FIRST, before the store guards: committing the phone's entries must not depend on the
    // strap's offload being fresh. The passphrase is read lazily, only when there is something to open.
    var passphraseCache: String?
    func getPassphrase() throws -> String {
        if let p = passphraseCache { return p }
        let p = try readPassphrase(opts.passphraseSource)
        passphraseCache = p
        return p
    }
    let side = try SideStore(stateDir: stateDir)
    var committed = 0
    if let inboxDir = opts.inboxDir {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let hasFiles = ((try? FileManager.default.contentsOfDirectory(atPath: inboxDir.path)) ?? [])
            .contains { $0.hasSuffix(".json") }
        var summary = InboxSummary()
        if hasFiles {
            let keys = try InboxCrypto.derive(passphrase: try getPassphrase())
            summary = try Inbox.process(dir: inboxDir, key: keys.entryKey, store: side)
        }
        // After COMMIT only: a crash before this point leaves nothing to delete server-side.
        try Data(summary.processedIds.map { $0 + "\n" }.joined().utf8)
            .write(to: outDir.appendingPathComponent("processed-ids"), options: .atomic)
        let line = "inbox: committed=\(summary.committed) duplicate=\(summary.duplicate) rejected=\(summary.rejected)"
        try Data((line + "\n").utf8).write(to: outDir.appendingPathComponent("inbox-summary"), options: .atomic)
        if summary.committed + summary.duplicate + summary.rejected > 0 {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        committed = summary.committed
    }

    let dbPath = try resolveDatabasePath(override: opts.dbPath)
    let db = try ReadOnlyDatabase(path: dbPath)
    FileHandle.standardError.write(Data("store: \(dbPath)\n".utf8))
    if let jm = db.pragmaText("journal_mode") {
        FileHandle.standardError.write(Data("journal_mode: \(jm)\n".utf8))
    }

    // Guards and the skip check run BEFORE the read model: the model's workout-HR precompute scans
    // hrSample, and this runs every 15 min — mostly to skip — often during a strap offload.
    let guards = try Checks.runGuards(db: db, minHrRows: opts.minHrRows, maxAgeHours: opts.maxAgeHours)
    if let last = opts.skipUnlessAfter, guards.maxTs <= last, committed == 0 {
        FileHandle.standardError.write(Data("noop-publish: frontier \(guards.maxTs) not past \(last); skipping\n".utf8))
        exit(exitSkipped)
    }
    let model = try ReadModel(db: db)
    let payload = try Build.payload(model: model, timeZone: opts.timeZone, dataMaxTs: guards.maxTs,
                                    side: side, stateDir: stateDir)
    do {
        try Checks.verify(model: model, payload: payload)
    } catch let e as PublishError {
        throw PublishError(e.description, reason: "verify-failed")
    }

    let plaintext = try Build.serialize(payload)
    let gz = try Gzip.compress(plaintext)
    let passphrase = try getPassphrase()
    let sealed = try Payload.seal(plaintext: gz, passphrase: passphrase)

    // Prove the round-trip on every publish: a payload that cannot be reopened is worse than none.
    let reopened = try Payload.open(sealed: sealed, passphrase: passphrase)
    guard reopened == gz else { throw PublishError("seal/open round-trip mismatch — refusing to publish") }

    try Build.write(sealed: sealed, payload: payload, plaintext: plaintext,
                    outDir: outDir, plaintextOut: opts.plaintextOut)
    // The wrapper records this as "last published frontier" only AFTER the transfer succeeds.
    try Data("\(guards.maxTs)\n".utf8).write(to: outDir.appendingPathComponent("frontier"), options: .atomic)

    let kb = { (n: Int) in String(format: "%.1f KB", Double(n) / 1024.0) }
    FileHandle.standardError.write(Data("""
    published \(outDir.appendingPathComponent("noop-data.json").path)
      days=\(payload.days.count) sleeps=\(payload.sleeps.count) workouts=\(payload.workouts.count) \
    series=\(payload.series.count) edited=\(payload.workouts.filter { $0.edited }.count) \
    orphanOverrides=\(payload.orphanOverrides) ingestedIds=\(payload.ingestedEntryIds.count)
      json=\(kb(plaintext.count)) gzip=\(kb(gz.count)) sealed=\(kb(sealed.ciphertextB64.count))
      dataMaxTs=\(guards.maxTs) (\(guards.ageDescription))
    \n
    """.utf8))
} catch {
    FileHandle.standardError.write(Data("noop-publish: \(error)\n".utf8))
    let reason = (error as? PublishError)?.reason ?? "error"
    FileHandle.standardError.write(Data("noop-publish-reason: \(reason)\n".utf8))
    exit(1)
}

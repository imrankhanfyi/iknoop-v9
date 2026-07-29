import Foundation

// noop-publish — build the phone viewer's encrypted payload from the live NOOP store.
//
// Usage:
//   noop-publish --out <dir> [--db <path>] [--passphrase-from keychain|stdin|env]
//                [--max-age-hours N] [--min-hr-rows N] [--plaintext-out <path>] [--self-test]
//
// Writes <dir>/noop-data.json (the envelope). Read-only with respect to the NOOP store.

struct Options {
    var outDir: URL?
    var dbPath: String?
    var passphraseSource = "keychain"
    var maxAgeHours = 48.0
    var minHrRows = 100_000
    var plaintextOut: URL?
    var selfTest = false
    var timeZone = TimeZone.current
}

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
    guard let outDir = opts.outDir else { throw PublishError("--out is required (or use --self-test)") }

    let dbPath = try resolveDatabasePath(override: opts.dbPath)
    let db = try ReadOnlyDatabase(path: dbPath)
    FileHandle.standardError.write(Data("store: \(dbPath)\n".utf8))
    if let jm = db.pragmaText("journal_mode") {
        FileHandle.standardError.write(Data("journal_mode: \(jm)\n".utf8))
    }

    let model = try ReadModel(db: db)
    let guards = try Checks.runGuards(db: db, minHrRows: opts.minHrRows, maxAgeHours: opts.maxAgeHours)
    let payload = try Build.payload(model: model, timeZone: opts.timeZone, dataMaxTs: guards.maxTs)
    try Checks.verify(model: model, payload: payload)

    let plaintext = try Build.serialize(payload)
    let gz = try Gzip.compress(plaintext)
    let passphrase = try readPassphrase(opts.passphraseSource)
    let sealed = try Payload.seal(plaintext: gz, passphrase: passphrase)

    // Prove the round-trip on every publish: a payload that cannot be reopened is worse than none.
    let reopened = try Payload.open(sealed: sealed, passphrase: passphrase)
    guard reopened == gz else { throw PublishError("seal/open round-trip mismatch — refusing to publish") }

    try Build.write(sealed: sealed, payload: payload, plaintext: plaintext,
                    outDir: outDir, plaintextOut: opts.plaintextOut)

    let kb = { (n: Int) in String(format: "%.1f KB", Double(n) / 1024.0) }
    FileHandle.standardError.write(Data("""
    published \(outDir.appendingPathComponent("noop-data.json").path)
      days=\(payload.days.count) sleeps=\(payload.sleeps.count) workouts=\(payload.workouts.count) \
    series=\(payload.series.count)
      json=\(kb(plaintext.count)) gzip=\(kb(gz.count)) sealed=\(kb(sealed.ciphertextB64.count))
      dataMaxTs=\(guards.maxTs) (\(guards.ageDescription))
    \n
    """.utf8))
} catch {
    FileHandle.standardError.write(Data("noop-publish: \(error)\n".utf8))
    exit(1)
}

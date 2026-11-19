import Foundation
import SQLite3
import CryptoKit

/// Minimal WRITABLE SQLite wrapper for the phone side store. Deliberately a separate type from
/// `ReadOnlyDatabase`: nothing that can write is ever pointed at the NOOP store.
final class WritableDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw PublishError("cannot open side store (rc=\(rc))", reason: "side-store-open")
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }
    deinit { sqlite3_close_v2(handle) }

    enum Arg { case int(Int), text(String), null }

    func exec(_ sql: String, _ args: [Arg] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PublishError("side store prepare failed: \(String(cString: sqlite3_errmsg(handle)))", reason: "side-store-sql")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw PublishError("side store step failed: \(String(cString: sqlite3_errmsg(handle)))", reason: "side-store-sql")
        }
    }

    func changes() -> Int { Int(sqlite3_changes(handle)) }

    func query(_ sql: String, _ args: [Arg] = [], _ each: (ReadOnlyDatabase.Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PublishError("side store prepare failed: \(String(cString: sqlite3_errmsg(handle)))", reason: "side-store-sql")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try each(ReadOnlyDatabase.Row(stmt: stmt)) }
            else if rc == SQLITE_DONE { return }
            else { throw PublishError("side store step failed", reason: "side-store-sql") }
        }
    }
}

/// Validated, decrypted entry plaintext.
enum InboxEntry {
    case checkin(day: String, item: String, value: Bool?, enteredAt: Int)
    case workoutOverride(WorkoutOverride)
}

struct WorkoutOverride {
    var origStart: Int, origEnd: Int, origSport: String
    var sport: String?, startTs: Int?, endTs: Int?
    var deleted: Bool
    var enteredAt: Int
}

enum EntryParser {
    static let dayRe = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
    static let itemRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,64}$")
    static let sportRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9 _.-]{1,48}$")

    fileprivate static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 4e12 ? Int(d) : nil
        }
        return nil
    }

    /// nil = structurally invalid (rejected).
    static func parse(_ plaintext: Data) -> InboxEntry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              int(obj["v"]) == 1, let kind = obj["kind"] as? String,
              let enteredAt = int(obj["enteredAt"]), enteredAt > 0 else { return nil }
        switch kind {
        case "checkin":
            guard let day = obj["day"] as? String, matches(dayRe, day),
                  let item = obj["item"] as? String, matches(itemRe, item) else { return nil }
            var value: Bool?
            if let n = obj["value"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { value = n.boolValue }
            else if obj["value"] is NSNull { value = nil }
            else { return nil }
            return .checkin(day: day, item: item, value: value, enteredAt: enteredAt)
        case "workoutOverride":
            guard let orig = obj["orig"] as? [String: Any],
                  let os = int(orig["startTs"]), let oe = int(orig["endTs"]), oe > os,
                  let osp = orig["sport"] as? String, matches(sportRe, osp) else { return nil }
            var o = WorkoutOverride(origStart: os, origEnd: oe, origSport: osp, sport: nil, startTs: nil,
                                    endTs: nil, deleted: false, enteredAt: enteredAt)
            if let s = obj["sport"] { guard let s = s as? String, matches(sportRe, s) else { return nil }; o.sport = s }
            if let s = obj["startTs"] { guard let v = int(s) else { return nil }; o.startTs = v }
            if let e = obj["endTs"] { guard let v = int(e) else { return nil }; o.endTs = v }
            if let d = obj["deleted"] {
                guard let n = d as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
                o.deleted = n.boolValue
            }
            if !o.deleted {
                if (o.startTs == nil) != (o.endTs == nil) { return nil }
                if let s = o.startTs, let e = o.endTs, e <= s { return nil }
            }
            return .workoutOverride(o)
        default:
            return nil
        }
    }
}

/// The phone side store: `<stateDir>/lifestyle.sqlite`. Outside the repo and outside the NOOP container.
/// Last-write-wins by `enteredAt`, evaluated with a guarded upsert so batch order cannot matter.
///
/// A cleared check-in (`value` null) is kept as a NULL row rather than deleted: a physical delete would
/// let a stale, older "yes" arriving later resurrect the answer, and could not override a legacy NOOP
/// journal answer. NULL rows are excluded from the published answers.
final class SideStore {
    let db: WritableDatabase

    init(stateDir: URL) throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        db = try WritableDatabase(path: stateDir.appendingPathComponent("lifestyle.sqlite").path)
        try db.exec("PRAGMA journal_mode=WAL;")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS checkin(
          day TEXT NOT NULL, item TEXT NOT NULL, value INTEGER, enteredAt INTEGER NOT NULL, entryId TEXT NOT NULL,
          PRIMARY KEY(day, item));
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS workoutOverride(
          origStart INTEGER NOT NULL, origEnd INTEGER NOT NULL, origSport TEXT NOT NULL,
          sport TEXT, startTs INTEGER, endTs INTEGER, deleted INTEGER NOT NULL DEFAULT 0,
          enteredAt INTEGER NOT NULL, entryId TEXT NOT NULL,
          PRIMARY KEY(origStart, origEnd, origSport));
        """)
        // Every authenticated entry id, including last-write-wins losers, so the phone's pending badge
        // clears for all of them. `seq` gives a stable "last N" order.
        try db.exec("CREATE TABLE IF NOT EXISTS ingested(seq INTEGER PRIMARY KEY AUTOINCREMENT, entryId TEXT NOT NULL UNIQUE);")
    }

    func isIngested(_ id: String) throws -> Bool {
        var found = false
        try db.query("SELECT 1 FROM ingested WHERE entryId = ?1;", [.text(id)]) { _ in found = true }
        return found
    }

    func apply(_ e: InboxEntry, id: String) throws {
        try db.exec("INSERT INTO ingested(entryId) VALUES (?1);", [.text(id)])
        switch e {
        case .checkin(let day, let item, let value, let at):
            try db.exec("""
            INSERT INTO checkin(day,item,value,enteredAt,entryId) VALUES (?1,?2,?3,?4,?5)
            ON CONFLICT(day,item) DO UPDATE SET value=excluded.value, enteredAt=excluded.enteredAt, entryId=excluded.entryId
            WHERE excluded.enteredAt > checkin.enteredAt;
            """, [.text(day), .text(item), value.map { .int($0 ? 1 : 0) } ?? .null, .int(at), .text(id)])
        case .workoutOverride(let o):
            try db.exec("""
            INSERT INTO workoutOverride(origStart,origEnd,origSport,sport,startTs,endTs,deleted,enteredAt,entryId)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
            ON CONFLICT(origStart,origEnd,origSport) DO UPDATE SET sport=excluded.sport, startTs=excluded.startTs,
              endTs=excluded.endTs, deleted=excluded.deleted, enteredAt=excluded.enteredAt, entryId=excluded.entryId
            WHERE excluded.enteredAt > workoutOverride.enteredAt;
            """, [.int(o.origStart), .int(o.origEnd), .text(o.origSport),
                  o.sport.map { .text($0) } ?? .null, o.startTs.map { .int($0) } ?? .null,
                  o.endTs.map { .int($0) } ?? .null, .int(o.deleted ? 1 : 0), .int(o.enteredAt), .text(id)])
        }
    }

    /// `{day: {item: Bool}}` from explicit answers only (cleared rows omitted), plus the set of cleared
    /// (day,item) pairs so they can override legacy answers.
    func checkins(fromDay: String) throws -> (answers: [String: [String: Bool]], cleared: [(String, String)]) {
        var a: [String: [String: Bool]] = [:]
        var cleared: [(String, String)] = []
        try db.query("SELECT day,item,value FROM checkin WHERE day >= ?1;", [.text(fromDay)]) { r in
            guard let d = r.text(0), let i = r.text(1) else { return }
            if let v = r.int(2) { a[d, default: [:]][i] = v != 0 } else { cleared.append((d, i)) }
        }
        return (a, cleared)
    }

    func overrides() throws -> [WorkoutOverride] {
        var out: [WorkoutOverride] = []
        try db.query("SELECT origStart,origEnd,origSport,sport,startTs,endTs,deleted,enteredAt FROM workoutOverride;") { r in
            guard let os = r.int(0), let oe = r.int(1), let osp = r.text(2), let at = r.int(7) else { return }
            let sp = r.value(3) == .null ? nil : r.text(3)
            out.append(WorkoutOverride(origStart: os, origEnd: oe, origSport: osp, sport: sp,
                                       startTs: r.value(4) == .null ? nil : r.int(4),
                                       endTs: r.value(5) == .null ? nil : r.int(5),
                                       deleted: r.bool(6), enteredAt: at))
        }
        return out
    }

    func lastIngestedIds(_ n: Int = 500) throws -> [String] {
        var ids: [String] = []
        try db.query("SELECT entryId FROM ingested ORDER BY seq DESC LIMIT ?1;", [.int(n)]) { r in
            if let s = r.text(0) { ids.append(s) }
        }
        return ids.reversed()
    }
}

struct InboxSummary {
    var committed = 0, duplicate = 0, rejected = 0
    var processedIds: [String] = []
}

enum Inbox {
    static let uuidRe = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    static func isUUID(_ s: String) -> Bool { uuidRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// Decrypt every `<uuid>.json` in `dir` and commit the good ones in ONE transaction. Rejected entries
    /// (bad auth, bad shape, id/filename mismatch, oversized) are counted and never logged. Returns the
    /// ids to delete server-side: every well-named file, committed or rejected. The caller writes
    /// `processed-ids` only after this returns, i.e. after COMMIT.
    static func process(dir: URL, key: SymmetricKey, store: SideStore) throws -> InboxSummary {
        var summary = InboxSummary()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        try store.db.exec("BEGIN IMMEDIATE;")
        do {
            for name in names where name.hasSuffix(".json") {
                let id = String(name.dropLast(5))
                guard isUUID(id) else { continue }     // not ours to delete; the wrapper filters these too
                summary.processedIds.append(id)
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)), data.count <= 16 * 1024,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      (obj["v"] as? NSNumber)?.intValue == 1, (obj["id"] as? String) == id,
                      let n = obj["nonceB64"] as? String, let c = obj["ciphertextB64"] as? String,
                      let plain = try? InboxCrypto.open(nonceB64: n, ciphertextB64: c, id: id, key: key),
                      let entry = EntryParser.parse(plain) else {
                    summary.rejected += 1
                    continue
                }
                if try store.isIngested(id) { summary.duplicate += 1; continue }
                try store.apply(entry, id: id)
                summary.committed += 1
            }
            try store.db.exec("COMMIT;")
        } catch {
            try? store.db.exec("ROLLBACK;")
            throw error
        }
        return summary
    }
}

/// `<stateDir>/items.json`: `{"v":1,"items":[{"id","label","legacy": "<NOOP journal question>"|null}]}`.
/// Never in git (it names medications). Missing or malformed => no items, never a failure.
struct LifestyleItem { var id: String; var label: String; var legacy: String? }

enum LifestyleItems {
    static func load(stateDir: URL) -> [LifestyleItem] {
        guard let data = try? Data(contentsOf: stateDir.appendingPathComponent("items.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["items"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, EntryParser.itemMatches(id),
                  let label = d["label"] as? String, !label.isEmpty else { return nil }
            return LifestyleItem(id: id, label: label, legacy: d["legacy"] as? String)
        }
    }
}

extension EntryParser {
    static func itemMatches(_ s: String) -> Bool { matches(itemRe, s) }
}

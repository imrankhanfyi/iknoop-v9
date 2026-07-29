import Foundation
import SQLite3

/// Minimal read-only SQLite wrapper.
///
/// WHY `mode=ro` AND NOT `immutable=1`: the NOOP store is a live WAL database that NOOP.app writes
/// while this tool runs. `immutable=1` tells SQLite to assume the file cannot change, which makes it
/// skip locking *and ignore the -wal file entirely*. Measured consequences on this store:
///   - it reads STALE data (the newest night/day live in the WAL) while reporting
///     `journal_mode: delete`, and
///   - a read concurrent with a checkpoint returns `database disk image is malformed`, or worse,
///     silently returns a torn cross-table snapshot.
/// `mode=ro` participates in WAL locking, which is exactly why it is safe. It does write the `-shm`
/// index to take a read mark; that is not a write to the database. If `-shm` cannot be created the
/// open fails loudly with SQLITE_READONLY_CANTINIT — that must NOT be "fixed" by falling back to
/// `immutable=1`.
final class ReadOnlyDatabase {
    private var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        // Percent-encode for the URI form; a space in "Application Support" must not split the URI.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("?")
        allowed.remove("#")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let uri = "file://\(encoded)?mode=ro"
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close_v2(db)
            throw PublishError("cannot open \(path) read-only: \(msg)")
        }
        self.handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    /// A single scalar-producing query. Returns nil when the query yields no row.
    func scalar(_ sql: String) throws -> SQLValue? {
        var out: SQLValue?
        try query(sql) { row in if out == nil { out = row.value(0) } }
        return out
    }

    /// Run `sql`, invoking `each` once per row. Column access is by index.
    func query(_ sql: String, _ each: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PublishError("prepare failed: \(String(cString: sqlite3_errmsg(handle)))\nSQL: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try each(Row(stmt: stmt))
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw PublishError("step failed: \(String(cString: sqlite3_errmsg(handle)))\nSQL: \(sql)")
            }
        }
    }

    /// The value of a `PRAGMA` that returns a single text column (e.g. journal_mode).
    func pragmaText(_ name: String) -> String? {
        (try? scalar("PRAGMA \(name);"))?.flatMap { $0.text }
    }

    struct Row {
        let stmt: OpaquePointer
        func value(_ i: Int32) -> SQLValue {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL: return .null
            case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, i)))
            case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
            default:
                guard let c = sqlite3_column_text(stmt, i) else { return .null }
                return .text(String(cString: c))
            }
        }
        func int(_ i: Int32) -> Int? { value(i).int }
        func double(_ i: Int32) -> Double? { value(i).double }
        func text(_ i: Int32) -> String? { value(i).text }
        func bool(_ i: Int32) -> Bool { (value(i).int ?? 0) != 0 }
    }
}

enum SQLValue: Equatable {
    case null, int(Int), double(Double), text(String)

    var int: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .text(let s): return Int(s)
        case .null: return nil
        }
    }
    var double: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s)
        case .null: return nil
        }
    }
    var text: String? {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .null: return nil
        }
    }
}

/// Convenience so `scalar()`'s double-optional reads naturally at call sites.
extension Optional where Wrapped == SQLValue {
    func flatMap<T>(_ f: (SQLValue) -> T?) -> T? {
        guard let self else { return nil }
        return f(self)
    }
}

struct PublishError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

/// SQL string literal quoting (single quotes doubled). Only used for internal constants — no user
/// input reaches SQL in this tool — but kept correct so that stays true if it ever does.
func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

import Foundation
import GRDB

/// The user-selected meaning of a point on a sleep graph.
public enum SleepAnnotationType: Int, CaseIterable, Codable, Sendable {
    case inBed = 0
    case fellAsleep = 1
    case awakeInBed = 2
    case brieflyGotUp = 3
    case arose = 4
}

/// One user-authored annotation on a device's sleep graph.
///
/// Its natural key is `(deviceId, tsMs, type)`, permitting multiple annotation types at one instant
/// while making a repeated insertion idempotent.
public struct SleepAnnotationRow: Equatable, Codable, Sendable {
    public let deviceId: String
    public let tsMs: Int64
    public let type: SleepAnnotationType

    public init(deviceId: String, tsMs: Int64, type: SleepAnnotationType) {
        self.deviceId = deviceId
        self.tsMs = tsMs
        self.type = type
    }

    static func decode(_ row: Row) -> SleepAnnotationRow {
        let rawType: Int = row["type"]
        return SleepAnnotationRow(
            deviceId: row["deviceId"],
            tsMs: row["tsMs"],
            type: SleepAnnotationType(rawValue: rawType)!
        )
    }
}

extension WhoopStore {
    /// Rounds an epoch millisecond timestamp to its nearest 30-second boundary. Halfway points round up.
    public static func snappedTsMs(_ tsMs: Int64) -> Int64 {
        (tsMs + 15_000) / 30_000 * 30_000
    }

    /// Reads annotations in an inclusive timestamp window, ordered by timestamp then annotation type.
    public func sleepAnnotations(deviceId: String, fromTsMs: Int64, toTsMs: Int64) async throws -> [SleepAnnotationRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT deviceId, tsMs, type FROM sleepAnnotation
                WHERE deviceId = ? AND tsMs >= ? AND tsMs <= ?
                ORDER BY tsMs ASC, type ASC
                """, arguments: [deviceId, fromTsMs, toTsMs]).map(SleepAnnotationRow.decode)
        }
    }

    /// Adds an annotation if its natural key is not already present.
    public func insertSleepAnnotation(_ row: SleepAnnotationRow) async throws {
        try syncWrite { db in
            try Self.insertSleepAnnotation(row, into: db)
        }
    }

    /// Moves an annotation to a new timestamp. A pre-existing identical target is retained once.
    public func moveSleepAnnotation(_ row: SleepAnnotationRow, toTsMs: Int64) async throws {
        try syncWrite { db in
            try Self.deleteSleepAnnotation(row, from: db)
            try Self.insertSleepAnnotation(
                SleepAnnotationRow(deviceId: row.deviceId, tsMs: toTsMs, type: row.type),
                into: db
            )
        }
    }

    /// Replaces an annotation's type at the same timestamp. A pre-existing identical target is retained once.
    public func replaceSleepAnnotation(_ row: SleepAnnotationRow, with type: SleepAnnotationType) async throws {
        try syncWrite { db in
            try Self.deleteSleepAnnotation(row, from: db)
            try Self.insertSleepAnnotation(
                SleepAnnotationRow(deviceId: row.deviceId, tsMs: row.tsMs, type: type),
                into: db
            )
        }
    }

    /// Removes one annotation by its natural key.
    public func deleteSleepAnnotation(_ row: SleepAnnotationRow) async throws {
        try syncWrite { db in
            try Self.deleteSleepAnnotation(row, from: db)
        }
    }

    private static func insertSleepAnnotation(_ row: SleepAnnotationRow, into db: Database) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO sleepAnnotation (deviceId, tsMs, type) VALUES (?, ?, ?)",
            arguments: [row.deviceId, row.tsMs, row.type.rawValue]
        )
    }

    private static func deleteSleepAnnotation(_ row: SleepAnnotationRow, from db: Database) throws {
        try db.execute(
            sql: "DELETE FROM sleepAnnotation WHERE deviceId = ? AND tsMs = ? AND type = ?",
            arguments: [row.deviceId, row.tsMs, row.type.rawValue]
        )
    }
}

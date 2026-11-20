import Foundation

/// Always-on, durable copy of the in-memory strap log (`BLEManager.log`). The in-memory log dies with
/// every relaunch, which destroyed the evidence for post-wake sync stalls; this keeps the last ~2 MB.
///
/// One line per entry: a full local ISO-8601 date-time, a space, the log string, "\n". Lives at
/// `<AppSupport>/OpenWhoop/strap-log.txt` (same directory as `PuffinEventLog`), rotating to
/// `strap-log.1.txt` when the live file exceeds `maxBytes`. Not gated by any toggle. Every failure is
/// swallowed: a diagnostics log must never affect the connection path.
final class StrapLogFile {

    private let directoryOverride: URL?
    private let maxBytes: Int
    private var handle: FileHandle?
    private var disabled = false

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        return f
    }()

    init(directory: URL? = nil, maxBytes: Int = 1_000_000) {
        self.directoryOverride = directory
        self.maxBytes = maxBytes
    }

    deinit { try? handle?.close() }

    private func directory() throws -> URL {
        let fm = FileManager.default
        let dir: URL
        if let directoryOverride {
            dir = directoryOverride
        } else {
            dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
                .appendingPathComponent("OpenWhoop", isDirectory: true)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func append(_ message: String, at date: Date = Date()) {
        guard !disabled else { return }
        let line = Self.stampFormatter.string(from: date) + " " + message + "\n"
        do {
            var h = try openHandle()
            if try h.offset() > UInt64(maxBytes) {
                close()
                h = try openHandle()
            }
            try h.write(contentsOf: Data(line.utf8))
        } catch {
            close()
            disabled = true
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let dir = try directory()
        let url = dir.appendingPathComponent("strap-log.txt")
        let fm = FileManager.default
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            let old = dir.appendingPathComponent("strap-log.1.txt")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        return h
    }
}

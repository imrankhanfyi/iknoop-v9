import XCTest
@testable import Strand

final class StrapLogFileTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrapLogFileTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testAppendsLinesWithDatePrefix() {
        let dir = tempDir()
        let log = StrapLogFile(directory: dir)
        log.append("[10:00:00] hello")
        log.append("[10:00:01] world")
        log.close()
        let lines = read(dir.appendingPathComponent("strap-log.txt"))
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" [10:00:00] hello"))
        XCTAssertTrue(lines[1].hasSuffix(" [10:00:01] world"))
        // ISO-8601 date-time prefix: yyyy-MM-ddTHH:mm:ss…
        let prefix = String(lines[0].prefix(19))
        XCTAssertNotNil(prefix.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#, options: .regularExpression))
    }

    func testRotatesToDotOneWhenOverMax() {
        let dir = tempDir()
        let log = StrapLogFile(directory: dir, maxBytes: 200)
        for i in 0..<8 { log.append("line-\(i) ................") }
        log.close()
        let live = dir.appendingPathComponent("strap-log.txt")
        let old = dir.appendingPathComponent("strap-log.1.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(read(old).contains("line-0 "))
        XCTAssertTrue(read(live).contains("line-7 "))
        XCTAssertFalse(read(live).contains("line-0 "))
    }

    func testSecondRotationReplacesOldDotOne() {
        let dir = tempDir()
        let log = StrapLogFile(directory: dir, maxBytes: 100)
        for i in 0..<60 { log.append("line-\(i) ................") }
        log.close()
        let old = read(dir.appendingPathComponent("strap-log.1.txt"))
        XCTAssertFalse(old.contains("line-0 "), "the first generation must have been replaced")
        XCTAssertTrue(old.contains("line-"))
        XCTAssertTrue(read(dir.appendingPathComponent("strap-log.txt")).contains("line-59 "))
    }
}

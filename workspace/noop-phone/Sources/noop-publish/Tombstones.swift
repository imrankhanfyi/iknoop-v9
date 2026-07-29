import Foundation

/// User "this isn't real" exclusions.
///
/// THE PROBLEM THIS SOLVES: two of the app's delete/dismiss features are NOT recorded in SQLite —
/// they live in the sandboxed app's UserDefaults:
///   - `sleep.dismissedSessions`     (`Repository.dismissedSleepDefaultsKey`)
///   - `workouts.dismissedDetected`  (`WorkoutSource.dismissedDefaultsKey`)
/// A detected workout row is wiped and re-derived on every analyze pass, so deleting the ROW would
/// only hide it until the next pass; the durable record is the span list. Consequently a viewer that
/// reads only the database RESURRECTS every night and bout the user has dismissed.
///
/// Both keys are absent on this install today, so there is nothing to exclude yet — but the first time
/// a spurious night is deleted, a viewer without this would disagree with the app and look broken.
struct Tombstones {
    var dismissedSleepSpans: [(start: Int, end: Int)] = []
    var dismissedWorkoutSpans: [(start: Int, end: Int)] = []

    static let sleepKey = "sleep.dismissedSessions"
    static let workoutKey = "workouts.dismissedDetected"

    /// Read the sandboxed container's preferences plist. `UserDefaults(suiteName:)` will not reach
    /// another app's sandboxed domain, so the plist is parsed directly.
    static func load(bundleId: String = "com.noopapp.noop") -> Tombstones {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Containers/\(bundleId)/Data/Library/Preferences/\(bundleId).plist"),
            home.appendingPathComponent("Library/Preferences/\(bundleId).plist"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any] else { continue }
            var t = Tombstones()
            t.dismissedSleepSpans = parseSpans(dict[sleepKey] as? [String] ?? [])
            t.dismissedWorkoutSpans = parseSpans(dict[workoutKey] as? [String] ?? [])
            return t
        }
        return Tombstones()
    }

    /// Parse "startTs:endTs" tokens. Malformed or non-positive-width entries are dropped, so a corrupt
    /// value can never hide everything — matching `WorkoutSource.parseDismissedSpans`.
    static func parseSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (start: a, end: b)
        }
    }
}

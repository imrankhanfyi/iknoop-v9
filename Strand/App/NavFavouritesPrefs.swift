import Foundation

// MARK: - User-pinned navigation favourites
//
// The macOS sidebar (`RootView`) and the iPhone More tab (`RootTabView`) both group ~28 destinations into
// a handful of collapsible sections, so most screens sit one expand-plus-click away. This lets the user PIN
// the handful they actually live in to an always-open "Favourites" block at the top of either shell, and
// reorder within it.
//
// Display-only: nothing is computed or stored differently, and no destination is ever hidden. A favourited
// row is PROMOTED out of its home group rather than duplicated - a macOS `List(selection:)` cannot carry two
// rows with the same `.tag`, and one mental model beats two.
//
// This type holds ONLY the pure, platform-agnostic key + encode/decode/mutations - no UIKit, no SwiftUI - so
// it compiles into both the macOS and iOS targets and is unit-tested headlessly in `StrandTests` (the same
// split `MoreSectionPrefs` uses). The stored value is a comma-joined list of `NavItem.favouriteID`s in
// DISPLAY ORDER, so unlike `MoreSectionPrefs.encode` it must NOT sort.
//
// Deliberately NOT in the `.noopbak` whitelist (`BackupSettings.swift`) and not yet mirrored on Android:
// the id vocabulary is shaped like Android's existing route names so a future Kotlin twin can read the same
// string, but nothing crosses a platform boundary today.

/// Pure persistence model for the user's pinned navigation favourites. The stored value is a comma-joined
/// list of stable destination ids in display order; an EMPTY string is the valid default (no favourites),
/// never a seed order. Vocabulary is deliberately NOT validated here - each shell `compactMap`s the ids to
/// the destinations it can actually reach, which differ (the iPhone More list has no Today/Sleep/Trends row,
/// and no `NavItem` exists for the iOS-only Shortcuts screens).
enum NavFavouritesPrefs {
    /// The `@AppStorage` / UserDefaults key. Unprefixed, matching `more.expandedSections`; an Android twin
    /// would namespace it as `noop.nav.favourites`.
    static let storageKey = "nav.favourites"

    /// No favourites at first run - the sidebar reads exactly as it does today apart from an empty-state
    /// hint. An empty stored string means the same thing, so there is no "never set" vs "cleared" split.
    static let defaultCSV = ""

    /// Encode ids to the stored string, preserving DISPLAY ORDER (no sorting - the order IS the value).
    static func encode(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    /// Decode the stored string to ids in display order. Blank tokens are dropped and duplicates collapse
    /// to their FIRST occurrence, so a hand-edited or half-written value degrades to something renderable
    /// rather than listing a row twice.
    static func decode(_ csv: String) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for token in csv.split(separator: ",") {
            let id = token.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// Pin `id` (appended to the END, so a new favourite never displaces an existing one) or unpin it if
    /// it is already present.
    static func toggling(_ id: String, in ids: [String]) -> [String] {
        guard !id.isEmpty else { return ids }
        if let at = ids.firstIndex(of: id) {
            var out = ids
            out.remove(at: at)
            return out
        }
        return ids + [id]
    }

    /// Promote `id` to the first position. A no-op if it isn't pinned or is already first.
    static func movingToTop(_ id: String, in ids: [String]) -> [String] {
        guard let at = ids.firstIndex(of: id), at != ids.startIndex else { return ids }
        var out = ids
        out.remove(at: at)
        out.insert(id, at: 0)
        return out
    }

    /// Shift `id` by `offset` positions (-1 up, +1 down). CLAMPED, not wrapped: moving the first item up or
    /// the last item down is a no-op, so the context-menu commands can be offered unconditionally without
    /// an item teleporting from one end of the list to the other.
    static func moving(_ id: String, by offset: Int, in ids: [String]) -> [String] {
        guard offset != 0, let at = ids.firstIndex(of: id) else { return ids }
        let to = at + offset
        guard ids.indices.contains(to) else { return ids }
        var out = ids
        out.remove(at: at)
        out.insert(id, at: to)
        return out
    }
}

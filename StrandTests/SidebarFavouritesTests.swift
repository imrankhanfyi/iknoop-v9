import XCTest
@testable import Strand

/// Guards the sidebar "Favourites" feature: an always-open block pinned atop the macOS sidebar that
/// PROMOTES a pinned `NavItem` out of its home `NavGroup` rather than duplicating it — a `List(selection:)`
/// cannot carry two rows tagged with the same `NavItem`, and duplicating would also double-count it in
/// `NavGroup.all.flatMap(\.items)`, breaking `MoreListParityTests.testEveryNavItemIsReachableInExactlyOneGroup`.
///
/// `NavItem.favouriteID` is the stable, snake_case, persisted id `NavFavouritesPrefs` stores (shaped like
/// Android's `Destination` route names for a future Kotlin twin); `rawValue` is the English display label
/// and must never be used for persistence, since it drifts with copy edits.
final class SidebarFavouritesTests: XCTestCase {

    // MARK: - favouriteID

    /// Every case must have a non-empty, unique, snake_case id — the CSV persistence format that
    /// `NavFavouritesPrefs` round-trips through `@AppStorage`.
    func testFavouriteIDsAreNonEmptyUniqueAndSnakeCase() {
        let pattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]*$")
        var seen: Set<String> = []
        for item in NavItem.allCases {
            let id = item.favouriteID
            XCTAssertFalse(id.isEmpty, "NavItem.\(item.rawValue) has an empty favouriteID.")
            let range = NSRange(id.startIndex..., in: id)
            XCTAssertNotNil(pattern.firstMatch(in: id, range: range),
                            "NavItem.\(item.rawValue).favouriteID (\"\(id)\") is not snake_case.")
            XCTAssertTrue(seen.insert(id).inserted,
                          "favouriteID \"\(id)\" is not unique — NavItem.\(item.rawValue) collides.")
        }
        XCTAssertEqual(seen.count, NavItem.allCases.count)
    }

    /// `init?(favouriteID:)` must round-trip every case (never a second hand-maintained switch that could
    /// drift from `favouriteID`), and must reject an id no case owns.
    func testFavouriteIDInitRoundTripsEveryCaseAndRejectsUnknownIds() {
        for item in NavItem.allCases {
            XCTAssertEqual(NavItem(favouriteID: item.favouriteID), item,
                           "NavItem(favouriteID:) failed to round-trip NavItem.\(item.rawValue).")
        }
        XCTAssertNil(NavItem(favouriteID: "nope"))
        XCTAssertNil(NavItem(favouriteID: ""))
    }

    /// Pins the Android-route-parity spelling — the whole reason `favouriteID` isn't derived from
    /// `rawValue`: these specific ids are chosen to match existing Android `Destination` route names /
    /// iOS `MoreDestination` case names, so a rename here is a deliberate, visible break.
    func testAndroidParityIDsArePinned() {
        XCTAssertEqual(NavItem.insightsHub.favouriteID, "insights_hub")
        XCTAssertEqual(NavItem.smartAlarm.favouriteID, "smart_alarm")
        XCTAssertEqual(NavItem.backupSync.favouriteID, "backup_sync")
        XCTAssertEqual(NavItem.testCentre.favouriteID, "test_centre")
        XCTAssertEqual(NavItem.labBook.favouriteID, "lab_book")
        XCTAssertEqual(NavItem.appleHealth.favouriteID, "apple_health")
        XCTAssertEqual(NavItem.fusedRecord.favouriteID, "fused_record")
        XCTAssertEqual(NavItem.dataSources.favouriteID, "data_sources")
        // Intentional: matches the iOS `MoreDestination.miBand` case name, not the `xiaomi` case name
        // itself — Android has no route for this destination yet.
        XCTAssertEqual(NavItem.xiaomi.favouriteID, "mi_band")
    }

    // MARK: - RootView.favouriteItems(from:)

    /// Decoding drops any id this shell can't resolve to a `NavItem` (a stale id from a future shell, or a
    /// hand-edited default), rather than crashing or inserting a placeholder — and preserves display order.
    func testFavouriteItemsFromCSVDropsUnknownIdsAndPreservesOrder() {
        let items = RootView.favouriteItems(from: "sleep,nope,today,workouts")
        XCTAssertEqual(items, [.sleep, .today, .workouts])
    }

    func testFavouriteItemsFromEmptyCSVIsEmpty() {
        XCTAssertEqual(RootView.favouriteItems(from: ""), [])
    }

    // MARK: - RootView.rows(in:favourites:query:) — the promotion + shape-branch regression guard

    /// A favourited row is PROMOTED out of its home group: `rows(in:...)` must exclude it while preserving
    /// the relative order of what remains.
    func testRowsExcludesFavouritedItemsPreservingOrderOfTheRest() {
        let body = NavGroup.all.first { $0.id == "body" }!
        let rows = RootView.rows(in: body, favourites: [.live], query: "")
        XCTAssertEqual(rows, [.workouts, .health, .stress, .intervals, .breathe])
    }

    /// If every item in a group is favourited, the group has nothing left to show — `rows(in:...)` returns
    /// empty (which is what makes the `!visible.isEmpty` branch in `RootView.body` drop the group's header).
    func testRowsIsEmptyWhenEveryItemInTheGroupIsFavourited() {
        let sleep = NavGroup.all.first { $0.id == "sleep" }!
        XCTAssertEqual(RootView.rows(in: sleep, favourites: [.sleep], query: ""), [])
    }

    /// The search filter still applies on top of the favourites subtraction: a query that only matches an
    /// already-favourited row (removed) yields nothing; one that matches a non-favourited row still hits.
    func testRowsStillAppliesTheSearchFilterAfterSubtractingFavourites() {
        let body = NavGroup.all.first { $0.id == "body" }!
        // "Live" is favourited (removed) — searching "Live" should find nothing left in the group.
        XCTAssertEqual(RootView.rows(in: body, favourites: [.live], query: "Live"), [])
        // "Health" is not favourited — searching "Health" should still find it.
        XCTAssertEqual(RootView.rows(in: body, favourites: [.live], query: "Health"), [.health])
    }

    /// The whole reason favourite-subtraction is confined to `RootView.rows(in:...)` rather than rebuilding
    /// `NavGroup` values: `RootView.body`'s render loop branches on `group.items.count == 1` to pick a bare
    /// row vs. a `DisclosureGroup` with a header. If subtraction ever touched `NavGroup.all` (or a synthetic
    /// copy of it) directly, a 6-row group reduced to 1 remaining row would misreport as a genuinely
    /// single-item group and silently lose its header. Pin that `NavGroup.all` itself is never mutated by
    /// any of the favourites machinery: its total row count must be identical before and after exercising
    /// `rows(in:...)` with a favourites set that empties out whole groups.
    func testNavGroupAllIsNeverMutatedBySubtraction() {
        let before = NavGroup.all.flatMap(\.items).count
        for group in NavGroup.all {
            _ = RootView.rows(in: group, favourites: group.items, query: "")
        }
        let after = NavGroup.all.flatMap(\.items).count
        XCTAssertEqual(before, after, "NavGroup.all must stay the literal, untransformed static source of truth.")
        XCTAssertEqual(before, NavItem.allCases.count)
    }

    // MARK: - RootView.favouriteRows(from:query:)

    func testFavouriteRowsAppliesTheSameSearchPredicate() {
        let favs: [NavItem] = [.sleep, .workouts]
        XCTAssertEqual(RootView.favouriteRows(from: favs, query: ""), favs)
        XCTAssertEqual(RootView.favouriteRows(from: favs, query: "Sleep"), [.sleep])
        XCTAssertEqual(RootView.favouriteRows(from: favs, query: "   "), favs, "Whitespace-only query is no query.")
        XCTAssertEqual(RootView.favouriteRows(from: favs, query: "zzz"), [])
    }
}

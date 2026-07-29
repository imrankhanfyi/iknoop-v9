import XCTest
@testable import Strand

/// Pins the sidebar/More-tab pinned-favourites persistence (`NavFavouritesPrefs`). The behaviour that must
/// never regress: the user's pin set and its DISPLAY ORDER survive encode/decode round trips, and the
/// mutation helpers (`toggling`, `movingToTop`, `moving(by:)`) behave predictably enough that the context
/// menu can offer them unconditionally. Unlike its twin `MoreSectionPrefs.encode`, `encode` here must NOT
/// sort - the order IS the value.
final class NavFavouritesPrefsTests: XCTestCase {

    func testStorageKeyAndDefaultCSVArePersistedContracts() {
        // These are on-disk contracts (UserDefaults key + seed value); pin them so a rename is deliberate.
        XCTAssertEqual(NavFavouritesPrefs.storageKey, "nav.favourites")
        XCTAssertEqual(NavFavouritesPrefs.defaultCSV, "")
    }

    func testDecodeEmptyStringIsEmptyArray() {
        // No favourites at first run - an empty stored string means "none", not "unset".
        XCTAssertEqual(NavFavouritesPrefs.decode(""), [])
    }

    func testDecodePreservesOrderNotSorted() {
        // The key difference from MoreSectionPrefs: the stored order IS the display order, so decode must
        // never reorder tokens alphabetically or otherwise.
        XCTAssertEqual(NavFavouritesPrefs.decode("sleep,today"), ["sleep", "today"])
        XCTAssertEqual(NavFavouritesPrefs.decode("today,sleep"), ["today", "sleep"])
    }

    func testDecodeCollapsesDuplicatesToFirstOccurrence() {
        // A hand-edited or half-written value degrades to something renderable rather than listing a row
        // twice; the FIRST occurrence wins so a later duplicate can't silently jump the row's position.
        XCTAssertEqual(NavFavouritesPrefs.decode("a,b,a"), ["a", "b"])
    }

    func testDecodeIgnoresBlankAndStrayTokensAndTrimsWhitespace() {
        XCTAssertEqual(NavFavouritesPrefs.decode("a,,  ,b"), ["a", "b"])
        XCTAssertEqual(NavFavouritesPrefs.decode("  a  , b"), ["a", "b"])
    }

    func testEncodeDecodeRoundTripsMultiElementList() {
        let ids = ["today", "sleep", "trends", "recovery"]
        XCTAssertEqual(NavFavouritesPrefs.decode(NavFavouritesPrefs.encode(ids)), ids)
    }

    func testTogglingAppendsToEndWhenAbsent() {
        // A new favourite must never displace an existing one, so it lands at the END, not the front.
        XCTAssertEqual(NavFavouritesPrefs.toggling("trends", in: ["today", "sleep"]), ["today", "sleep", "trends"])
    }

    func testTogglingRemovesWhenPresentLeavingRestInOrder() {
        XCTAssertEqual(NavFavouritesPrefs.toggling("sleep", in: ["today", "sleep", "trends"]), ["today", "trends"])
    }

    func testTogglingIgnoresEmptyId() {
        // Guards the `!id.isEmpty` branch: an empty id must never be appended as a phantom favourite.
        XCTAssertEqual(NavFavouritesPrefs.toggling("", in: ["today"]), ["today"])
    }

    func testMovingToTopPromotesToFirstPosition() {
        XCTAssertEqual(NavFavouritesPrefs.movingToTop("trends", in: ["today", "sleep", "trends"]),
                       ["trends", "today", "sleep"])
    }

    func testMovingToTopIsNoOpWhenAlreadyFirst() {
        XCTAssertEqual(NavFavouritesPrefs.movingToTop("today", in: ["today", "sleep"]), ["today", "sleep"])
    }

    func testMovingToTopIsNoOpWhenIdAbsent() {
        XCTAssertEqual(NavFavouritesPrefs.movingToTop("missing", in: ["today", "sleep"]), ["today", "sleep"])
    }

    func testMovingByOffsetIsClampedNotWrappedAtEitherEnd() {
        // Moving the first item up (or the last item down) must be a no-op, never a wraparound to the
        // opposite end - the context-menu commands are offered unconditionally and must never crash or
        // teleport a row.
        let ids = ["today", "sleep", "trends"]
        XCTAssertEqual(NavFavouritesPrefs.moving("today", by: -1, in: ids), ids)
        XCTAssertEqual(NavFavouritesPrefs.moving("trends", by: 1, in: ids), ids)
    }

    func testMovingByOffsetSwapsWithNeighborForMiddleElement() {
        let ids = ["today", "sleep", "trends"]
        XCTAssertEqual(NavFavouritesPrefs.moving("sleep", by: -1, in: ids), ["sleep", "today", "trends"])
        XCTAssertEqual(NavFavouritesPrefs.moving("sleep", by: 1, in: ids), ["today", "trends", "sleep"])
    }

    func testMovingByZeroIsNoOp() {
        let ids = ["today", "sleep", "trends"]
        XCTAssertEqual(NavFavouritesPrefs.moving("sleep", by: 0, in: ids), ids)
    }

    func testMovingByOffsetIsNoOpWhenIdAbsent() {
        let ids = ["today", "sleep"]
        XCTAssertEqual(NavFavouritesPrefs.moving("missing", by: -1, in: ids), ids)
        XCTAssertEqual(NavFavouritesPrefs.moving("missing", by: 1, in: ids), ids)
    }

    func testMutationsDoNotModifyTheInputArray() {
        // Swift value semantics make this trivial today, but assert it once so a future inout/reference
        // refactor of these helpers is caught by a test rather than discovered as a UI glitch.
        let original = ["today", "sleep", "trends"]
        let ids = original

        _ = NavFavouritesPrefs.toggling("recovery", in: ids)
        _ = NavFavouritesPrefs.movingToTop("trends", in: ids)
        _ = NavFavouritesPrefs.moving("sleep", by: 1, in: ids)

        XCTAssertEqual(ids, original)
    }
}

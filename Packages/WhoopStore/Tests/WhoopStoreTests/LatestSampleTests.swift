import XCTest
import WhoopProtocol
@testable import WhoopStore

final class LatestSampleTests: XCTestCase {
    func testLatestHRSampleTs() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        // No rows yet → nil.
        let empty = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertNil(empty)
        // Insert HR rows at ts 100 and 250; latest = 250.
        let s = Streams(hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 250, bpm: 61)])
        _ = try await store.insert(s, deviceId: "d")
        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 250)
    }

    /// The stuck-strap watchdog frontier must advance on a PPG-only offload too (#156): a v26
    /// WHOOP 5 night with no measured HR still has a real data frontier from its PPG rows.
    func testLatestHRSampleTsIncludesPpgFallbackRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "d")
        _ = try await store.insert(
            Streams(ppgHr: [PpgHrSample(ts: 300, bpm: 62, conf: 0.8)]), deviceId: "d")

        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 300)
    }

    /// The MOTION frontier. Gravity arrives only through the historical offload, so this is the
    /// ceiling on how far a detected night can reach; the Sleep screen compares it with the HR
    /// frontier to tell a finished night from one still mid-offload.
    func testLatestGravitySampleTs() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        // No rows yet → nil (a fresh install must not read as a lagging offload).
        let empty = try await store.latestGravitySampleTs(deviceId: "d")
        XCTAssertNil(empty)

        _ = try await store.insert(Streams(gravity: [
            GravitySample(ts: 100, x: 0, y: 0, z: 1.0),
            GravitySample(ts: 250, x: 0, y: 0, z: 1.0),
        ]), deviceId: "d")
        let latest = try await store.latestGravitySampleTs(deviceId: "d")
        XCTAssertEqual(latest, 250)
    }

    /// Scoped per device: another strap's motion must not advance this one's frontier.
    func testLatestGravitySampleTsIsScopedToDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        try await store.upsertDevice(id: "other", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(gravity: [GravitySample(ts: 100, x: 0, y: 0, z: 1.0)]), deviceId: "d")
        _ = try await store.insert(
            Streams(gravity: [GravitySample(ts: 900, x: 0, y: 0, z: 1.0)]), deviceId: "other")

        let mine = try await store.latestGravitySampleTs(deviceId: "d")
        XCTAssertEqual(mine, 100)
    }
}

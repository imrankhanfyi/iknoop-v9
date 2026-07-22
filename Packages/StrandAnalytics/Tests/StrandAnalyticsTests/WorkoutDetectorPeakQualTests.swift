import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Interval/HIIT bouts (e.g. CrossFit) fail the plain z2+ average gate because rest
/// periods between efforts drag the bout's mean time-in-zone below 50%, even when the
/// working intervals are near-max. These tests cover the sustained-peak fallback gate
/// (`peakQualZone` / `peakQualMinSeconds`) that qualifies such bouts on sustained zone
/// 3+ time instead of the average.
final class WorkoutDetectorPeakQualTests: XCTestCase {

    /// A day of rest (HR 55, still) with a bout embedded that alternates `highBpm`
    /// (moving) and `restBpm` (moving, to keep the motion gate satisfied throughout)
    /// on a 1-second cadence — an interval-style HR profile.
    private func intervalDay(boutStart: Int, boutDur: Int, highBpm: Int, restBpm: Int,
                             highFracPerCycle: Double = 0.5, cycleS: Int = 2) -> (hr: [HRSample], grav: [GravitySample]) {
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = boutStart - 30 * 60
        let dayEnd = boutStart + boutDur + 30 * 60
        for t in dayStart..<dayEnd {
            let inBout = t >= boutStart && t < boutStart + boutDur
            if inBout {
                let phase = (t - boutStart) % cycleS
                let high = Double(phase) < Double(cycleS) * highFracPerCycle
                hr.append(HRSample(ts: t, bpm: high ? highBpm : restBpm))
                let motionPhase = Double((t - boutStart) % 2) * 0.5
                grav.append(GravitySample(ts: t, x: motionPhase, y: 0, z: 1))
            } else {
                hr.append(HRSample(ts: t, bpm: 55))
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            }
        }
        return (hr, grav)
    }

    func testIntervalWorkoutQualifiesByPeakDespiteLowAvgTimeInZone() {
        // hrmax 190, resting 60 → hrReserve 130. Zone 3+ threshold = 60 + 0.70*130 = 151.
        // 40% high at 175 bpm (zone 3+), 60% rest at 120 bpm (zone 0/1) → z2+ average well
        // under 0.50, but the near-max intervals accumulate far more than 60s sustained.
        let start = 10_000_000
        let dur = 20 * 60  // 20 min
        let (hr, grav) = intervalDay(boutStart: start, boutDur: dur, highBpm: 175, restBpm: 120,
                                     highFracPerCycle: 0.4, cycleS: 10)
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, maxHR: 190, age: 40)
        XCTAssertEqual(sessions.count, 1)
        let w = sessions[0]
        let z2plus = (2...5).reduce(0.0) { $0 + (w.zoneTimePct[$1] ?? 0.0) } / 100.0
        XCTAssertLessThan(z2plus, WorkoutDetector.minIntensityZ2Plus,
                          "precondition: this bout must fail the average gate, or the test isn't exercising the peak fallback")
        XCTAssertGreaterThanOrEqual(w.peakHR, 164)
    }

    func testFlatModerateBoutWithLowPeakIsNotAWorkout() {
        // HR pinned at 120 the whole bout → zone 0 under hrmax 190/resting 60
        // (60 + 0.60*130 = 138 for zone 2). Neither the average gate nor the sustained
        // zone 3+ gate can pass — 0 sessions.
        let start = 11_000_000
        let dur = 20 * 60
        let (hr, grav) = intervalDay(boutStart: start, boutDur: dur, highBpm: 120, restBpm: 120)
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, maxHR: 190, age: 40)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testBriefNearMaxSpikeDoesNotQualify() {
        // Mostly 120 bpm (zone 0) with a lone ~20s burst at 175 bpm (zone 3+) — well
        // under the 60s sustained-peak bar, and the average gate also fails.
        let start = 12_000_000
        let dur = 6 * 60
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = start - 30 * 60
        let dayEnd = start + dur + 30 * 60
        let spikeStart = start + 60
        let spikeEnd = spikeStart + 20
        for t in dayStart..<dayEnd {
            let inBout = t >= start && t < start + dur
            let inSpike = t >= spikeStart && t < spikeEnd
            hr.append(HRSample(ts: t, bpm: inSpike ? 175 : (inBout ? 120 : 55)))
            if inBout {
                let phase = Double((t - start) % 2) * 0.5
                grav.append(GravitySample(ts: t, x: phase, y: 0, z: 1))
            } else {
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            }
        }
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, maxHR: 190, age: 40)
        XCTAssertTrue(sessions.isEmpty)
    }
}

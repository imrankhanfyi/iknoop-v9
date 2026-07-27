import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepReadoutTests: XCTestCase {
    func testHrDensityPerMinute() {
        // 600 HR samples over 599 s span -> ~60 samples/min.
        let start = 1_749_513_600
        let hr = (0..<600).map { HRSample(ts: start + $0, bpm: 50) }
        let d = SleepReadout.hrDensityPerMinute(hr: hr)
        XCTAssertEqual(d, 60.1, accuracy: 0.2)
    }

    func testHrDensityFewerThanTwoSamplesIsZero() {
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: []), 0)
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: [HRSample(ts: 0, bpm: 50)]), 0)
    }

    func testGravityCoverageFraction() {
        // Gravity spanning the whole HR window -> coverage ~1.0 (dense, not sparse).
        let start = 1_749_513_600
        let hr = (0..<600).map { HRSample(ts: start + $0, bpm: 50) }
        let grav = (0..<600).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
        let c = SleepReadout.gravityCoverageFraction(gravity: grav, hr: hr)
        XCTAssertGreaterThan(c, 0.9)
    }

    func testGravityCoverageSparseIsBelowGate() {
        // Gravity clumped into the first quarter of the HR window -> sparse (< sparseGravitySpanFrac).
        let start = 1_749_513_600
        let hr = (0..<600).map { HRSample(ts: start + $0, bpm: 50) }
        let grav = (0..<150).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
        let c = SleepReadout.gravityCoverageFraction(gravity: grav, hr: hr)
        XCTAssertLessThan(c, SleepStager.sparseGravitySpanFrac)
    }

    // MARK: - isNightProvisional

    /// The real case this was built for (2026-07-27). The Sleep screen showed the night ending
    /// 01:46 when the true wake was near 05:00, because the motion frontier had only reached 03:13
    /// while HR had streamed live to 11:31. That is a lag of 8 h 18 m, and it must read provisional.
    func testNightProvisionalWhenMotionFrontierTrailsByHours() {
        let hrFrontier = 1_784_474_000            // stands for 11:31 local
        let motionFrontier = hrFrontier - 29_880  // 8 h 18 m earlier, i.e. 03:13
        XCTAssertTrue(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: motionFrontier,
                                                     hrFrontierTs: hrFrontier,
                                                     backfilling: false))
    }

    /// The same morning's later catch-up, measured live: HR 12:34:10, gravity 11:08:16, a 5154 s
    /// lag. Still hours of motion outstanding relative to the threshold, so still provisional.
    func testNightProvisionalAtMidCatchUpGap() {
        let hrFrontier = 1_784_474_000
        XCTAssertTrue(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: hrFrontier - 5_154,
                                                     hrFrontierTs: hrFrontier,
                                                     backfilling: false))
    }

    /// Caught up: the two frontiers meet and no offload is running, so the night is final.
    func testNightNotProvisionalWhenFrontiersAgree() {
        let ts = 1_784_474_000
        XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: ts, hrFrontierTs: ts,
                                                      backfilling: false))
    }

    /// A small standing lag is normal on a caught-up strap (both frontiers advance in bursts) and
    /// must NOT badge the night. Guards the false-positive direction.
    func testNightNotProvisionalForSmallStandingLag() {
        let hrFrontier = 1_784_474_000
        let justUnder = hrFrontier - (SleepReadout.provisionalMotionLagS - 1)
        XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: justUnder,
                                                      hrFrontierTs: hrFrontier,
                                                      backfilling: false))
    }

    /// The sawtooth peak must not badge a finished night. A caught-up strap's lag climbs between
    /// offload bursts (gravity stalls at the end of a burst while HR keeps streaming live), so the
    /// worst normal lag is the offload cadence: 900 s, stretched to 2700 s on a low battery. Both
    /// must read as final, or a low-battery strap shows "still syncing" every cycle forever.
    func testNightNotProvisionalAtOffloadCadenceSawtoothPeak() {
        let hrFrontier = 1_784_474_000
        for cadenceS in [900, 2_700] {
            XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: hrFrontier - cadenceS,
                                                          hrFrontierTs: hrFrontier,
                                                          backfilling: false),
                           "a \(cadenceS)s lag is a normal inter-burst sawtooth, not a lagging offload")
        }
    }

    /// Term 1 stands alone: an offload running with the frontiers already level still means more
    /// motion is landing, so the night is not yet final.
    func testNightProvisionalWhileBackfillingEvenWithNoGap() {
        let ts = 1_784_474_000
        XCTAssertTrue(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: ts, hrFrontierTs: ts,
                                                     backfilling: true))
    }

    /// A fresh install has no samples on either stream. Absent frontiers are not evidence of a
    /// lagging offload, so nothing is badged.
    func testNightNotProvisionalWhenFrontiersMissing() {
        XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: nil, hrFrontierTs: nil,
                                                      backfilling: false))
        XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: nil,
                                                      hrFrontierTs: 1_784_474_000,
                                                      backfilling: false))
        XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: 1_784_474_000,
                                                      hrFrontierTs: nil, backfilling: false))
    }

    /// A motion frontier AHEAD of HR (possible when the offload lands motion while live HR is
    /// disconnected) is not a lagging offload either.
    func testNightNotProvisionalWhenMotionLeadsHR() {
        let hrFrontier = 1_784_474_000
        XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nil, motionFrontierTs: hrFrontier + 3_600,
                                                      hrFrontierTs: hrFrontier,
                                                      backfilling: false))
    }

    // MARK: - isNightProvisional, term 1's could-still-grow gate

    /// The noise case. Last night was final at 05:08 and by early afternoon the motion frontier had
    /// run roughly eight hours past it. A routine periodic offload fires every
    /// `backfillIntervalSeconds` while connected, so without this gate the pill would paint under a
    /// CORRECT wake time every quarter hour, all day, and mean nothing by the morning it matters.
    func testBackfillingDoesNotBadgeASettledNight() {
        let nightEnd = 1_784_474_000
        let motionFrontier = nightEnd + 470 * 60   // 05:08 night end vs a 12:58 frontier
        XCTAssertFalse(SleepReadout.isNightProvisional(nightEndTs: nightEnd,
                                                      motionFrontierTs: motionFrontier,
                                                      hrFrontierTs: motionFrontier,
                                                      backfilling: true))
    }

    /// The gate must NOT suppress the real case. At the reported 11:31 snapshot the night still read
    /// 01:46 while the motion frontier had reached 03:13: a delta of 87 minutes, inside the bound, so
    /// this night could still grow and an offload running over it is worth saying.
    func testBackfillingStillBadgesANightThatCanGrow() {
        let nightEnd = 1_784_474_000
        let motionFrontier = nightEnd + 87 * 60
        XCTAssertTrue(SleepReadout.isNightProvisional(nightEndTs: nightEnd,
                                                     motionFrontierTs: motionFrontier,
                                                     hrFrontierTs: motionFrontier,
                                                     backfilling: true))
    }

    /// The bound is the detector's own `nightContinuationGapMin`, inclusive: past it, later stillness
    /// opens a separate session instead of extending this night, so the window in which an extension
    /// could have been found is fully covered.
    func testCouldStillGrowBoundIsNightContinuationGap() {
        let nightEnd = 1_784_474_000
        let gapS = SleepStager.nightContinuationGapMin * 60
        XCTAssertTrue(SleepReadout.nightCouldStillGrow(nightEndTs: nightEnd,
                                                       motionFrontierTs: nightEnd + gapS))
        XCTAssertFalse(SleepReadout.nightCouldStillGrow(nightEndTs: nightEnd,
                                                        motionFrontierTs: nightEnd + gapS + 1))
        // Conservative on missing inputs: an unknown night end must not silently suppress the badge.
        XCTAssertTrue(SleepReadout.nightCouldStillGrow(nightEndTs: nil, motionFrontierTs: nightEnd))
        XCTAssertTrue(SleepReadout.nightCouldStillGrow(nightEndTs: nightEnd, motionFrontierTs: nil))
    }

    /// Term 2 is deliberately NOT gated on the same delta. The recompute lags the frontier, so on the
    /// real case the night read 01:46 against an 03:13 frontier: 87 minutes, only 3 short of the
    /// 90-minute bound. A slightly staler recompute would have pushed it past, and gating term 2 would
    /// then have suppressed exactly the signal this feature exists for. So a wide frontier gap badges
    /// the night even when the could-still-grow gate is shut.
    func testWideFrontierGapBadgesEvenWhenGateIsShut() {
        let nightEnd = 1_784_474_000
        let motionFrontier = nightEnd + 470 * 60          // gate shut: night is settled
        XCTAssertFalse(SleepReadout.nightCouldStillGrow(nightEndTs: nightEnd,
                                                        motionFrontierTs: motionFrontier))
        XCTAssertTrue(SleepReadout.isNightProvisional(nightEndTs: nightEnd,
                                                     motionFrontierTs: motionFrontier,
                                                     hrFrontierTs: motionFrontier + 29_880,
                                                     backfilling: false))
    }

    func testLastGateFiredParsesTaggedTail() {
        let tail = [
            "[sleep] gate run=0 spanS=1800 DROPPED gate=minSleepMin spanMin=30 minSleepMin=60",
            "[sleep] gate run=1 spanS=5400 KEPT gate=accepted spanMin=90 eff=0.9 restingHR=50 daytime=false",
        ]
        XCTAssertEqual(SleepReadout.lastGateFired(taggedTail: tail), "accepted")
    }

    func testLastGateFiredNilWhenNoGateLine() {
        XCTAssertNil(SleepReadout.lastGateFired(taggedTail: ["[sleep] sleep day=2021-06-17 totalSleepMin=420"]))
        XCTAssertNil(SleepReadout.lastGateFired(taggedTail: []))
    }
}

/// The Recovery / HRV live-readout parsers (Test Centre Group G). Twin of the Android TestReadout tests.
final class TestReadoutTests: XCTestCase {
    func testLastChargeBreakdownParsesScoreAndBand() {
        let tail = [
            "[recovery] charge day=2021-06-17 baseline hrv mean=50.0 spread=4.79 nValid=14 status=trusted",
            "[recovery] charge day=2021-06-17 score=62.5 band=yellow (logistic k=1.6 z0=-0.2)",
        ]
        XCTAssertEqual(TestReadout.lastChargeBreakdown(taggedTail: tail), "score=62.5 band=yellow")
    }

    func testLastChargeBreakdownFallsBackToNilReason() {
        let tail = ["[recovery] charge day=2021-06-17 nilScore reason=hrvBaselineNotUsable hrvStatus=calibrating hrvNValid=2 (need nValid>=4)"]
        XCTAssertEqual(TestReadout.lastChargeBreakdown(taggedTail: tail), "no score (hrvBaselineNotUsable)")
    }

    func testLastChargeBreakdownNilWhenNoTrace() {
        XCTAssertNil(TestReadout.lastChargeBreakdown(taggedTail: []))
        XCTAssertNil(TestReadout.lastChargeBreakdown(taggedTail: ["[sleep] gate run=0 ... gate=accepted"]))
    }

    func testLastChargeBreakdownPicksNewestDayNotLastEmitted() {
        // #343: the engine emits days NEWEST-FIRST, so the LAST line is the OLDEST window-edge day — a
        // cold-start nilScore. The panel must show the NEWEST day's real score, not that trailing nilScore.
        let tail = [
            "[recovery] charge day=2026-07-12 baseline hrv mean=44.8 spread=7.2 nValid=20 status=trusted",
            "[recovery] charge day=2026-07-12 score=99.78 band=green (logistic k=1.6 z0=-0.2)",
            "[recovery] charge day=2026-07-11 score=99.36 band=green (logistic k=1.6 z0=-0.2)",
            "[recovery] charge day=2026-07-09 nilScore reason=missingInput (hrv/rhr/hrvBaseline required)",
        ]
        XCTAssertEqual(TestReadout.lastChargeBreakdown(taggedTail: tail), "score=99.78 band=green")
    }

    func testLastChargeBreakdownReportsNilWhenNewestDayGenuinelyMissing() {
        // If the NEWEST day itself has no score (real missing input today), report THAT — don't fall
        // through to an older day's score and present a stale number as current.
        let tail = [
            "[recovery] charge day=2026-07-12 nilScore reason=missingInput (hrv/rhr/hrvBaseline required)",
            "[recovery] charge day=2026-07-11 score=88.0 band=green (logistic k=1.6 z0=-0.2)",
        ]
        XCTAssertEqual(TestReadout.lastChargeBreakdown(taggedTail: tail), "no score (missingInput)")
    }

    func testLastChargeBreakdownPrefersLastPassForNewestDay() {
        // Several recompute passes may be in the tail; the newest day's latest pass wins.
        let tail = [
            "[recovery] charge day=2026-07-12 score=50.0 band=yellow (..)",  // pass 1
            "[recovery] charge day=2026-07-11 score=40.0 band=yellow (..)",
            "[recovery] charge day=2026-07-12 score=72.0 band=green (..)",   // pass 2, newest day refreshed
            "[recovery] charge day=2026-07-11 score=41.0 band=yellow (..)",
        ]
        XCTAssertEqual(TestReadout.lastChargeBreakdown(taggedTail: tail), "score=72.0 band=green")
    }

    func testLastHrvComputationParsesRmssdFragment() {
        let tail = [
            "[hrv] hrv path=spot nInput=60 nClean=58 rejectedFraction=0.03",
            "[hrv] hrv rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms",
        ]
        XCTAssertEqual(TestReadout.lastHrvComputation(taggedTail: tail), "rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms")
    }

    func testLastHrvComputationReportsFilteredOut() {
        let tail = ["[hrv] hrv result=nil (a gate above refused the reading)"]
        XCTAssertEqual(TestReadout.lastHrvComputation(taggedTail: tail), "no reading (filtered out)")
    }
}

# Sleep screen: "still syncing" badge on a provisional night

**Date:** 2026-07-27
**Scope:** `Packages/WhoopStore` (new read), `Packages/StrandAnalytics/SleepReadout.swift` (pure
predicate), `Strand/Screens/SleepView.swift` (UI). Android twin is an explicit non-goal for this
change (see Non-goals): it is UI-only plus one read, so the parity contract's byte-identical clause
does not apply here.

## Problem

On 2026-07-27, NOOP displayed the previous night as ending at 01:46, while the actual wake was
around 05:00. The discrepancy was investigated against the live container DB
(`~/Library/Containers/com.noopapp.noop/.../OpenWhoop/whoop.sqlite`).

Nothing was broken in the analytics. `gravitySample`/`respSample` arrive only via the strap's
historical offload; `hrSample`/`rrInterval` also arrive from the live connection.
`SleepStager.detectSleep` builds its still-spine from gravity (`SleepStager.swift:858`:
`if grav.count < 2 { return [] }`); HR only confirms a run and cannot extend one. The displayed
wake time was therefore the motion-offload frontier, not a wake:

```
11:31  hr=11:31  motion=03:13  night_end=01:46  (2.99 h, RHR 72)   <-- what was reported
11:38  hr=11:38  motion=04:01  night_end=03:50  (5.06 h, RHR 64)
11:52  hr=11:52  motion=05:17  night_end=05:15  (6.47 h, RHR 64)
12:08  hr=12:07  motion=07:21  night_end=05:08  (tail re-detected slightly earlier)
```

Gravity from 01:46 to 03:23 showed near-total stillness (mean |Δ| ~0.002 g against the
`gravityStillThresholdG = 0.01` bar) with HR 67-72; the actual wake signature (HR rising to 92-98)
occurred at 05:08-05:16, confirming there was no real wake at 01:46.

A related hypothesis was tested and disproved: the HR gaps at 03:18 and 04:39 (31 minutes)
appeared large enough to break the run at `maxGapMin = 20`, but once the frontier passed that
region, `gravitySample` showed zero gaps over 60 seconds and a flat 60 samples/minute throughout.
Those gaps were BLE live-stream dropouts that the offload backfilled at 1 Hz; an HR gap in the
live-only tail is not a recording gap.

The night self-corrected once the offload finished, but only after a database probe explained it.
The underlying product gap is that a mid-offload night is presented as final. The natural user
reaction, tapping the pencil to fix the wake time, is actively harmful: `applySleepEdit` sets
`userEdited = 1`, and `upsertSleepSessions` (`MetricsCache.swift:138`) then freezes `endTs` against
every future recompute, permanently pinning the wrong value.

The intended outcome: when the displayed night is still provisional, the screen should say so,
beside the wake time, using the component the codebase already has for this.

## The mechanism already exists; it is in the wrong place

`SleepSyncingNote()` renders `StatePill("Syncing strap history…", tone: .accent, pulsing: true)`
(`ScreenScaffold.swift:199-212`). It is called at `SleepView.swift:2289`, inside
`private var emptyState`, addressing the case where no nights exist yet (#77), but a night that
exists and is short still reads as final. That is exactly this case. No new design-system
component is needed.

## Design

### 1. Signal, two terms OR'd

A night is treated as provisional when either of two conditions holds:

1. `live.backfilling`, already published by `BLEManager` (`state.backfilling`, set at line 1568,
   cleared in `exitBackfilling` at 1668).
2. `latestHRSampleTs − latestGravitySampleTs > provisionalMotionLagS`.

Both terms are load-bearing:

- **Term 2 is not redundant.** `backfilling` spans a single offload session
  (`HISTORY_START`→`HISTORY_COMPLETE`) and goes false between the chained sessions of a burst
  (`shouldRunPeriodicBackfill`, line 1978), so term 1 alone would make the badge flicker across
  exactly the multi-hour catch-up that matters. It also misses a stalled offload (hours
  outstanding, nothing running), which is live territory given `workspace/state.md` open item #1
  (reconnect churn).
- **Term 1 is not redundant.** It catches an active offload whose gap is still under the
  threshold.

Term 2's viability was challenged and verified, not assumed. The concern was that if HR only ever
arrived via the same offload as gravity, the two frontiers would move together and the gap would
stay near zero indefinitely. `exitBackfilling` (line 1661-1664) does note that live HR is opt-in.
However HR also arrives over the standard 0x2A37 profile, which NOOP subscribes to automatically:

- `:21-22`: "the independent low-bandwidth 0x2A37 standard HR profile, which NOOP already
  subscribes"
- `:462`: `heartRateChar = 2A37`, "HR + R-R (works unbonded)"
- `:2040`: stopping the opt-in Live-tab streams notes "the lightweight 0x2A37 HR keeps recording
  if firmware emits it"
- `:2579` / `:3415-3416`: `heartRateService` sits in the ordinary discover-and-subscribe path

That is what wrote HR/RR to 12:07 while gravity sat at 07:21, independent of both the bond and the
Live tab. The residual risk is that this is firmware-conditional ("if firmware emits it", per
`standardHRFallback`); on a strap where 0x2A37 stays silent, term 2 degrades to never firing, and
term 1 serves as the backstop for that case.

Term 2 compares two data frontiers and uses no wall-clock term, so strap RTC skew cannot trip it
(see the `noop-rtc-recording-fix` memory). It is also the rule that would have caught the reported
case: a naive "night ends near the frontier" rule would have missed it, since the session reported
01:46 while the frontier was already at 03:13 (the recompute lags the frontier).

Term 2 is gated on `nightOffset == 0` only. The offload replays chronologically, so older browsed
nights are already complete and must not be badged.

### 2. Threshold: probe disproved the floor premise; derived from offload cadence instead

Per CLAUDE.md's probe rule, this is the one value that needed data not yet in hand (the DB holds
only current frontiers, so historical gaps are unmeasurable). The decision rule below was
committed before looking at any results, the first measurement setting the false-positive floor,
the second proving term 2 fires at all:

> **(a) Caught-up floor.** Once the offload catches up, sample
> `latestHRSampleTs − latestGravitySampleTs` every 30 s for 10 min.
> Stays **< 10 min** → `provisionalMotionLagS = 30 * 60`. Regularly exceeds **20 min** →
> `60 * 60`.
>
> **(b) Onset gap (the direction that matters).** At the start of a *fresh* backfill, record the
> same gap. It must comfortably exceed the constant from (a).
>
> **Fallback, committed now:** if (b) shows the onset gap is ~0, do not invent a replacement
> signal; drop term 2 and ship term 1 only (the ~3-line change), and state that plainly.

**The probe ran on 2026-07-27 and disproved the premise the rule was built on, rather than
producing a value from it.** Sampling `latestHRSampleTs − latestGravitySampleTs` every 30 s during
catch-up gave:

```
12:34:39  5007 s
12:35:09  4600 s
12:35:39  4070 s
12:36:09  3572 s
12:36:40  3031 s
12:37:10  2481 s
12:37:40  1914 s
12:38:10  1417 s
12:38:41   927 s
12:39:11   454 s
12:39:41    49 s
12:40:11    18 s
12:40:41    57 s
12:41:11    82 s
12:41:42   109 s
12:42:13   136 s
12:42:43   178 s
```

The gap fell steadily while the offload caught up, bottomed at 18 s, then began climbing again:
gravity stopped advancing at 12:39:43 (the end of an offload burst) while HR kept streaming live
over the 0x2A37 profile. A caught-up strap does not hold the two frontiers level. The caught-up
state is a sawtooth, and its peak is set by the interval between offload bursts, not by a floor
near zero. Rule (a) assumed a stable floor that could be sampled once and thresholded against;
that premise does not hold, so the rule as committed cannot be applied as written.

**The pre-committed decision rule is therefore superseded, not refined.** The probe measured the
right quantity and did its job: it disproved the floor premise and revealed the sawtooth. It did
not, and by construction could not, produce the 60-minute figure itself, since a sampled value
from a sawtooth is only ever one point on a curve whose height depends on how long ago the last
burst ended. Once the sawtooth was visible, the sawtooth's peak became a question about the app's
periodic-offload cadence, a code constant, which is a stronger and more direct source for the
bound than any further sampling would have been.

That cadence is `BLEManager.backfillIntervalSeconds` = 900 s (15 min) normally, stretched to
`BLEManager.lowBatteryBackfillIntervalSeconds` = 2700 s (45 min) when the strap is low on
battery. A 30-minute threshold would mislabel a finished night as "still syncing" for the tail of
every cycle on a low-battery strap, since the sawtooth alone can climb past 30 min before the next
burst starts. The shipped value is `provisionalMotionLagS = 60 * 60` (60 minutes): it clears the
2700 s low-battery cadence plus the burst's own duration, while staying far below the multi-hour
lags that motivate the feature (the real truncated-night case measured 29880 s).

**The tradeoff this width buys.** A stalled offload (hours outstanding, nothing running) is
surfaced by term 2 only after a full hour of no motion progress. An offload that is merely
running, rather than stalled, is already covered by term 1 (`backfilling`), so the wide bar on
term 2 costs detection time only in the stalled case, not in the ordinary catch-up case.

`Packages/StrandAnalytics` is app-free and CoreBluetooth-free by design, so `provisionalMotionLagS`
cannot reference `BLEManager.backfillIntervalSeconds` or `BLEManager.lowBatteryBackfillIntervalSeconds`
directly. The value above is derived from those constants by hand; if the offload cadence ever
changes, this constant must be re-derived by hand alongside it, not automatically.

Ship as a named constant beside the other `SleepStager` tuning values, never a literal. Note
`maxGapMin = 20` / `offWristHRGapMin = 20` as the existing scale in this codebase.

### 3. Files to change

| File | Change |
|---|---|
| `Packages/WhoopStore/Sources/WhoopStore/Reads.swift` | Add `latestGravitySampleTs(deviceId:)`, mirroring `latestHRSampleTs` (line 212) verbatim in shape, same `syncRead` / `Int.fetchOne` idiom. No `UNION` (gravity has one source). |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepReadout.swift` | Add the pure predicate + the `provisionalMotionLagS` constant. Pure `(Int?, Int?, Bool) -> Bool`, database-free, so it unit-tests with no app and no strap. |
| `Strand/Screens/SleepView.swift` | Render the pill in `sleepWindowRow` (line 783), beside the "Woke" value and the `wakeEditButton`, above the existing `Divider()` / `mainSleepFooter`. Load the two frontiers in the existing `.task(id: repo.refreshSeq)` (line 187) alongside `allSessions` / `motionByStart`, into `@State`, never read the store per body pass. |

**Why `SleepReadout` and not `Strand/`.** The choice follows from reading the file first: it is
described as "pure values for the Sleep & Rest live-readout panel", 147 lines, database-free, with
existing members `hrDensityPerMinute` and `gravityCoverageFraction`, i.e. already exactly "what do
these stream frontiers tell us about what the detector can see." The new predicate is that
module's direct sibling, and placing it there earns real `swift test` coverage with no Xcode
required. Nothing in this file feeds a stored value or a score, so the parity note in the commit
must be precise: this adds a display-only predicate to a readout module, no stored value, no
scoring input, no migration, no decoder, which is what keeps the Android-gap argument intact even
though a file under `Packages/StrandAnalytics` changed.

**Refresh semantics (accepted deliberately).** Term 1 is reactive at approximately 1 Hz through the
leaf's `@EnvironmentObject`. Term 2 is a `@State` snapshot that reloads when `repo.refreshSeq`
changes, which is exactly when a recompute lands, so the badge's frontier view refreshes in step
with the night data it qualifies and clears on the same refresh that lands the final night. It
does not tick continuously mid-catch-up; that is acceptable, since term 1 carries the badge during
an active offload.

**Critical convention (`SleepView.swift:28-32`):** SleepView deliberately does not observe
`LiveState`, since a connected strap publishes at approximately 1 Hz and would re-evaluate this
heavy body every tick. The pill must therefore be its own small leaf owning
`@EnvironmentObject var live`, taking the frontier lag as a plain value, following the same
pattern `SleepSyncingNote` (line 2600) and `SleepMarkCard` already use. `live` should not be added
to `SleepView` itself.

The `emptyState` call site at line 2289 is left unchanged.

### 4. Copy

The existing `SyncingHistoryNote` string, "Syncing strap history…", is reused; it is already
localized and already the established wording for this state. No new copy is introduced.

### 5. Non-goals

- **Android twin.** Not included in this change. It is UI-only plus one read: it changes no
  stored value, no analytics formula, and no migration, so the parity contract's byte-identical
  clause does not apply here (UI parity is explicitly feature-level). This machine has no Android
  SDK, so a Kotlin twin would ship uncompiled, as happened with the WorkoutDetector port. This is
  documented as a known parity gap in the commit message.
- Today dashboard tile.
- **The edit pencil is not gated or disabled on a provisional night.** Called out deliberately,
  since the placement rationale rests on the pencil being the control that should not be used
  here. Badging is informational only in this round; disabling a control the user may have a
  legitimate reason to reach for is a larger behavioral change and deserves its own pass. This can
  be revisited if the badge alone proves insufficient.
- The approximately 8-hour offload backlog itself (`gravitySample` also has a 15:36-22:07 hole on
  07-26). That is `workspace/state.md` open item #1, plus the untested faster-offload / 2M-PHY
  toggles (#533/#536-538); it needs observation across nights, not a one-night fix.

## Verification

This is app-target Swift, so no default CI covers it: `swift-packages.yml` does not compile app
targets and `app-build.yml` is disabled. Compile success is mandatory but proves nothing on its
own.

1. `cd Packages/StrandAnalytics && swift test`, the pure predicate. Cases: today's real numbers
   (HR 11:31 / motion 03:13 → true), caught-up equal frontiers → false, `nil` frontiers → false
   (must not badge a fresh install), `backfilling == true` with a zero gap → true.
2. `cd Packages/WhoopStore && swift test`, `latestGravitySampleTs` returns the max, and `nil` on
   an empty table.
3. `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`,
   the app target CI will not check.
4. `xcodebuild … -scheme Strand test` for `StrandTests` (macOS only).
5. **End-to-end on real data. The two terms verify on different clocks and must not be conflated
   in the report.**
   - **Term 1, checkable same day.** `state.backfilling` flips on every periodic backfill
     (`shouldRunPeriodicBackfill`, line 1978), so a short routine sync is enough: run the built
     app against the live container and watch the pill appear and then clear. Report this as
     observed.
   - **Term 2.** The plan originally assumed the multi-hour frontier gap term 2 keys on could not
     be observed until the next morning's backfill. That assumption did not hold. At 12:34 on
     2026-07-27 the offload was still behind: the HR frontier stood at 12:34:10 and the gravity
     frontier at 11:08:16, a gap of 5154 seconds (86 minutes), down from a gap of approximately
     8h18m observed at 11:31. The multi-hour frontier gap is therefore directly observable during
     the same day's catch-up, not only after an overnight backfill. The caught-up floor side of
     probe (a), sampled later the same day (12:34-12:43) as the offload finished converging, is
     what showed the sawtooth described in the Threshold section above and superseded the original
     decision rule; `provisionalMotionLagS = 60 * 60` was derived from the offload cadence
     constants rather than read off that sample.
6. Confirm design tokens only, no hardcoded colors/fonts/spacing (the change should add none,
   since it reuses `StatePill`).

Install to `/Applications` only via `ditto`, never re-signed (strips the sandbox; see
`noop-codesign-strips-entitlements`). Probe the container DB, not a stale leftover.

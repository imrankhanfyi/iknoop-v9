# Resting-HR RR-density signal-quality gate — design

**Date:** 2026-07-22
**Scope:** `Packages/StrandAnalytics` (canonical resting-HR function + gate), `Strand/Data`
(historical recompute path). Android twin (`com.noop.analytics`) is an explicit, **non-optional**
tracked follow-up — Swift lands first because it can be validated against real WHOOP-4.0 data on this
machine; the Kotlin twin must carry the identical metric + constants to honor the parity contract
(numbers must not diverge on artifact nights).

## Problem

The stored per-night resting HR can read implausibly low when the WHOOP optical sensor loses good
contact (strap loosened/shifted, typically in early-morning sleep). During such a stretch the
beat detector collapses and emits erratic, depressed HR samples. The resting-HR estimator — the
minimum of 5-minute HR-sample bin means — averages a full bin of that noise into a plausible-looking
floor and stores it as the night's resting HR.

Observed on this machine (`com.noopapp.noop` container DB):

- **2026-07-22:** stored RHR **42 bpm**. Night mean HR 68.1 (min 31, max 92). Sub-45 readings appear
  *only* 05:00–07:03, never earlier, never on prior healthy nights. The winning bin (05:12:52–05:17:52)
  held 300 HR samples averaging exactly 42.0.
- **Decisive proof it is artifact, not bradycardia:** RR-interval density collapses in the dip.
  A clean window (~05:11) logged 110 RR intervals in 2 min (dense, ~792 ms); the dip window (05:13–05:16)
  logged only **4 RR intervals in 4 min**, scattered 691–2371 ms. A genuine 42-bpm heart produces
  ~170 tightly-clustered intervals in that span. This is a beat-detector collapse.
- A second, previously-unnoticed instance: **2026-07-14** second session, stored RHR **52**, same
  signature (winning bin at 0.03× the night's median RR density).

Two aggravating structural facts:

1. **The stored value inflates recovery.** Resting HR is a recovery-score input; a spuriously *low*
   RHR reads as "well recovered." 2026-07-22 recovery was 87.9 while HRV had dropped to 50.8 (from
   65.4 two days earlier) — HRV fell sharply but recovery barely moved, consistent with the bogus 42
   propping it up.
2. **Two divergent resting-HR implementations exist.** `SleepStager.sessionRestingHR`
   (`SleepStager.swift:1996`) is the actual producer of the stored value and has **no** artifact
   guards — just the min of all bin means. `RecoveryScorer.restingHR` (`RecoveryScorer.swift:134`)
   carries the #686 guards (≥5 samples/bin, mean ≥25 bpm) but is **not** on the storage path. The
   guards live in the function that isn't used. (Note: even the #686 guards would not have caught this
   — 42 > 25 and the bin held 300 samples; #686 targets sub-physiological dropout and thin bins, not
   a well-populated bin of above-25 collapse noise.)

## Chosen approach — night-relative RR-density gate

A 5-minute bin may only **win** the resting-HR floor if its heartbeat detection is corroborated by
adequate RR-interval density, measured **relative to the same night**:

- Per qualifying bin (already ≥`MinBinSamples` HR samples and mean ≥`MinPlausibleBpm`):
  `rrDensity = rrCount / hrSampleCount`.
- `nightMedianDensity` = median `rrDensity` over all qualifying bins.
- A bin is **floor-eligible** only if `rrDensity ≥ gateFrac × nightMedianDensity`.
- `gateFrac = 0.4` (see "Threshold basis").

The resting floor is then `min(mean)` over floor-eligible bins. Fallback chain (preserves
never-nil-on-data): floor-eligible bins → else lowest of *all* bin means (legacy floor) → else
all-sample mean.

### Why night-relative, not an absolute constant

The night's RR-logging rate genuinely varies (observed nightMedianDensity 0.86–2.45 across 9 nights),
so an absolute "ratio ≥ X" tuned on one night/strap would not transfer to WHOOP 5.0/MG. The
*relative* ratio is stable: on 8 healthy nights the winning bin sat at 0.67–1.05× median; the two
artifact bins sat at 0.03×. Self-calibrating per night and per strap.

### RR-absent fallback (explicit, honest)

If `nightMedianDensity` is below an absolute floor `MinNightDensityToGate` (RR stream off, imported
CSV — no RR to reason from), the gate is **inactive** and behavior falls back to today's ungated
estimate. There is **no HR-only substitute**: a jitter/dispersion probe showed the artifact bin's
sample-to-sample delta (1.15) did not separate from real transitional bins (0.47–0.76), and its
stddev (5.0) was actually *lower* than neighboring real bins because WHOOP smooths its HR output.
RR-absent nights are therefore **not protected**, and the estimator must `log` when it falls back so
the gap is visible rather than silent.

## Threshold basis (`gateFrac = 0.4`)

Probe over all 10 stored sessions (2026-07-14 → 07-22), winning-bin density ratio (winning-bin
`rrDensity` ÷ that night's median), sorted:

```
[0.03, 0.03, 0.67, 0.69, 0.83, 0.90, 0.92, 0.93, 0.99, 1.05]
```

Bimodal with a wide empty gap between **0.03** (the two artifact nights) and **0.67** (lowest healthy
night). Any threshold in (0.03, 0.67) separates them; `0.4` is near gap-center, biased slightly low to
maximize headroom for healthy nights (a false-*reject* would read the night's RHR too *high*, the
worse-feeling error). The gate changed exactly the 2 artifact nights (42→56.6, 52→60.1) and left all
8 healthy nights byte-identical.

**Under-constrained, revisit:** basis is one strap (WHOOP 4.0), one user, 9 nights, 8 healthy. The
constant is bracketed by this data but not proven across straps/populations. Treat `0.4` as a pinned,
documented constant to re-examine as more nights/straps accumulate — not a law. Do **not** silently
retune it per platform; a change must move Swift and Kotlin together.

## Unification

Collapse the two implementations into one canonical function:

```
RecoveryScorer.restingHR(_ hr: [HRSample], rr: [RRInterval] = [], start: Int, end: Int) -> Int?
```

- Carries the existing #686 guards (`MinBinSamples`, `MinPlausibleBpm`) **plus** the RR-density gate.
- `rr` defaults to `[]` → gate inactive → behavior byte-identical to today's `RecoveryScorer.restingHR`
  for all existing no-RR callers (tests, the daytime false-sleep guard path). A **characterization
  test** must pin that the no-RR path output is unchanged, so unification does not silently move the
  sleep-detection guards' numbers.
- `SleepStager.sessionRestingHR` is deleted; its one call site (`SleepStager.swift:954`) calls the
  canonical function, passing the `rrS` already in scope. This removes the duplication that let the
  guards drift onto the wrong function.

New constants (pinned identically cross-platform), beside the existing #686 constants:

- `restingHRGateFrac: Double = 0.4`
- `restingHRMinNightDensityToGate: Double = ` *(set from the RR-absent probe below; see Open items)*

## Historical recompute (backfill)

- Reuse the existing recompute path (`IntelligenceEngine.recomputeRecovery` and the sleep-session
  recompute over stored `hrSample`/`rrInterval`). Recompute each stored session's `restingHr`, then
  re-derive dependent `dailyMetric.recovery`.
- **Skip `userEdited` sessions** — never clobber a manual edit.
- **Backup the DB first** and emit a **preview diff** (which sessions/recovery values change, old→new)
  for review **before** committing the write. Recomputing many RHRs shifts the baseline windows that
  recovery for *other* days scores against, so the blast radius is wider than the two artifact nights;
  it must be a deliberate, inspected, reversible operation, not a blind apply.
- Idempotent: re-running produces no further change once corrected.

## Testing

- **Pure unit tests (no strap, no DB), tracking a *varying* input** (per CLAUDE.md — recover multiple
  injected values, not one match):
  - Synthetic bins at several true low HRs (e.g. 40/45/50) with **dense** RR (real bradycardia) → each
    must WIN the floor (not rejected).
  - Synthetic bins of erratic-low HR with **sparse** RR (collapse artifact) at several depths → each
    must be REJECTED; floor falls to the next dense bin.
  - Median-contamination boundary: artifact spanning <50% vs >50% of qualifying bins — document the
    known degradation past 50% (see Risks).
  - No-RR characterization: `rr: []` reproduces today's `RecoveryScorer.restingHR` output exactly.
- **End-to-end against the real container DB:** recompute 2026-07-22 → assert `restingHr` lands
  ~53–56 (not 42) and recovery drops; 2026-07-14 second session → ~60 (not 52); all 8 healthy nights
  unchanged.
- Existing `RecoveryScorerTests` continue to pass.

## Risks / known limits (from redteam)

1. **Whole-night loose strap** — if RR is globally sparse, the gate goes inactive and an artifact
   floor can still win. Mitigation: `log` loudly on fallback; a whole night of garbage HR is visible
   through other signals. Not fully closed.
2. **Median contamination >50%** — a majority-artifact night pulls the median into the artifact range
   and contaminated bins begin to pass. Inherent to any night-relative approach; documented, not
   solved. Observed nights were ≤25% contaminated, well within tolerance.
3. **Threshold generalization** — `0.4` validated on one strap/user/9 nights (see Threshold basis).
4. **Backfill cascade** — baseline shift touches other days' recovery; mitigated by backup +
   preview-diff + `userEdited` skip.
5. **False-reject of genuine bradycardia** — a real low-40s dip coinciding with an RR-logging hiccup
   could be rejected and read high. Low probability given the 6× margin; accepted, stated.
6. **Parity window** — Swift-first means Swift/Kotlin RHR diverge on artifact nights until the Android
   twin lands. The twin is a tracked, non-optional follow-up, not "someday."
7. **Scope of protection** — this is specifically a *dropout/collapse* gate (bad signal → sparse RR).
   It gives no protection against dense-but-wrong RR (e.g. motion-injected false beats), which would
   read *high*, not low — a different failure, out of scope. Do not oversell the gate as general
   "signal-quality validation."

## Open items (resolve during implementation)

- **`restingHRMinNightDensityToGate`**: pick from an RR-absent / low-RR probe (what nightMedianDensity
  do genuinely RR-poor nights show?). All 10 local nights had ample RR, so this floor is not yet
  data-backed; set conservatively and log every fallback so real-world RR-poor nights surface it.
- **Android twin ticket**: mirror `restingHR(hr:rr:)`, the two new constants, and the recompute, with
  the same tests.

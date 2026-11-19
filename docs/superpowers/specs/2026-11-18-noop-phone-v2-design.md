# NOOP phone v2 — the phone becomes the place you look

_Status: APPROVED and all four phases DEPLOYED 2026-11-18 (real-iPhone check pending). Builds on `workspace/noop-phone/` (v1: encrypted read-only
viewer, deployed). Decisions below were made in conversation on 2026-11-18; facts carry the probe that
established them._

## Why

The desktop app is slow to change screens, cluttered (~60 screens, ~85k lines of app-layer Swift), and the
data arrives late. Imran wants his core numbers on the iPhone. Building a new phone app that collects
from the strap was ruled out: it would re-open all the BLE debugging, the strap bonds to one device at
a time, a free Apple ID means 7-day re-signing, and iOS has no OS-level equivalent of the fork's
no-network entitlement. So: **the Mac stays the collector and runs unattended; everything Imran looks at
or edits moves to the phone viewer.**

## Decisions (Imran, 2026-11-18)

| Topic | Decision |
|---|---|
| Collector | NOOP.app is a login item (done 2026-11-18). The Mac is usually closed overnight. |
| Freshness | Accept ~1 h after opening the Mac before last night appears (measured below). No keep-awake setup. |
| Sleep | Headline = **sleep performance** (the WHOOP-style number); plus length. |
| Workouts | kcal, avg HR, max HR, **HR-through-the-workout chart**. Edits are **phone-only** (overrides applied by the publisher; NOOP's DB is never written). |
| Trends | HRV and average HR over time; **21-day** window to start. |
| Lifestyle | WHOOP-style morning yes/no checklist about yesterday, plus correlations. |
| Lifestyle items | 13 yes/no items; caffeine stays split into morning and late, matching history. **The list is kept locally, not in git** (some items are medication), in `~/Library/Application Support/noop-phone/items.json`. New items: Imran asks Claude to add them. |
| Write-back | **Approved:** a small receiver on Freckleclaw that stores phone-encrypted entries only. |

## Evidence the design rests on

1. **Offload throughput ≈ 10× real time.** Over 5 min on 2026-11-18, `max(gravitySample.ts)` went
   `13:10:51 → 14:04:21` (strap time). One ~50-record chunk is acked every 3–4 s, persist-before-ack
   (`Strand/Collect/Backfiller.swift:364`, deliberate trim-safety). Upstream's speed toggles
   (#536/#537) are Android-only. ⇒ a 9–10 h closed-lid night needs ~1 h of open-lid time.
2. **Live HR is not a freshness signal.** At 16:57 `hrSample` max was 16:57:20 (live stream) while
   `gravitySample` max was 2026-11-11 13:07 (offload frontier). The v1 guard keys on `hrSample`, so it
   would pass and publish a week-stale night. Gravity is offload-only.
3. **Why v1 went dark 11-12 → 11-18:** NOOP.app wasn't running (not a login item; reboots 11-14 and
   11-18). The wrapper logged only `noop-publish failed`; running the binary by hand showed
   *"newest hrSample is 165.6h old (limit 48h)"*.
4. **Freckleclaw** (`tailscale serve status`): `:8444` serves `/srv/noop-health` as static files,
   tailnet-only. Host has `python3` 3.12.3, `caddy`, `docker`; Hermes runs in Docker (`127.0.0.1:9119`,
   `:8642`).
5. **Reusable analytics, not ports:** `EffectRanker` (lag-aware {0,+1,+2}, effect size + n, significance
   gated at min(nWith, nWithout) ≥ 5, explicitly "lines up with", never "causes") and
   `WorkoutDetector.estimateBoutCalories` are public in `Packages/StrandAnalytics`.
6. **History to seed correlations:** `journal` has 335 rows, 30 days, 2026-07-17 → 2026-08-23
   (logging stopped — the desktop journal UI was the friction).
7. **Workout columns exist:** `workout.energyKcal`, `avgHr`, `maxHr`, `zonesJSON`; stored avg/max are
   stale vs render (v1 README) — keep v1's reconcile-from-`hrSample` path.
8. **Journal day convention:** NOOP stores an answer under the morning it leads into — UI text:
   *"Answers are about the night and day leading into this morning, the same attribution a WHOOP export
   uses"* (`Strand/Screens/JournalLogCard.swift:100`). The phone's "about yesterday" checklist therefore
   writes under **today's** date, so legacy and new days share one alignment.

## Design

### Mac side (`workspace/noop-phone/`)

- **Schedule:** the LaunchAgent moves from a fixed 08:15 to `StartInterval` 900 s (every 15 min while
  awake). Each run: pull the inbox → if the gravity frontier advanced past the last published frontier
  **or** new inbox entries were applied → publish; else exit quietly. Last-published frontier kept in a
  small state file outside the repo.
- **Guards:** staleness guard and the envelope's plaintext `dataMaxTs` switch to
  `max(gravitySample.ts)`. Keep the ≥100k-row guard. The wrapper captures and logs the publisher's
  actual error line (no health values in it).
- **Side store:** `~/Library/Application Support/noop-phone/lifestyle.sqlite` (outside the repo and the
  NOOP container). Tables: `checkin(day, item, yes, enteredAt, entryId)` and
  `workoutOverride(workoutKey, sport?, startTs?, endTs?, deleted, enteredAt, entryId)`; last-write-wins
  per key by `enteredAt`. Item definitions (short label ↔ legacy NOOP question string) live in
  `~/Library/Application Support/noop-phone/items.json` (never in git — it names medications), so adding an
  item is a one-line change.
- **Publisher additions:** sleep performance + length (existing), workouts with overrides applied
  (edited spans re-derive avg/max HR from `hrSample` and kcal via `estimateBoutCalories` with the
  profile from the container prefs), a downsampled HR trace per workout (≈5 s buckets, 21-day window),
  HRV + avg-HR daily series, checklist state, and `EffectRanker` output over **all** history
  (NOOP `journal` rows mapped through `items.json` + side-store check-ins). **Unanswered days must be
  excluded per item:** `BehaviorInsights.effect` puts every outcome day not in `behaviorDays` into the
  "without" group (`BehaviorInsights.swift:92-94`), so the publisher filters each item's outcome map to
  days where that item was explicitly answered — otherwise every unlogged day since 2026-08-23 counts as
  "no". Day key = the **morning** the answer leads into (see evidence 8).
- **Dependency choice (decided 2026-11-18, by a rule set before looking):** `Packages/StrandAnalytics`
  depends on `WhoopStore` → GRDB (`Packages/StrandAnalytics/Package.swift:9-13`), which would put a
  remote package fetch and a large release build into the path the LaunchAgent rebuilds every 15 min.
  So, v1-style, **port** `BehaviorInsights.effect`, `EffectRanker` and `WorkoutDetector.estimateBoutCalories`
  (all pure) into `noop-publish`, each pinned by `--self-test` against values computed from the live
  store by the engine. No path dependency.

### Freckleclaw side

- **Receiver:** ~100 lines of stdlib Python, systemd unit, dedicated unprivileged user, binds
  `127.0.0.1:<free port>`. `POST` only; ≤16 KB body; writes each entry as `/srv/noop-inbox/<uuid>.json`
  (dir owned by that user, not readable by the Hermes container — no bind mount). No `GET`.
- **Routing:** `tailscale serve` adds `/inbox` on the existing `:8444` origin → same-origin POST from
  the viewer, no CORS, still tailnet-only.
- **Pull:** the Mac fetches over the existing root SSH path, commits to the side store, **then** deletes
  the fetched files (persist-before-delete, same invariant as the strap ack).
- **Integrity:** entries are AES-GCM sealed on the phone with a passphrase-derived key (same
  PBKDF2/AES-GCM scheme as v1; salt in the entry envelope). The VPS holds ciphertext only; anything
  that can reach the port can at worst spam or drop entries — forged entries fail authentication on the
  Mac and are discarded and counted in the log.

### Phone side (`viewer/`)

Four tabs, design tokens matching v1:
1. **Sleep** — last night: sleep performance (headline), length, hypnogram; 21-day history.
2. **Workouts** — list → detail with HR-over-time chart, kcal, avg/max HR. Edit: sport, start/end,
   delete. Edits show immediately (local pending state) and are marked "pending" until a publish
   confirms them.
3. **Trends** — HRV and avg HR, 21 days, gaps shown as gaps.
4. **Lifestyle** — morning checklist for yesterday (one tap per item, defaults blank not "no"), and an
   Effects list from `EffectRanker`: effect size, n with/without, lag, confidence tier; items under the
   n≥5 gate shown as "not enough data yet".

Every page shows "data through <gravity frontier>". A stale banner ("No new data since <dataMaxTs>")
shows before the passphrase prompt whenever the frontier is >30 h old. **Provisional nights:** during the
~1 h morning catch-up the 15-min publish will ship a half-offloaded night, so the latest night is marked
"still syncing" until the gravity frontier passes that night's end + 30 min (see the
partial-night-offload trap: a short night is usually the frontier, not a wake).

## Phasing (each phase independently useful and verifiable)

| Phase | Scope | Done when |
|---|---|---|
| 0 | Gravity-keyed guard + `dataMaxTs`; wrapper logs real error; 15-min frontier-triggered schedule | Publish to a scratch dir passes `--self-test`; a run with an artificially old frontier refuses with the gravity message; LaunchAgent fires and skips when nothing advanced |
| 1 | Read-only v2 views: Sleep, Workouts + HR chart, Trends | Payload built from the live store; headless WKWebView 414×896 renders all tabs; Imran opens it on the iPhone |
| 2 | Receiver + inbox pull + side store + checklist + workout overrides | Round-trip: entry from WKWebView → VPS → Mac side store → next payload; forged entry rejected; edited workout shows recomputed kcal/HR |
| 3 | Effects (`EffectRanker`) over legacy journal + new check-ins | Self-test pins one known effect from the 30 legacy days |

No NOOP.app change, no NOOP DB writes, no migration ⇒ no Android twin. Ports can drift from the engine
after a rebase onto upstream v12; the `--self-test` pins are what catch it (the wrapper runs them
every run, so drift fails loudly).

## Open questions for Imran

1. ~~"Average HR over time"~~ — **resolved 2026-11-18: both.** Resting HR (`dailyMetric.restingHr`) is the
   primary line; whole-day mean HR (computed from `hrSample` by the publisher) is secondary.
2. **The four legacy items not on the new list:** keep their history out of the Effects list, or show
   them read-only?

## Unknowns (verify before acting)

- **Hermes container network mode** — if host-networked it can reach the receiver port. Integrity
  holds either way (GCM), but check `docker inspect` before deploy and prefer a port it cannot reach.
- **Phone PBKDF2 cost** — 600k iterations on the iPhone per entry batch; measure in Phase 2, reuse the
  session key derived at unlock if slow.
- **Profile source for kcal** — weight/height/age/sex location in the container prefs; confirm in
  Phase 2 before trusting recomputed kcal.
- **Workout override keys** — `workout` PK is `(deviceId, startTs, sport)`; if NOOP re-runs detection a
  bout's `startTs` can shift and an override would silently stop matching (the original reappears).
  Match overrides by time overlap, and log any override that matches nothing.
- **Payload size** with HR traces — estimate in Phase 1; v1 is ~60 KB sealed.

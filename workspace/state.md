# NOOP — working state (v9 era)

_Last updated: 2026-07-29. This is the ongoing log for the active repo. Historical trail
(v1.61–v1.68) is in `~/Projects/NOOP-archive/repo-v1.61/workspace/state.md`._

## NEXT PICKUP — `workspace/noop-phone/` (blocked on ONE decision, Imran's)

Read **`workspace/noop-phone/README.md`** first; it is the full handoff (design, the ported traps,
the safety properties, and the open decision). This section is only the "where were we" pointer.

**Built and verified:** `noop-publish` (Mac-side Swift CLI: reads the live container store read-only,
emits a ~36 KB encrypted `noop-data.json`) and `viewer/` (self-contained HTML/JS page that decrypts in
the browser and renders Today / Last night / Sleep history / Workouts / Trends). 13 files, additive,
`workspace/`-local — touches no app code and neither `fork/no-network` patch.

**BLOCKED on Imran choosing how the viewer is served.** A red-team pass killed the original
"hermes dashboard plugin over the tailnet" hosting layer on two grounds, both measured:
1. `crypto.subtle` **does not exist** on `http://freckleclaw.tail4d0805.ts.net:9119` — WebCrypto is
   secure-context-only and the tailnet is plain HTTP. Measured `isSecureContext:false` there vs
   `true` on `https://` and on `http://127.0.0.1`. No decryption is possible as configured today.
2. Plugin assets are served from `/opt/data`, **the hermes agent's own writable tree**, and hermes'
   `SETUP.md` says the tailnet is the only real boundary. An agent that can rewrite `index.html` can
   capture the passphrase, reducing client-side encryption to theatre against exactly its threat
   model. (Symmetrically, a page same-origin with the dashboard inherits its session cookie and can
   reach `/api/env/reveal`.)

The two options — **(A)** enable Tailscale HTTPS certs then `tailscale serve --https`, or **(B)**
accept plaintext biometrics on the VPS — are written up with their costs in the README. **Do not pick
for him.** The generator and viewer are identical either way; only where `index.html` is served differs.

**Remaining work once he decides** (ordered, ~an evening; the full version is in the README):
keychain passphrase → launchd daily timer → [if A] the hermes plugin wrapper → Tailscale on the
iPhone → **load it on the actual iPhone**. That last step is the one real verification gap: the
viewer has been driven in a headless WKWebView at 414×896 (all 5 tabs render, decryption succeeds,
wrong passphrase fails cleanly, zero JS errors) but **has never run on Imran's phone**. A simulated
Safari is not his Safari.

Nothing here is a NOOP.app change, so no Android twin and no migration is involved.

## Where things stand (2026-07-18)

- **Active repo:** `~/Projects/NOOP` (this repo), branch **`fork/no-network`**, based on
  `ryanbr/noop`. **Rebased onto `origin/main` on 2026-07-18** — pulled 19 upstream commits past
  the v9.0.1 tag; our local patches replayed cleanly on top (0 conflicts).
- **Two permanent local patches** (ride the rebase stack forever — see `CLAUDE.md` banner):
  1. Strip `com.apple.security.network.client` → OS sandbox hard-blocks all egress.
  2. Production identity `com.noopapp.noop` / `NOOP` (upstream ships this fork as `.staging`).
- **Installed build:** `/Applications/NOOP.app` = Debug build ditto'd from this repo on 2026-07-18
  (never re-signed — that strips the sandbox). Reads the live container
  `~/Library/Containers/com.noopapp.noop/.../OpenWhoop/whoop.sqlite` (~479k HR rows, growing).
- **Tests (2026-07-18):** all packages green — WhoopProtocol 286/286, WhoopStore 266/266,
  StrandAnalytics 1096/1096, StrandImport 207/207 (1 env-gated skip).

## Folder layout (rationalized 2026-07-18)

- `~/Projects/NOOP` — active (this repo).
- `~/Projects/NOOP-archive/repo-v1.61` — frozen v1.61 archive + full v1.62–1.68 investigation trail.
- `~/Projects/NOOP-archive/migration-backup-2026-07-17` — pre-migration container DB + v1.68 app.
- `~/Projects/NOOP-archive/pre-rebase-app-2026-07-18` — `/Applications` bundle backup taken before
  the 2026-07-18 rebase. Git safety tag for that state: `backup/pre-rebase-2026-07-18` (also on `personal`).

Claude Code memory lives under `~/.claude/projects/-Users-imrankhan-Projects-NOOP/` — now correctly
keyed to THIS repo (the active folder is named `NOOP` again after the cleanup). Launch Claude from here.

## Open items (watch / low-priority — none blocking)

1. **Reconnect churn.** Under v9, seen as an *intermittent* ~45–60s re-attach/re-bond loop that is
   **relaunch-recoverable** — NOT the constant 1–4 min drop of the archive era. Benign when last
   observed; watch over a longer window before treating as a defect. v9 already has real machinery:
   `MarginalRadioDetector` (#80), `PostBondTimeoutLoopDetector` (#617), bond-refusal epitaph (#747).
   The 2026-07-18 rebase added **experimental** faster-offload / 2M-PHY toggles (#533/#536–538) that
   *might* help — untested. See memory `noop-strap-reconnect`.
2. **`pairedDevice.model` is bare `"WHOOP"`** → `DeviceFamily.forRegistryModel` defaults it to
   `.whoop5`. LATENT ONLY: skin-temp would decode on the 5/MG scale, but `skinTempDevC` is null across
   all days, so no visible harm. Does NOT affect the live connection (that uses
   `selectedWhoopModel="WHOOP 4.0"` from UserDefaults). A one-line registry correction someday.
3. **MarkdownUI image-provider gap** (`CoachView.swift:456`): an LLM reply containing image markdown
   fires an ungated outbound GET. On macOS this is currently blocked ONLY by the stripped network
   entitlement (patch 1). If ever restoring the entitlement to enable AI Coach, first set a no-op /
   allowlist `imageProvider`. Worth reporting upstream regardless.
4. **INVESTIGATE: store growth — 411 MB, ~half of it index overhead.** Raised 2026-07-28. The
   container DB is 413,741,056 bytes for **one year** of data (`hrSample` spans 2025-07-30 →
   2026-07-29, 1,321,682 rows), i.e. ~400 MB/yr monotonic. Per-table (`dbstat`, MB):

   ```
   gravitySample|56   sqlite_autoindex_rrInterval_1|32   spo2Sample|32
   sqlite_autoindex_hrSample_1|30          hrSample|30   sqlite_autoindex_spo2Sample_1|29
   sqlite_autoindex_skinTempSample_1|29    sqlite_autoindex_respSample_1|29
   sqlite_autoindex_gravitySample_1|29     rrInterval|29 skinTempSample|28   respSample|28
   ```

   Two observations worth chasing, neither yet a diagnosed defect:
   - **The autoindexes are as large as the tables they index.** Every per-second table is
     `PRIMARY KEY (deviceId, ts)` with `deviceId` a TEXT column, so a short string is duplicated
     ~7M times across the store. Interning `deviceId` to an INTEGER id (or reordering to an
     `INTEGER PRIMARY KEY` rowid + covering index) could plausibly reclaim a large fraction.
   - **The decoded streams are never pruned, by design.** `Database.swift:542-545` says so
     explicitly, and `PrunePolicy`'s ~50 MB cap governs **only** `rawBatch`. There is no retention
     policy for `hrSample`/`rrInterval`/`spo2Sample`/`skinTempSample`/`respSample`/`gravitySample`.
     A downsample-after-N-months policy (keep per-second for the recent window, roll older data to
     per-minute aggregates) is the obvious candidate — but note `Repository.reconcileWorkoutHrWithTrace`
     recomputes historical workout avg/max HR from `hrSample` on every read, so pruning raw samples
     silently changes displayed history. Resolve that coupling first.

   Any change here needs a versioned migration + test (never mutate an existing migration) and an
   Android twin per the parity contract. Measure with `VACUUM INTO` on a copy before/after — do not
   experiment on the live container store.
5. **The sleep-stage palette fails a colour-vision-deficiency separation check.** Raised 2026-07-29
   while building `workspace/noop-phone/`. The three hypnogram tokens
   (`Packages/StrandDesign/Sources/StrandDesign/Palette.swift:206-208`) are all violet-magenta:

   ```
   206: sleepLight  light "#7B78E0"  dark "#A7A4F4"
   207: sleepDeep   light "#C13EC1"  dark "#FD96FD"
   208: sleepREM    light "#8E3BD6"  dark "#AE5BEF"
   ```

   The `dataviz` skill's `validate_palette.js` **FAILS** the deep/REM and light/REM pairs on both CVD
   separation and the normal-vision floor — worst normal-vision ΔE ≈ **10.7–13.5 against a floor of
   15**, i.e. they are hard to tell apart even with unimpaired colour vision, and near-identical under
   deuteranopia/protanopia. This affects `SleepView`'s stage chart and legend in the shipped app, not
   just the side project. Scope note: only the **default** palette was measured; the `isClassic`
   variants (`cSleepLight`/`cSleepDeep`/`cSleepREM`) were not evaluated. The phone viewer kept these
   colours deliberately (its job is to match the app) and mitigated with an always-visible text legend,
   a stage-totals table, and a `forced-colors`/`prefers-contrast` texture overlay — the same three
   mitigations would work in SwiftUI. **Upstream-reportable and not fork-specific;** a token change is
   also a design-system change, so it is `ryanbr/noop`'s call, not ours.

## Recently done

- 2026-07-29: **`workspace/noop-phone/` — encrypted read-only NOOP viewer for the iPhone.** See the
  NEXT PICKUP section above for status and the README for the full handoff. Recording here only the
  findings that are **about NOOP itself** and would otherwise be lost with the side project:
  1. **Workout avg/max HR are recomputed at render and never persisted**
     (`Repository.reconcileWorkoutHrWithTrace`), and the reconcile spends a **300-row budget in
     newest-first order** (`Repository.swift:2053` sorts descending *before* reconciling). Any
     consumer that reads the stored `avgHr` column, or that iterates oldest-first, is wrong: the 834
     imported `apple-health` rows all have `avgHr IS NULL` so all are eligible and eat the whole
     budget. Measured divergence on this store: detected rows read **114/123 stored vs 118/124
     reconciled**. This is also the coupling that blocks naive `hrSample` pruning (open item 4).
  2. **Night/bout dismissals live in UserDefaults, not SQLite** (`sleep.dismissedSessions`,
     `workouts.dismissedDetected` in the container plist). Both empty today. Any exporter that reads
     only the DB resurrects every deleted night.
  3. **`dailyMetric` sleep is not derivable from `sleepSession`** — they reconcile on 14 of 16 nights;
     2026-07-14 differs because the daily row was scored from a differently-bridged detection pass.
     Never sum sessions to make a daily total.
  4. **`AnalyticsEngine.Rest.composite` reproduced exactly** (weights .50/.20/.20/.10, needHours 8.0,
     restorativeTarget .50, deepShareTarget .13, deepFloorFactor .5, neutralConsistency .5) →
     2026-07-28 = 90.54, 2026-07-13 = 49.09, matching the persisted `metricSeries`.
  5. **`respRateBpm` is no longer null on the 4.0** — 15/20 rows, 13.33–16.0 bpm. Memory
     `noop-resp-rate-4-limitation` was marked superseded in part. Still null 20/20: `spo2Pct`,
     `skinTempDevC`, `steps`.
- 2026-07-28: **user-editable sidebar: a "Favourites" section pinned at the top** (macOS sidebar +
  iPhone More tab). New pure `Strand/App/NavFavouritesPrefs.swift` (key `nav.favourites`, comma-joined
  stable ids in display order, empty = none), modelled on `MoreSectionPrefs`. Right-click (Mac) /
  long-press (iPhone) any row for Add to Favourites · Move to Top · Move Up · Move Down · Remove.
  **Three design constraints worth remembering:**
  1. A favourited row is **promoted, not duplicated** — a `List(selection:)` cannot carry two rows with
     the same `.tag(item)`.
  2. The subtraction happens **only inside `visibleItems(in:)`**, never by rebuilding `NavGroup` values
     with a shortened `items`. The render loop branches on `group.items.count == 1` to choose bare-row
     vs `DisclosureGroup`, so a 6-row BODY group with 5 favourites would otherwise silently lose its
     header. This also keeps `NavGroup.all` provably unmutated, so the M5 gate
     (`StrandTests/MoreListParityTests.swift`, every `NavItem` in exactly one group) holds by
     construction — that test file is unchanged.
  3. `"favourites"` is **never** inserted into `expandedGroups` (the block owns no expansion state), so
     `initialExpandedGroups(for:)` and the `preSearchExpansion` snapshot/restore round-trip are
     untouched. The three home-group auto-expand sites are each guarded, plus a fourth case the plan
     missed: un-favouriting the *selected* row demotes it without firing the `selection` observer, so
     `toggleFavourite` expands the home group on removal.
  Ids are snake_case, shaped like Android's existing `Destination` routes (`insights_hub`,
  `smart_alarm`, `lab_book`, `mi_band`, …) — **never** `NavItem.rawValue`, which is an English display
  label. Deliberately absent from the `.noopbak` whitelist and **no Android twin** (display-only, no
  stored value or scoring changes; no Android SDK here).
  The iOS More tab's 25 hardcoded `MoreRow(...)` literals became data (`MoreDestination` gained
  `title`/`icon`/`favouriteID`/`CaseIterable` + `static let groups`), with a `#if DEBUG` assert standing
  in for the absent iOS test target. Its Favourites header is a plain `Text(...).strandOverline()`, NOT
  a `moreSection(_:)` call — that helper's header writes the tapped title into the `more.expandedSections`
  CSV, which is a byte-identical Android contract.
  Verified: macOS `Strand` target builds; full `StrandTests` suite green (including
  `MoreListParityTests` unmodified, plus 17 new `NavFavouritesPrefsTests` + 10 new
  `SidebarFavouritesTests`); Release built with `CODE_SIGN_IDENTITY="-"` and `ditto`'d to
  `/Applications` (never re-signed — post-install `com.noopapp.noop`, adhoc signature, `app-sandbox` +
  bluetooth entitlements and NO network client all re-checked; existing container reached, no
  onboarding). Prior bundle backed up to `~/Projects/NOOP-archive/installed-app-backup-2026-07-28/`.
  **The iOS half is compile-verified too:** `** BUILD SUCCEEDED **` for `NOOPiOS` on an iPhone 17
  simulator (iOS 26.5). That closes the 2026-07-27 "NOOPiOS does not build on this machine" gap, and
  the *how* is the reusable part:
  1. `xcodebuild -downloadPlatform iOS` — 8.52 GB, iOS 26.5 runtime 23F77. `-showdestinations` went
     from **zero eligible** to a full iPhone/iPad list.
  2. The scheme then stops on a **second** platform: *"This scheme builds an embedded Apple Watch app.
     watchOS 26.5 must be installed in order to run the scheme."* Only watchOS 11.5 is present.
  3. **No watchOS download is needed.** Comment out the one `- target: NOOPWatch` line in `project.yml`
     (the iOS target's embed, ~line 316), `xcodegen generate`, build, then
     `git checkout -- project.yml && xcodegen generate`. Fully disposable — `Strand.xcodeproj` is
     generated and untracked so nothing can leak into a commit; re-check
     `grep -c com.apple.security.network.client Strand/Resources/Strand.entitlements` → 0 after the
     final regenerate. Imran has no Apple Watch and doesn't intend to get one, so this probe is the
     standing answer rather than a second ~8 GB `-downloadPlatform watchOS`.
  4. What does NOT work: `-target NOOPiOS -sdk iphonesimulator` fails to resolve every SPM product
     (`NetworkImage`, `GRDB`, `StrandDesign`, `WhoopProtocol`, `OuraProtocol`) even immediately after
     `-resolvePackageDependencies` reports success — SPM products only resolve through a scheme. That is
     the same `NetworkImage` symptom the 2026-07-27 entry recorded; the package was just the first error
     alphabetically, not the cause.
  **`.contextMenu` inside a sidebar `List(selection:)` WORKS** — confirmed by Imran on the shipped
  build. It had no precedent in this tree (the only other `.contextMenu` uses are custom rows in scroll
  containers, `Strand/Screens/WorkoutsView.swift:1191`/`:1263`), and it was the reason the design chose
  context-menu commands over `.onMove`, so it's worth knowing the pattern is available for future
  sidebar work. **Still unverified:** iOS runtime behaviour — the simulator build was never launched.
  **Deliberately NOT in `CHANGELOG.md`.** An `## Unreleased` heading was tried and reverted: this
  changelog's convention is that entries land with a version bump in a release-prep commit, and a new
  top-of-file section in an upstream-tracked file is maximum conflict surface on the next rebase for a
  feature that is fork-local. The user-facing description lives in `docs/FEATURES.md`; the contract
  lives in `docs/CROSS_PLATFORM.md`; whoever cuts a version that includes this should write the
  changelog entry from the diff then.
- 2026-07-27: **renamed the branch `local/no-network` → `fork/no-network`, and closed the backup gaps.**
  The branch was always fully pushed to `personal`, but the name's "local" token (meaning *local to this
  fork*, as `CLAUDE.md` uses it for the two "local patches") read as "not pushed" and caused real
  confusion about whether a backup existed. `fork/` states the actual meaning. Renamed on GitHub too
  (default branch moved first — GitHub refuses to delete a repo's default branch), and the reference
  updates were committed **before** the first push so the rename and the docs explaining it travelled
  together. Backup topology confirmed correct and deliberately left alone: `imrankhanfyi/iknoop-v9` is a
  **standalone private repo, not a fork**, because GitHub forks inherit the parent's visibility — a
  private fork of public `ryanbr/noop` is impossible. Standalone also means the push carried every
  ancestor commit, so it restores with no dependency on upstream still existing. There is deliberately
  no `main` on `personal`: this branch IS the trunk.
  Gaps closed: `AGENTS.md` is now tracked (it had never been added, so the one file in the tree with
  **zero** presence in the backup); the immutable semver release tags are pushed (deliberately NOT
  `--tags` — `testing-latest`, `noop-staging`, `ci-appbuild` are *moving* upstream tags that nothing on
  `personal` tracks, so copies there would freeze stale and mislead); and the archive repo's one missing
  commit is pushed. Cadence stays **manual** — `/ship` already pushes.
  **Out of scope but recorded because it is the real exposure:** Time Machine's destination is
  `Macintosh HD` (a *local* destination) and currently fails to mount, so nothing outside git has a
  working off-machine backup. That matters for `NOOP-archive/migration-backup-2026-07-17` (133M), which
  holds the container SQLite — biometric data, which by hard rule can never go to a git remote.
- 2026-07-27: **"still syncing" badge on a provisional sleep night** (`ca0fbcc4`, `c5d21d66`).
  Investigated "NOOP says I slept til 1:30am, I actually slept til 5am": nothing was wrong with the
  analytics. `gravitySample` lands ONLY via the historical offload while `hrSample` also streams live
  over 0x2A37, and `SleepStager` builds its still-spine from gravity, so the displayed wake was the
  **motion-offload frontier**, not a wake. It self-corrected with no code change (01:46 → 03:50 →
  05:15 → 05:08; resting HR 72 → 64). See memory `noop-partial-night-offload-frontier` — and **never
  hand-edit such a night**, `userEdited` then pins `endTs` against every recompute.
  Shipped: `latestGravitySampleTs` (`Reads.swift`), `Repository.streamFrontiers()`, and a pure
  `SleepReadout.isNightProvisional` driving the existing "Syncing strap history…" pill on the newest
  night's window row (`SleepView.sleepWindowRow`, gated to `nightOffset == 0`). Two OR'd terms:
  `backfilling`, and motion trailing HR by > `provisionalMotionLagS`.
  **Two values were set by evidence, not by the plan** (both documented in
  `docs/superpowers/specs/2026-07-27-sleep-syncing-badge-design.md`):
  1. Threshold is **60 min, not 30**. A probe disproved its own premise: the caught-up lag is a
     **sawtooth**, not a floor (fell 5007s → 18s, then climbed 49/82/109/136/178/205/219s as gravity
     stopped at a burst end while HR streamed on). The bound is the offload cadence —
     `backfillIntervalSeconds` 900s, stretched to `lowBatteryBackfillIntervalSeconds` **2700s** —
     so 30 min would badge a *finished* night every cycle on a low-battery strap.
  2. Term 1 is **gated** on `nightCouldStillGrow` (`SleepStager.nightContinuationGapMin`, 90 min).
     Unqualified it fires on every 15-min periodic offload, painting the pill under an
     already-correct wake time all day. Term 2 is deliberately NOT gated the same way: the recompute
     lags the frontier (night read 01:46 against an 03:13 frontier = 87 min, only 3 min inside the
     bound), so gating it would nearly have suppressed the real signal.
  Verified: all packages green (286/268/1117/207/32/9, 0 failures); Strand macOS target builds;
  installed Release to `/Applications` via `ditto` (never re-signed — sandbox + `com.noopapp.noop`
  identity re-checked after install; prior bundle backed up to
  `~/Projects/NOOP-archive/installed-app-backup-2026-07-27/`). Both **suppression** paths confirmed
  on live data in the shipped binary: at 13:21:32 an offload advanced gravity while the pill stayed
  hidden because the gate was shut (night end 05:08 vs frontier 13:21).
  **Still unverified:** the *positive* render — nobody has seen the pill drawn. Next morning's
  backfill exercises both terms at once (87-min delta opens the gate, multi-hour gap trips term 2);
  glance at the Sleep screen before the offload catches up. Also `NOOPiOS` does **not** build on this
  machine (iOS 26.5 *platform* not installed; bypassing the scheme fails in `swift-markdown-ui`'s
  `NetworkImage` — unrelated to these files), and there is **no Android twin** (display-only
  predicate, no stored value/scoring/migration, and no Android SDK here).
- 2026-07-22: fixed CrossFit/interval workouts silently not auto-logging. `WorkoutDetector`'s
  intensity gate (`z2plus < 0.50` average time-in-zone) rejects interval bouts because rest periods
  between efforts drag the average below the bar, even when the working intervals are near-max —
  this is the same bug the pre-v9 fork fixed in `07278b41` (2026-07-14), which never made it
  upstream into v9. Ported the fix: qualify a bout on `z2plus ≥ 0.50` **OR** ≥60s sustained
  (time-weighted) at Edwards zone 3+ (`peakQualZone`/`peakQualMinSeconds` in
  `Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetector.swift`). Validated against the
  real container DB: recovered 4 previously-dropped `detected` workouts (07-14, 07-15, 07-16, and
  07-21's CrossFit session, 4:23–5:41pm EDT, matching the reported 4:30–5:35pm). Android twin
  (`android/.../analytics/WorkoutDetector.kt`) ported line-for-line but **unverified** — this
  machine has no Android SDK (only a JDK was installed via brew for the attempt); low priority since
  this fork's daily use is macOS-only.
- 2026-07-18: upstream rebase (19 commits), rebuild, ditto to `/Applications`, full test pass.
- 2026-07-18: folder cleanup (4 dirs → `NOOP` + `NOOP-archive/`), ~4G build artifacts reclaimed,
  path references in CLAUDE.md + Claude memory updated, this `workspace/` layer created.

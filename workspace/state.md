# NOOP — working state (v9 era)

_Last updated: 2026-07-27. This is the ongoing log for the active repo. Historical trail
(v1.61–v1.68) is in `~/Projects/NOOP-archive/repo-v1.61/workspace/state.md`._

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

## Recently done

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
  **Still unverified:** `StrandiOS/App/RootTabView.swift` is **uncompiled** — `NOOPiOS` still has zero
  eligible destinations on this machine (iOS platform component absent, see the 2026-07-27 entry). The
  one construct most likely to break, `ForEach(tupleArray, id: \.header)`, was type-checked in isolation
  against the macOS SDK and is fine; `ScreenScaffold`/`NoopCard` signatures and `.contextMenu` on a
  `NavigationLink` label remain unchecked.
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

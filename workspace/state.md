# NOOP — working state (v9 era)

_Last updated: 2026-07-18. This is the ongoing log for the active repo. Historical trail
(v1.61–v1.68) is in `~/Projects/NOOP-archive/repo-v1.61/workspace/state.md`._

## Where things stand (2026-07-18)

- **Active repo:** `~/Projects/NOOP` (this repo), branch **`local/no-network`**, based on
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

- 2026-07-18: upstream rebase (19 commits), rebuild, ditto to `/Applications`, full test pass.
- 2026-07-18: folder cleanup (4 dirs → `NOOP` + `NOOP-archive/`), ~4G build artifacts reclaimed,
  path references in CLAUDE.md + Claude memory updated, this `workspace/` layer created.

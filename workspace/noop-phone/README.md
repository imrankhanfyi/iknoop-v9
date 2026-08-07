# noop-phone — read-only NOOP viewer for the iPhone

Two pieces:

- **`noop-publish`** — a Mac-side Swift CLI that reads the live NOOP store (read-only) and writes a
  small encrypted payload, `noop-data.json` (~36 KB).
- **`viewer/`** — a self-contained HTML page that fetches that payload, decrypts it in the browser
  with WebCrypto, and renders Today / Last night / Sleep history / Workouts / Trends.

Nothing here touches NOOP.app, the `fork/no-network` patches, or any file the app writes. It is
additive and local-only: `workspace/` never conflicts on an upstream rebase, and no XcodeGen target
globs this directory.

## Status

`noop-publish`, the standalone viewer, and the daily encrypted publishing path are **built and
verified**. The viewer is served privately over Tailscale HTTPS; see "How this gets onto the phone"
for the operational handoff.

**Accessibility note.** The three sleep-stage colours are NOOP's own shipped tokens
(`StrandPalette.sleepLight`/`sleepDeep`/`sleepREM`) and they **fail** a colour-vision-deficiency
separation check — deep/REM and light/REM sit at ΔE ≈ 10.7–13.5 against a floor of 15. They are kept
here on purpose, because this viewer's job is to agree with the app, and mitigated with an
always-visible text legend, a stage-totals table that doubles as the table view of the chart, and a
texture overlay under `forced-colors`/`prefers-contrast` (never on by default). The underlying issue is
in the app, not in this viewer — recorded as open item 5 in `workspace/state.md`.

## Quick start

```bash
# one-time: store the passphrase in the login keychain (prompts; never lands in shell history)
security add-generic-password -s noop-publish -a "$USER"

cd workspace/noop-phone
swift build
.build/debug/noop-publish --self-test              # crypto + gzip + read-model port checks
.build/debug/noop-publish --out ~/noop-phone-out   # real publish
```

The passphrase is **never** accepted as a command-line argument — argv is visible to every process
running as your user. `--passphrase-from` is `keychain` (default), `stdin`, or `env`.

## What is in the payload

The summary tier only. As of the 2026-07-29 run: 21 days, 17 sleep sessions, 841 workouts, 4 metric
series — 246 KB of JSON, 27 KB gzipped, **36.5 KB sealed**. It grows by roughly a day and a night per
day, so treat those counts as a scale check, not a constant; the previous run (2026-07-28) read
20/16/840 at 36 KB. The per-second tables (`hrSample` 1.3M rows and five siblings, ~360 MB) are **not**
shipped and never will be; they are read only to precompute workout HR.

## Correctness: how this stays in step with the Mac app

Every number the viewer shows is verified against the store on each publish. The traps that were
found and handled — each one would have made the viewer quietly disagree with the app:

| Trap | Rule applied |
|---|---|
| Workout avg/max HR are **recomputed at render** from `hrSample` and never persisted (`Repository.reconcileWorkoutHrWithTrace`) | Precomputed here from the same trace, same gate (≥60 samples, ≤8000 rows), same rounded-mean reduction. Shipping the stored column was measurably wrong: detected rows read 114/123 stored vs 118/124 reconciled. |
| That reconcile spends a **300-row budget in newest-first order** | We sort descending before reconciling. Oldest-first burns the whole budget on the 834 imported Apple rows (all have `avgHr IS NULL`, so all are eligible) and no strap session gets reconciled. |
| A hand-edited night's onset lives in `startTsAdjusted` | `effectiveStartTs = startTsAdjusted ?? startTs`, per `MetricsCache.swift:30`. On this store 2026-07-18 carries a 43-minute correction. `NoopLocalAccess`'s `SleepSessionRow` deliberately omits the column and must **not** be reused. |
| `dailyMetric` sleep is **not** derivable from `sleepSession` | Day figures come from `dailyMetric` columns; `stagesJSON` is used **only** for the hypnogram. They reconcile on 14 of 16 nights; 2026-07-14 differs because the daily row was scored from a differently-bridged detection pass. Never sum sessions to make a daily total. |
| `apple-health` has 4,214 daily rows back to 2016 that no app screen shows | `days` unions only `importedReadIds` + `computedReadIds` (+ `activity-file` steps), matching `Repository.refresh`. Asserted structurally on every publish. |
| Legacy `my-whoop-manual` workout rows are read by nothing | Excluded by construction — not in the read-id set. |
| A detected bout and its real logged twin both exist until the next analyze pass | `dropDetectedShadows` ported faithfully, including the quirk that a bare `"noop"` source classifies as `.apple` (no `-noop` suffix, no `"whoop"` substring) and so counts as a real row. |
| Deleting a night / dismissing a bout is recorded in **UserDefaults, not SQLite** | `Tombstones` parses `sleep.dismissedSessions` and `workouts.dismissedDetected` from the container plist. Both are empty today; without this the viewer would resurrect the first night you delete. |
| Nulls | `spo2Pct` and `skinTempDevC` are null on all 20 rows, `steps` on all 20. Emitted as JSON `null`, never 0, and the viewer renders "—" and breaks trend lines rather than plotting zero. |
| `sleep_performance` is computed at render in one place and read from `metricSeries` in another | `RestComposite` is a port of `AnalyticsEngine.Rest.composite`; verified to reproduce the persisted series exactly (2026-07-28 → 90.54, 2026-07-13 → 49.09) and **asserted on every publish**, so an upstream formula change fails loudly instead of silently diverging. |

### Known, deliberate divergence: today's Effort

`TodayView.effortStrain` shows `max(liveTodayStrain, stored)`, recomputing strain from today's HR
samples up to *now*. The viewer ships the stored value, so **on the current day Effort can read low**
until the next analyze pass. Past days are exact. Reproducing the live number would mean porting
`StrainScorer` (Edwards zones + the HRmax profile), which is a genuine risk of divergence for one
cell — so it is documented rather than guessed. The viewer displays the payload's age so a stale
number is never mistaken for a current one.

## Safety properties

- **Read-only, `mode=ro`, never `immutable=1`.** `immutable=1` makes SQLite ignore the `-wal`, which
  on this live store measurably reads ~12 minutes stale *and* returns `database disk image is
  malformed` when a checkpoint lands mid-read (5 of 8 attempts under a concurrent writer).
  `mode=ro` participates in WAL locking, which is exactly why it is safe.
- **Two hard guards** before anything is built: `hrSample` must have ≥100k rows (catches resolving the
  4 KB staging store instead of the container — which would otherwise publish a valid, *empty*
  payload and exit 0), and the newest sample must be within 48h.
- **Fresh random salt and nonce every publish**, so each day's key is unique and nonce reuse across
  publishes is impossible by construction. PBKDF2-HMAC-SHA256 at 600,000 iterations; AES-256-GCM with
  a 96-bit nonce and 128-bit tag; the KDF parameters are bound as AAD so a tampered envelope cannot
  downgrade the iteration count. Every publish proves its own seal/open round-trip before writing.
- **Atomic write** (temp file + rename): an in-place overwrite is not atomic, and a phone fetching
  mid-write would get a short file whose GCM tag then fails — surfacing as the actively misleading
  "wrong passphrase".
- **`generatedAt` / `dataMaxTs` / `tz` sit outside the ciphertext** so the viewer can warn about stale
  data before a passphrase is entered. They leak only timestamps.
- **Artifacts are gitignored** (`workspace/noop-phone/out/`, `noop-data*.json`, `slim*.json`, `*.bin`,
  `*.json.gz`), verified with `git check-ignore`. `workspace/` is tracked and `fork/no-network`
  pushes to a private GitHub remote, so this matters: per the repo `CLAUDE.md`, biometric data never
  goes to any git remote. Prefer `--out` outside the repo entirely.

## How this gets onto the phone

The viewer is deployed as a standalone static site, not as a Hermes dashboard plugin. Its files live
in the root-owned `/srv/noop-health` directory on Freckleclaw and are served only within the tailnet:

```
https://freckleclaw.tail4d0805.ts.net:8444/
```

Tailscale HTTPS supplies the browser secure context required by WebCrypto. Keeping the viewer outside
the agent-writable Hermes tree means a Hermes agent cannot replace its JavaScript to capture the
passphrase. The old plugin approach was rejected for both reasons; do not recreate it.

### Daily publishing

The Mac has a Keychain item named `noop-publish` and a per-user LaunchAgent,
`com.noopapp.noop-phone-publish`. At 08:15 in the Mac's local Pacific time (or at the next wake after
a missed time), it runs `scripts/publish-daily.sh`. The wrapper builds and self-tests `noop-publish`,
creates the encrypted envelope in a private `/private/tmp` directory, transfers that file only over
SSH, then atomically replaces `/srv/noop-health/noop-data.json` on Freckleclaw.

The LaunchAgent does not wake the Mac, does not have `KeepAlive`, and writes only timestamps, build
output, and encrypted byte counts to `~/Library/Logs/NOOP/`. A failed run leaves the previously served
encrypted payload in place.

Operational checks:

```bash
launchctl print "gui/$(id -u)/com.noopapp.noop-phone-publish"
curl --fail --silent --show-error \
  https://freckleclaw.tail4d0805.ts.net:8444/noop-data.json -o /dev/null
```

On the iPhone, connect Tailscale, open the URL above, and enter the existing passphrase. Refreshing
shows the latest encrypted snapshot; the viewer displays its age.

Optional and separable (Phase 2 of the plan, never built): a morning recovery digest pushed to Telegram
by the Mac with `deliver_only: true`. It inherently puts a few numbers in front of Telegram and the VPS
in plaintext, which is why it is opt-in and why the viewer stands alone without it.

## Layout

```
workspace/noop-phone/
├── Package.swift
├── Sources/noop-publish/
│   ├── main.swift             CLI, path resolution, passphrase sourcing
│   ├── SQLite.swift           read-only wrapper (mode=ro; see the comment on why not immutable=1)
│   ├── ReadModel.swift        the app-matching read model
│   ├── WorkoutVisibility.swift  port of Strand/Data/WorkoutSource.swift
│   ├── RestComposite.swift    port of AnalyticsEngine.Rest.composite
│   ├── Tombstones.swift       UserDefaults dismissal spans
│   ├── Crypto.swift           PBKDF2 + AES-GCM + gzip
│   ├── Build.swift            payload assembly, JSON, atomic write
│   └── Checks.swift           publish guards, assertions, --self-test
└── viewer/
    ├── index.html
    └── app.js
```

Ports are pinned by `--self-test` against values verified on the live store. If a ported file in
`Strand/` or `Packages/StrandAnalytics` changes, the self-test is what tells you.

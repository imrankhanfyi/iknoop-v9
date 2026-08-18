# Editable Sleep Timeline Design

## Goal

Let a person correct a detected night's asleep and woke boundaries directly on
the sleep-stage graph, including a correction outside the currently detected
window. Persist the correction through the established sleep-edit path so the
shown stages, sleep totals, and downstream on-device calculations reflect the
chosen interval.

## Scope

The macOS, iOS, and Android sleep screens expose two draggable boundary
handles:

1. **Asleep** — the effective sleep-session onset.
2. **Woke** — the effective sleep-session end.

The graph's displayed coordinate domain is separate from the session's
physiological data domain. It extends exactly 90 minutes before the effective
asleep time and 90 minutes after the effective woke time. Stage segments remain
drawn only in their recorded interval; the surrounding editing corridor is
visibly empty rather than invented or labelled as a sleep stage. This lets a
person correct, for example, a 06:00 detected wake to 06:45.

On a drag release, the handle position is clamped to the editable coordinate
domain and snapped to the 30-second epoch grid. The UI submits the pair of
chosen bounds to the existing repository sleep-edit method. That method remains
the sole persistence and recomputation path: it prevents future or inverted
windows, re-stages the edited range from local raw data when available, falls
back honestly when it is not, and refreshes the displayed night.

Existing **In bed**, **Fell asleep**, **Awake in bed**, **Briefly got up**, and
**Arose** pins remain optional, local user annotations. They retain their
current add, drag, type-change, and deletion interaction, but cannot alter
sleep stages, totals, recovery, strain, or any inferred physiological result.

## Interaction

The stage timeline renders the two boundary handles above its shared time axis.
Their labels identify the current local clock time and distinguish them from
the neutral annotation pins. A pointer drag works on macOS; long-press then
drag works on iOS and Android. Releasing a handle applies one 30-second-snapped
edit. If the proposed range is entirely outside recorded coverage, the existing
confirmation remains required. A rejected or failed save restores the previous
positions and shows a non-sensitive failure message.

The existing sheet-based “Edit sleep times” control remains available as an
accessible keyboard and precise-time alternative. Both entry points call the
same repository edit path and therefore have identical durability and safety
semantics.

## Architecture

Introduce a pure shared edit-domain helper on each platform. Given an effective
session start and end, it returns a graph domain expanded by exactly 5,400
seconds on each side; it maps a horizontal coordinate to a snapped timestamp
inside that domain. The helper has no persistence or UI dependency, making the
90-minute contract directly unit-testable and byte-identical with Kotlin.

Apple's `SleepView` overlays boundary handles over the existing stage rows and
uses transient drag state. Android's `SleepScreen` mirrors the layout and
interaction. Each platform calls its existing repository's sleep-time edit
method after the gesture ends; neither writes `sleepSession` directly.

## Invariants

- The editing corridor is exactly 90 minutes before and after the effective
  session bounds.
- Empty corridor pixels never claim that a person was awake, asleep, or staged.
- Boundary edits snap to 30 seconds and persist only through the guarded
  repository edit method.
- A boundary edit updates the actual sleep session and therefore may update
  re-derived stages, totals, recovery, and other derived on-device results.
- Annotation pins are descriptive notes only and never affect inferred data.
- No network, account, telemetry, or hardware-write behavior is added.
- macOS, iOS, and Android have feature-level parity and use the same 90-minute
  corridor and 30-second snapping rules.

## Validation

Pure Swift and Kotlin tests prove the 90-minute domain, endpoint mapping,
outside-detected-window mapping, and 30-second snapping. Repository tests keep
covering future/inverted/disjoint safeguards and durable re-staging. Apple and
Android UI tests cover handle visibility, transient dragging, and save routing.
Build the macOS `Strand` and iOS `NOOPiOS` targets, compile/test Android, then
build the macOS Release product with its sandbox entitlement intact and install
it with `ditto` over `/Applications/NOOP.app`.

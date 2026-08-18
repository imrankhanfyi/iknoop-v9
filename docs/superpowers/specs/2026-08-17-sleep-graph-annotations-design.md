# Sleep Graph Annotations Design

## Goal

Let a person pin and drag local, descriptive sleep annotations on a nightly
stage graph without altering automatically inferred sleep stages, sleep totals,
or any downstream health metric.

## Scope

The graph supports these annotation types:

1. In bed
2. Fell asleep
3. Awake in bed
4. Briefly got up
5. Arose

They are single timestamped points, not intervals. They are explicitly user
notes rather than physiological measurements. The feature ships at feature
parity on macOS, iOS, and Android.

The existing `SleepMark` feature remains unchanged. Its two action buttons and
strap double-tap preserve their `metricSeries` and strap-log behavior. Graph
annotations neither replace nor consume those records.

## Data model and persistence

Create a local `sleepAnnotation` table on both platforms. Each row contains:

| Column | Type | Meaning |
| --- | --- | --- |
| `deviceId` | text | Active strap identity / existing device-scoping convention |
| `tsMs` | integer | Absolute Unix milliseconds |
| `type` | integer | Stable enum: in-bed=0, fell-asleep=1, awake-in-bed=2, briefly-got-up=3, arose=4 |

The natural primary key is `(deviceId, tsMs, type)`. This permits several kinds
of note at the same instant, while making an accidental duplicate idempotent.
Moving a pin deletes its old natural key and inserts the new one transactionally.
Changing its type uses the same transactional replace. If the target natural key
already exists, the operation leaves one annotation.

Annotations are selected by their timestamp falling inclusively inside the
displayed session's in-bed window. They are therefore robust to future
re-detection or manual adjustment of a session boundary, rather than being
coupled to the mutable `(deviceId, startTs)` sleep-session key. A query is
ordered by timestamp then type for deterministic rendering.

This is a new versioned GRDB migration plus an equivalent Room migration and
entity/DAO. Device deletion removes the rows. The backup whitelist includes the
same fields and JSON kinds on Swift and Kotlin. CSV / health exports do not add
the annotations in this release, because those exports carry metrics rather than
free-form user notes.

## Interaction

The stage-breakdown card gains a `+ Marker` affordance. Selecting it presents
the five types. Choosing one creates a selected pin at the midpoint of the
current session. The pin’s timestamp is snapped to the same 30-second epoch
grid used by the stage chart.

Pins render as a neutral vertical line and accessible label over the shared
stage timeline; they do not recolor, split, or conceal stage segments. A selected
pin opens a compact editor with its type, formatted local time, and Delete.

On macOS, the pin can be dragged horizontally with a pointer. On iOS and
Android, it uses press-and-drag. Overlapping pins maintain individually
selectable stems and vertically stacked labels. Each add, change, drag, and
delete is local and optimistic. If persistence fails, the UI restores the
previous graph state and reports a non-sensitive error.

## Invariants

- An annotation never changes the detected sleep window, stage JSON, stage
  totals, sleep efficiency, recovery, strain, or any analytics input.
- No annotation feeds sleep staging or personal calibration in this release.
- All data stays on device; no telemetry, network access, or account is added.
- `SleepAnnotationType` integer encodings, storage columns, migration result,
  and backup representation are identical on Swift and Android.
- A drag is represented by one atomic move, never a visible delete/add gap.

## Validation

Automated coverage proves the enum encoding, primary-key deduplication, atomic
move/type replacement, deletion, time-window query ordering, and 30-second
snap behavior. Swift GRDB and Android Room migration tests assert the table,
column order, and device-deletion cleanup. Analytics regression tests prove a
stored annotation cannot alter a `SleepStager` result or calculated stage totals.

Platform UI tests / compile coverage verify the graph can add, select, move,
change, and delete a marker, and that an injected persistence failure restores
the prior state. The macOS and iOS app targets must compile after shared
SwiftUI changes; Android’s full unit test and Kotlin compile must run after the
Room / Compose changes.

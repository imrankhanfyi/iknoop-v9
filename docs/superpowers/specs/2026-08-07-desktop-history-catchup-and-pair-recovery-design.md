# Desktop history catch-up and secure-pair recovery

## Problem

On macOS, a newly opened NOOP can show an incomplete current sleep night for hours. The sleep stager needs `gravitySample` motion data, which arrives only through historical offload; live standard-HR notifications do not supply it. The strap serves history oldest-first in small sessions. Current automatic continuation is bounded and uses the strap-reported data-range newest timestamp, which is stale on the affected strap. A session that goes silent for 60 seconds falls back to the normal scheduler, even if the motion frontier is still materially behind.

The Live screen can also show a partial connection: standard HR flows but an encrypted WHOOP bond has not completed. Scanning rediscoveries are not a reliable way to reset that state. The user currently has to quit and relaunch NOOP to receive another useful secure-pair attempt.

## Evidence from the installed app

The persisted `strapLog.tail` on 2026-08-07 showed successful historical sessions between 12:43 and 13:44, each landing roughly 4--11 minutes of motion before the next trigger. The last re-kicked session began at 13:44:16 and ended on the 60-second idle timeout at 13:45:16. At inspection, live HR extended to 13:54 while gravity ended at 13:45. The stored strap data-range newest timestamp was 10:14 despite persisted data through 13:45, so that timestamp cannot be relied on to decide whether current sleep motion is caught up.

## Goals

- Pull current-night motion promptly enough that sleep scoring does not remain provisional for hours while a healthy strap is connected.
- Recover from a partial encrypted bond automatically, without an unbounded reconnect loop.
- Never send destructive strap commands or bypass the existing encrypted-pairing contract.
- Make history-sync availability honest: standard HR alone is not sufficient for history offload.
- Preserve existing automatic background battery safeguards.

## Non-goals

- Change sleep scoring formulas or invent motion from live HR.
- Change protocol trim semantics, offload ordering, or acknowledge unpersisted data.
- Repeatedly force pairing when CoreBluetooth reports that another central or stale OS bond owns the strap.
- Change Android behavior in this change; this is a macOS app-layer recovery/catch-up policy. The cross-platform data and analytics contracts remain unchanged.

## Design

### 1. Motion-frontier catch-up budget

Add a pure `HistoryCatchUpPolicy` beside the existing BLE policy helpers. It decides whether another immediate historical-offload attempt is warranted after an automatic session ends.

Inputs:

- current connection and genuine encrypted-bond state;
- latest persisted gravity timestamp;
- latest persisted HR timestamp;
- wall-clock time;
- whether the just-ended session advanced the trim cursor;
- the prior session's outcome and a bounded catch-up budget.

The policy should request a continuation only when gravity is materially behind the current physiological timeline (the newest plausible HR or wall clock), the prior session made safe trim progress, and the connection is genuinely encrypted. It must stop after a fixed time/pass budget, on no trim progress, on explicit pairing errors, and once gravity catches up. The normal 15-minute/low-battery cadence remains the fallback outside a bounded catch-up window.

The continuation uses the existing safe `beginBackfill`/persist/cursor/ack path; it does not change command bytes or acknowledge timing. A timeout after partial progress may schedule the next bounded catch-up retry after a short, nonzero delay, rather than waiting for the general cadence, but only while the policy says the current night remains behind. This avoids immediately reissuing a command while the strap may still be draining a prior response.

### 2. Automatic secure-pair retry

Introduce a small pure retry policy for a partial WHOOP connection. A partial connection means standard HR is arriving but `encryptedBond` remains false. After a short settle window, NOOP schedules one clean retry that cancels NOOP's peripheral session and reconnects after the disconnect callback. It is not a scan-only retry.

Use bounded backoff while the app remains active and standard HR proves the strap is nearby: 5 minutes, 15 minutes, then hourly. A successful genuine bond cancels and resets the retry state. An intentional user disconnect cancels it.

If the secure write reports insufficient authentication/encryption, peer-removed pairing information, or the existing bond-loop detector pauses reconnection, cancel automatic retries and surface the current re-pair guidance. This prevents an automated hammer loop against a strap held by the official WHOOP app or a stale macOS pairing.

### 3. Honest UI gating and diagnostics

The Sync UI and `requestSync` should require a genuine encrypted bond, not merely the `bonded` flag that may be set by standard HR on 5/MG. A partial link should describe history sync as unavailable while the automatic secure-pair retry is pending; it must not present a disabled/no-op sync as ready.

Persist concise diagnostic records to the existing strap-log tail for partial-bond detection, retry scheduling/firing/cancellation, secure-write error classification, catch-up decisions, and the HR/gravity frontiers. Do not log identifiers, raw biometrics, or sensitive pairing material.

## Testing and verification

- Add XCTest coverage for the pure catch-up and secure-pair retry policies: behind/caught-up, timeout/no-progress, cap/backoff, successful bond reset, explicit auth refusal, and intentional disconnect.
- Add BLEManager tests for gating sync on `encryptedBond` and for scheduling/cancelling policy actions through injected seams where necessary.
- Run the affected Strand test target and build the macOS `Strand` app because this changes app-target Swift.
- Hardware verification on the desktop strap: begin from a partial connection and verify one bounded retry; begin with a motion backlog and verify gravity advances in consecutive catch-up sessions until current-night lag closes or the explicit safety budget is reached.

## Acceptance criteria

- A partial link retries secure pairing without manual relaunch, no more frequently than the prescribed backoff, and stops automatically on explicit ownership/stale-pairing errors.
- A genuine encrypted bond cancels all pending pairing retries.
- A current-night motion backlog gets bounded expedited retries after a silent offload session instead of immediately falling back to the general cadence.
- The sync UI never claims history is available on a standard-HR-only partial link.
- All new policy decisions are pure and test-covered; existing safe persistence-before-ack behavior remains unchanged.

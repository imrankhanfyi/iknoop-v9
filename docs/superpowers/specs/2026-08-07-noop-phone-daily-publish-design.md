# NOOP phone viewer daily publish — design

## Goal

Refresh the encrypted NOOP phone-viewer snapshot every day at 08:15 in the
Mac's local Pacific time. If the laptop is asleep at that time, publish when
it next wakes. The phone must continue to serve the last known-good encrypted
snapshot if a run fails.

## Chosen approach

A per-user macOS LaunchAgent runs a small local wrapper. The wrapper invokes
the existing `noop-publish` executable with its Keychain passphrase source,
then transfers only the resulting encrypted `noop-data.json` to Freckleclaw.
The server installs that file atomically into the root-owned standalone viewer
directory served privately by Tailscale HTTPS on port 8444.

`StartCalendarInterval` schedules 08:15. macOS runs missed calendar jobs at
the next wake, which is the intended closed-lid-laptop behavior. The agent is
not a `KeepAlive` job and does not wake the Mac itself.

## Components and data flow

1. `~/Library/LaunchAgents/...plist` starts the local wrapper at 08:15.
2. The wrapper builds or uses the verified local `noop-publish` binary and
   writes its encrypted output to a private temporary directory outside the
   repository.
3. The wrapper transfers the encrypted JSON over SSH to a temporary remote
   file beneath `/srv/noop-health`.
4. A remote rename replaces `/srv/noop-health/noop-data.json` atomically.
   The standalone viewer therefore sees either the previous complete payload
   or the new complete payload, never a partial write.
5. The root-owned, tailnet-only HTTPS viewer at
   `https://freckleclaw.tail4d0805.ts.net:8444/` fetches and decrypts that
   file in the iPhone browser.

The wrapper never transfers the passphrase, the SQLite store, plaintext JSON,
or raw sensor tables.

## Failure handling and observability

- Any local publish, SSH, or remote-install failure exits non-zero and leaves
  the last served payload intact.
- Logs record timestamps, command outcome, and encrypted-payload byte counts
  only; they never log passphrases or health values.
- `StandardOutPath` and `StandardErrorPath` point to a private local log
  directory. The scheduled job has no retry loop beyond launchd's next
  calendar/wake opportunity, preventing repeated connection attempts while
  the VPS is unavailable.

## Verification

Before loading the agent, run the wrapper once manually and verify:

1. `noop-publish --self-test` succeeds.
2. The remote payload replacement is atomic and root-owned.
3. The private HTTPS viewer returns the updated payload.
4. The iPhone displays the new payload after a refresh.

After loading, inspect the LaunchAgent state and log paths. The next actual
08:15-or-wake run is the final scheduling verification.

## Scope boundaries

This adds the scheduled publishing path only. It does not add a Hermes
dashboard plugin, plaintext metrics on the VPS, Telegram delivery, public
internet exposure, or a wake-from-sleep policy.

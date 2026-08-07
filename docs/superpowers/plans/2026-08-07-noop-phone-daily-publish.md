# NOOP Phone Daily Publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish an encrypted NOOP phone-viewer snapshot at 08:15 Pacific each day, or at the next Mac wake after a missed run, without ever transferring plaintext health data or replacing the last good remote payload on failure.

**Architecture:** A per-user LaunchAgent invokes a checked-in zsh wrapper. The wrapper builds and self-tests the existing dependency-free Swift publisher, writes its encrypted envelope into a `mktemp` directory under `/private/tmp`, uploads it over SSH, and asks Freckleclaw to atomically rename it within the root-owned static viewer directory. Installation copies only the plist into the logged-in user’s LaunchAgents directory; the wrapper remains in the repository so its behavior is reviewable and versioned.

**Tech Stack:** macOS launchd plist, zsh, Swift Package Manager, `noop-publish`, macOS Keychain, OpenSSH/SCP, Tailscale Serve static files.

## Global Constraints

- The schedule is 08:15 in the Mac’s local Pacific time; a missed `StartCalendarInterval` run occurs on next wake and the job must not wake the Mac itself.
- The passphrase is read only by `noop-publish` from the login Keychain; it is never an argument, environment variable, log value, remote value, or repository file.
- Transfer only the encrypted `noop-data.json`; never transfer SQLite, plaintext JSON, raw sensor tables, or Keychain material.
- Freckleclaw’s served payload is `/srv/noop-health/noop-data.json`, root-owned, and replaced by a same-directory atomic rename.
- The private viewer remains `https://freckleclaw.tail4d0805.ts.net:8444/`; do not change Caddy, Hermes, dashboard port 8443, or public exposure.
- A failed build, publish, connection, copy, or remote install exits non-zero and preserves the previous served payload.
- Logs contain timestamps, command success/failure, and encrypted byte counts only; local logs are private to the Mac user.
- No biometric data may enter git. Do not alter NOOP.app, `project.yml`, the permanent fork patches, migrations, or Android code.

---

### Task 1: Add the reviewable encrypted-publish wrapper

**Files:**
- Create: `workspace/noop-phone/scripts/publish-daily.sh`
- Create: `workspace/noop-phone/scripts/test-publish-daily.sh`
- Modify: `workspace/noop-phone/.gitignore` only if a script-created artifact is not already covered by the repository ignore rules

**Interfaces:**
- Consumes: `workspace/noop-phone/.build/release/noop-publish`, macOS login Keychain item service `noop-publish`, and SSH access as `root@94.130.96.213`.
- Produces: one encrypted local file named `noop-data.json` in a private temporary directory and, on complete success, `/srv/noop-health/noop-data.json` on Freckleclaw.
- Invocation: `publish-daily.sh`; configuration is immutable shell constants `PROJECT_DIR=/Users/imrankhan/Projects/NOOP/workspace/noop-phone`, `REMOTE_HOST=root@94.130.96.213`, and `REMOTE_DIR=/srv/noop-health`.

- [ ] **Step 1: Write the failing wrapper contract test**

Create `workspace/noop-phone/scripts/test-publish-daily.sh` as an executable zsh test that creates a temporary fake project tree and prepends fake `swift`, `scp`, and `ssh` executables to `PATH`. The test must run a copied wrapper with `PROJECT_DIR` replaced by the temporary tree and assert all of the following:

```zsh
[[ -s "$fake_remote/.noop-data.json.pending" ]]
[[ ! -e "$fake_remote/noop-data.json" ]] # before the fake remote mv
[[ "$captured_scp_source" == */noop-data.json ]]
[[ "$captured_scp_source" != *"plaintext"* ]]
[[ "$captured_ssh_command" == *"mv -f"* ]]
[[ "$captured_ssh_command" == *"/srv/noop-health/noop-data.json"* ]]
```

Make the fake publisher write a recognisable encrypted-only fixture (`{"ciphertextB64":"sealed"}`), make fake `scp` copy it to the requested pending filename, and make fake `ssh` record its command and emulate the remote `mv`. Add a second case in which fake `scp` exits 1; assert the wrapper exits non-zero and the existing `noop-data.json` remains byte-identical.

- [ ] **Step 2: Run the wrapper contract test to verify it fails**

Run: `zsh workspace/noop-phone/scripts/test-publish-daily.sh`

Expected: FAIL because `publish-daily.sh` does not exist.

- [ ] **Step 3: Implement the minimal safe wrapper**

Create `workspace/noop-phone/scripts/publish-daily.sh` with `#!/bin/zsh`, `set -euo pipefail`, and these concrete behaviors:

```zsh
PROJECT_DIR=/Users/imrankhan/Projects/NOOP/workspace/noop-phone
REMOTE_HOST=root@94.130.96.213
REMOTE_DIR=/srv/noop-health
PRIVATE_TMP_ROOT=/private/tmp

tmp_dir=$(mktemp -d "$PRIVATE_TMP_ROOT/noop-phone-publish.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
cd "$PROJECT_DIR"
swift build -c release
.build/release/noop-publish --self-test
.build/release/noop-publish --out "$tmp_dir"
payload="$tmp_dir/noop-data.json"
[[ -s "$payload" ]] || { print -u2 'encrypted payload missing or empty'; exit 1; }
bytes=$(stat -f '%z' "$payload")
scp -- "$payload" "$REMOTE_HOST:$REMOTE_DIR/.noop-data.json.pending"
ssh -- "$REMOTE_HOST" "chown root:root '$REMOTE_DIR/.noop-data.json.pending' && chmod 0644 '$REMOTE_DIR/.noop-data.json.pending' && mv -f '$REMOTE_DIR/.noop-data.json.pending' '$REMOTE_DIR/noop-data.json'"
print -- "published encrypted payload bytes=$bytes"
```

Use a `log()` helper that prefixes local timestamps but never prints command arguments containing payload contents. Do not use `--plaintext-out`, `NOOP_PUBLISH_PASSPHRASE`, `KeepAlive`, or any retry loop. Adjust only the test’s explicit substitution mechanism if necessary so the production constants remain exact.

- [ ] **Step 4: Run static and behavioral checks**

Run:

```bash
zsh -n workspace/noop-phone/scripts/publish-daily.sh
zsh workspace/noop-phone/scripts/test-publish-daily.sh
rg -n 'plaintext-out|NOOP_PUBLISH_PASSPHRASE|passphrase' workspace/noop-phone/scripts/publish-daily.sh
```

Expected: syntax and contract test pass; the final search has no matches.

- [ ] **Step 5: Commit the wrapper and its contract test**

```bash
git add workspace/noop-phone/scripts/publish-daily.sh workspace/noop-phone/scripts/test-publish-daily.sh workspace/noop-phone/.gitignore
git commit -m "feat: add encrypted NOOP phone publisher wrapper"
```

### Task 2: Install and verify the per-user daily LaunchAgent

**Files:**
- Create: `workspace/noop-phone/launchd/com.noopapp.noop-phone-publish.plist`
- Modify: `workspace/noop-phone/scripts/publish-daily.sh` only if the manual production run exposes a verifiable failure
- Create outside git: `~/Library/LaunchAgents/com.noopapp.noop-phone-publish.plist`
- Create outside git: `~/Library/Logs/NOOP/`

**Interfaces:**
- Consumes: `workspace/noop-phone/scripts/publish-daily.sh` from Task 1.
- Produces: launchd label `com.noopapp.noop-phone-publish`, scheduled `StartCalendarInterval` dictionary `{ Hour = 8; Minute = 15; }`, and private standard logs at `~/Library/Logs/NOOP/noop-phone-publish.{out,err}.log`.

- [ ] **Step 1: Write a failing plist validation check**

Run the following before creating the plist:

```bash
plutil -lint workspace/noop-phone/launchd/com.noopapp.noop-phone-publish.plist
```

Expected: FAIL because the plist does not exist.

- [ ] **Step 2: Create the LaunchAgent plist**

Create a plist with this exact functional shape:

```xml
<key>Label</key><string>com.noopapp.noop-phone-publish</string>
<key>ProgramArguments</key>
<array><string>/bin/zsh</string><string>/Users/imrankhan/Projects/NOOP/workspace/noop-phone/scripts/publish-daily.sh</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>15</integer></dict>
<key>StandardOutPath</key><string>/Users/imrankhan/Library/Logs/NOOP/noop-phone-publish.out.log</string>
<key>StandardErrorPath</key><string>/Users/imrankhan/Library/Logs/NOOP/noop-phone-publish.err.log</string>
```

Do not add `RunAtLoad`, `KeepAlive`, `StartInterval`, environment passphrase fields, or a timezone field. `launchd` follows the logged-in Mac user’s local timezone.

- [ ] **Step 3: Validate the plist before installation**

Run:

```bash
plutil -lint workspace/noop-phone/launchd/com.noopapp.noop-phone-publish.plist
plutil -p workspace/noop-phone/launchd/com.noopapp.noop-phone-publish.plist
```

Expected: `OK`; printed dictionary includes the exact label, zsh wrapper path, 08:15 calendar interval, and both private log paths.

- [ ] **Step 4: Manually run the real wrapper and verify the private endpoint**

Run:

```bash
zsh workspace/noop-phone/scripts/publish-daily.sh
ssh -o BatchMode=yes root@94.130.96.213 "stat -c '%U:%G %a %s %n' /srv/noop-health/noop-data.json"
ssh -o BatchMode=yes root@94.130.96.213 "curl --fail --silent --show-error https://freckleclaw.tail4d0805.ts.net:8444/noop-data.json -o /dev/null -w 'status=%{http_code} bytes=%{size_download} tls=%{ssl_verify_result}\n'"
```

Expected: the wrapper reports a nonzero encrypted byte count; remote ownership/mode is `root:root 644`; HTTPS reports `status=200`, positive bytes, and `tls=0`. On the iPhone, refresh the viewer and confirm it decrypts with the existing passphrase.

- [ ] **Step 5: Install, load, and one-shot test the agent**

Run:

```bash
mkdir -p "$HOME/Library/Logs/NOOP"
chmod 700 "$HOME/Library/Logs/NOOP"
cp workspace/noop-phone/launchd/com.noopapp.noop-phone-publish.plist "$HOME/Library/LaunchAgents/com.noopapp.noop-phone-publish.plist"
launchctl bootout "gui/$(id -u)/com.noopapp.noop-phone-publish" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.noopapp.noop-phone-publish.plist"
launchctl kickstart -k "gui/$(id -u)/com.noopapp.noop-phone-publish"
launchctl print "gui/$(id -u)/com.noopapp.noop-phone-publish"
tail -n 40 "$HOME/Library/Logs/NOOP/noop-phone-publish.out.log"
tail -n 40 "$HOME/Library/Logs/NOOP/noop-phone-publish.err.log"
```

Expected: `launchctl print` shows the 08:15 calendar interval and no restart policy; logs show an encrypted byte count and no health values or passphrase. If loading succeeds but the kickstart run fails, retain the last good remote file, diagnose before editing, and do not claim scheduling is ready.

- [ ] **Step 6: Commit the versioned plist**

```bash
git add workspace/noop-phone/launchd/com.noopapp.noop-phone-publish.plist workspace/noop-phone/scripts/publish-daily.sh
git commit -m "feat: schedule daily NOOP phone publishing"
```

### Task 3: Replace obsolete deployment handoffs with the standalone secure model

**Files:**
- Modify: `workspace/noop-phone/README.md`
- Modify: `workspace/state.md`
- Modify on Freckleclaw: `/opt/data/hermes-work/NEXT_STEPS.md`

**Interfaces:**
- Consumes: completed standalone service at `https://freckleclaw.tail4d0805.ts.net:8444/` and LaunchAgent label `com.noopapp.noop-phone-publish`.
- Produces: accurate operational recovery instructions that do not direct a future worker to reinstall the rejected agent-writable Hermes plugin.

- [ ] **Step 1: Write a failing documentation guard**

Run:

```bash
rg -n 'OPEN DECISION|hermes dashboard plugin|/home/hermes/.hermes/plugins|tailnet is plain HTTP' workspace/noop-phone/README.md workspace/state.md
```

Expected: matches, proving the stale handoff still exists.

- [ ] **Step 2: Update the local README and state handoff**

Replace the README’s “open decision” and old pickup checklist with the deployed architecture: standalone root-owned static directory `/srv/noop-health`, tailnet-only Tailscale HTTPS port 8444, existing Keychain item, and the tracked wrapper/plist installation steps. State explicitly that the Hermes plugin was removed because it was agent-writable and iframe sandboxing prevented payload fetches. Include the exact health-check URL and the current schedule semantics (08:15 local time, late after wake, no Mac wake). Update `workspace/state.md`’s NEXT PICKUP to mark the phone viewer and timer as deployed, identify the first future check as the next actual 08:15-or-wake run, and retain the privacy boundaries.

- [ ] **Step 3: Update the remote docs-first handoff without touching Hermes runtime**

Over SSH, replace only the NOOP Health section of `/opt/data/hermes-work/NEXT_STEPS.md` with a concise statement that the viewer is a standalone root-owned static service at port 8444 and is not a Hermes plugin. Include the status check:

```sh
curl --fail --silent --show-error https://freckleclaw.tail4d0805.ts.net:8444/noop-data.json -o /dev/null
```

Do not modify `/opt/data/plugins`, container files, dashboard routes, Caddy, or Tailscale Serve mappings in this documentation task.

- [ ] **Step 4: Run documentation and repository hygiene checks**

Run:

```bash
rg -n 'OPEN DECISION|/home/hermes/.hermes/plugins|hermes dashboard plugin' workspace/noop-phone/README.md workspace/state.md
rg -n '8444|com\.noopapp\.noop-phone-publish|/srv/noop-health' workspace/noop-phone/README.md workspace/state.md
git diff --check
git status --short
```

Expected: the first search has no matches in the two local handoffs; the second finds the deployed endpoint and timer; whitespace check passes; no payload artifacts appear in status.

- [ ] **Step 5: Commit local documentation**

```bash
git add workspace/noop-phone/README.md workspace/state.md
git commit -m "docs: record standalone NOOP phone viewer deployment"
```

### Task 4: Final end-to-end verification and handoff

**Files:**
- Verify only: `workspace/noop-phone/scripts/publish-daily.sh`
- Verify only: `workspace/noop-phone/launchd/com.noopapp.noop-phone-publish.plist`
- Verify only: `workspace/noop-phone/README.md`

**Interfaces:**
- Consumes: all tasks above and the iPhone connected to the same Tailscale tailnet.
- Produces: evidence that a fresh encrypted snapshot reaches the actual phone and that the next scheduled-or-wake run is the only remaining time-based observation.

- [ ] **Step 1: Run all local deterministic checks**

Run:

```bash
zsh -n workspace/noop-phone/scripts/publish-daily.sh
zsh workspace/noop-phone/scripts/test-publish-daily.sh
cd workspace/noop-phone && swift build -c release && .build/release/noop-publish --self-test
plutil -lint launchd/com.noopapp.noop-phone-publish.plist
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 2: Verify the installed agent and remote payload**

Run:

```bash
launchctl print "gui/$(id -u)/com.noopapp.noop-phone-publish"
ssh -o BatchMode=yes root@94.130.96.213 "stat -c '%U:%G %a %s %n' /srv/noop-health/noop-data.json"
ssh -o BatchMode=yes root@94.130.96.213 "curl --fail --silent --show-error https://freckleclaw.tail4d0805.ts.net:8444/noop-data.json -o /dev/null -w 'status=%{http_code} bytes=%{size_download} tls=%{ssl_verify_result}\n'"
```

Expected: launchd lists the 08:15 calendar job without `KeepAlive`; remote file is `root:root 644` and nonempty; HTTPS is 200 with TLS validation success.

- [ ] **Step 3: Verify on the actual iPhone and record the bounded remaining observation**

On the iPhone, with Tailscale connected, open `https://freckleclaw.tail4d0805.ts.net:8444/`, refresh, enter the passphrase, and confirm the visible payload age reflects the manual/one-shot run. Record that launchd’s next naturally scheduled 08:15-or-wake execution remains the time-based confirmation; it requires no further code change or persistent monitoring.

- [ ] **Step 4: Commit any verification-only correction and report evidence**

If verification required a local tracked correction, commit it separately with a focused message. Otherwise make no empty commit. Report the exact checks that passed, the server ownership/mode, the iPhone result, and that failed future runs preserve the previously served encrypted snapshot by design.

#!/bin/zsh
# Runs every 15 min (LaunchAgent StartInterval). Publishes only when the offload frontier (newest
# gravitySample) has advanced past the last SUCCESSFULLY transferred one, so a closed-lid night reaches
# the phone shortly after the Mac opens and the strap catches up — instead of at a fixed 08:15 that
# usually fires before the night has offloaded.
#
# Phone write-back: before publishing, the wrapper pulls the receiver's inbox (/srv/noop-inbox), hands the
# files to `noop-publish --inbox-dir`, and afterwards — whatever the publisher's exit code — deletes
# exactly the ids the publisher listed in processed-ids (committed AND rejected). Ids are validated
# against the uuid4 pattern before they enter a remote command; there is never a glob delete.
#
# Log hygiene: stdout/stderr land in ~/Library/Logs/NOOP. Only timestamps, byte counts, frontier unix
# times and the publisher's `noop-publish-reason:` category are logged — never its summary lines.
set -euo pipefail

PROJECT_DIR=/Users/imrankhan/Projects/NOOP/workspace/noop-phone
REMOTE_HOST=root@94.130.96.213
REMOTE_DIR=/srv/noop-health
REMOTE_INBOX_DIR=/srv/noop-inbox
PRIVATE_TMP_ROOT=/private/tmp
STATE_DIR=${NOOP_PHONE_STATE_DIR:-"$HOME/Library/Application Support/noop-phone"}
STATE_FILE="$STATE_DIR/last-published-frontier"
# Set when inbox entries were committed to the side store but no payload carrying them has been
# transferred yet: forces the next run to publish even though the frontier has not advanced.
PENDING_FILE="$STATE_DIR/publish-pending"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

log() {
  print -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
}
fail() {
  print -u2 -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
  exit 1
}

tmp_dir=$(mktemp -d "$PRIVATE_TMP_ROOT/noop-phone-publish.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
cd "$PROJECT_DIR"

if ! swift build -c release >"$tmp_dir/build.log" 2>&1; then
  tail -n 5 "$tmp_dir/build.log" >&2
  fail 'swift build failed'
fi
if ! .build/release/noop-publish --self-test >/dev/null 2>&1; then
  fail 'noop-publish self-test failed'
fi
# The Effects math is vendored from Packages/StrandAnalytics; refuse to publish if upstream changed it.
if ! zsh scripts/check-vendored.sh >/dev/null 2>&1; then
  fail 'vendored analytics drifted from Packages/StrandAnalytics (re-vendor; see scripts/check-vendored.sh)'
fi

# --- pull the inbox (ids validated before they reach any remote command) -----------------------------
inbox_dir="$tmp_dir/inbox"
mkdir -p "$inbox_dir"
pull_inbox() {
  local listing name
  local -a names=()
  listing=$(ssh -- "$REMOTE_HOST" "cd '$REMOTE_INBOX_DIR' && ls -1") || { log 'inbox pull failed (ssh ls)'; return 0 }
  for name in ${(f)listing}; do
    [[ "$name" == *.json && "${name%.json}" =~ $UUID_RE ]] && names+=("$name")
  done
  (( ${#names} )) || return 0
  # Explicit, validated names only (never a glob); 200 per call keeps the command line short.
  local -a chunk
  while (( ${#names} )); do
    chunk=("${(@)names[1,200]}"); names=("${(@)names[201,-1]}")
    ssh -- "$REMOTE_HOST" "cd '$REMOTE_INBOX_DIR' && tar -cf - -- ${chunk[*]}" | tar -xf - -C "$inbox_dir" 2>/dev/null \
      || { log 'inbox pull failed (tar)'; return 0 }
  done
}
pull_inbox

# Delete exactly what the publisher processed. Runs on EVERY exit path of the publisher (success, skip,
# guard failure): the entries are already committed to (or rejected by) the side store.
delete_processed() {
  local f="$tmp_dir/processed-ids" id
  [[ -s "$f" ]] || return 0
  local -a ids=()
  for id in ${(f)"$(<"$f")"}; do
    if [[ "$id" =~ $UUID_RE ]]; then ids+=("$id.json"); else log 'ignored a malformed processed id'; fi
  done
  while (( ${#ids} )); do
    local -a chunk=("${(@)ids[1,50]}"); ids=("${(@)ids[51,-1]}")
    ssh -- "$REMOTE_HOST" "cd '$REMOTE_INBOX_DIR' && rm -f -- ${chunk[*]}" || log 'inbox delete failed (will retry; entries are idempotent)'
  done
}

last=0
[[ -s "$STATE_FILE" ]] && last=$(<"$STATE_FILE")
[[ "$last" == <-> ]] || last=0
[[ -e "$PENDING_FILE" ]] && last=0

set +e
# 240 h, not the CLI's 48 h default: after a multi-day closed lid the strap catch-up takes a day or more,
# and dataMaxTs (the offload frontier) plus the viewer's banner already say exactly how stale it is.
.build/release/noop-publish --out "$tmp_dir" --inbox-dir "$inbox_dir" --skip-unless-after "$last" --max-age-hours 240 >/dev/null 2>"$tmp_dir/err"
rc=$?
set -e

# Safe summary: three counters, nothing else from the publisher's output.
if [[ -s "$tmp_dir/inbox-summary" ]]; then
  summary=$(<"$tmp_dir/inbox-summary")
  if [[ "$summary" =~ '^inbox: committed=([0-9]+) duplicate=([0-9]+) rejected=([0-9]+)$' ]]; then
    (( match[1] + match[2] + match[3] > 0 )) && log "inbox committed=${match[1]} duplicate=${match[2]} rejected=${match[3]}"
    if (( match[1] > 0 )); then mkdir -p "$STATE_DIR"; : > "$PENDING_FILE"; fi
  fi
fi
delete_processed

if (( rc == 3 )); then
  exit 0   # frontier unchanged since the last successful publish and no new entries — nothing to do
fi
if (( rc != 0 )); then
  reason=$(grep -m1 '^noop-publish-reason: ' "$tmp_dir/err" | sed 's/^noop-publish-reason: //')
  fail "noop-publish failed: ${reason:-unknown (run .build/release/noop-publish --out <dir> by hand)}"
fi

payload="$tmp_dir/noop-data.json"
[[ -s "$payload" ]] || fail 'encrypted payload missing or empty'
frontier=$(<"$tmp_dir/frontier")
[[ "$frontier" == <-> ]] || fail 'publisher did not report a frontier'
bytes=$(stat -f '%z' "$payload")
scp -q -- "$payload" "$REMOTE_HOST:$REMOTE_DIR/.noop-data.json.pending" || fail 'transfer failed (scp)'
ssh -- "$REMOTE_HOST" "chown root:root '$REMOTE_DIR/.noop-data.json.pending' && chmod 0644 '$REMOTE_DIR/.noop-data.json.pending' && mv -f '$REMOTE_DIR/.noop-data.json.pending' '$REMOTE_DIR/noop-data.json'" \
  || fail 'transfer failed (remote replace)'

# Record only after the remote replace succeeded, so a failed transfer is retried on the next run.
mkdir -p "$STATE_DIR"
print -r -- "$frontier" > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
rm -f "$PENDING_FILE"
log "published encrypted payload bytes=$bytes frontier=$frontier"

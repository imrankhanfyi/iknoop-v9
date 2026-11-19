#!/bin/zsh
# Contract tests for publish-daily.sh, against a fake publisher / scp / ssh. No network, no store.
set -euo pipefail

script_dir=${0:A:h}
wrapper_source="$script_dir/publish-daily.sh"

[[ -f "$wrapper_source" ]] || {
  print -u2 "missing wrapper: $wrapper_source"
  exit 1
}

test_root=$(mktemp -d /private/tmp/noop-phone-publish-test.XXXXXX)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fake_project="$test_root/project"
fake_bin="$test_root/bin"
fake_remote="$test_root/remote"
state_dir="$test_root/state"
mkdir -p "$fake_project/.build/release" "$fake_bin" "$fake_remote"
mkdir -p "$fake_project/scripts"
print -r -- 'exit 0' > "$fake_project/scripts/check-vendored.sh"

wrapper="$fake_project/publish-daily.sh"
sed "s|^PROJECT_DIR=.*|PROJECT_DIR=$fake_project|" "$wrapper_source" > "$wrapper"
chmod +x "$wrapper"

# Fake publisher. FAKE_FRONTIER = the store's offload frontier; FAKE_PUBLISH_FAIL=1 = guard failure
# (AFTER the inbox pass, as in the real tool); FAKE_BAD_ID=1 = a malformed line in processed-ids;
# FAKE_REJECT=1 = every inbox file is "rejected" rather than committed.
cat > "$fake_project/.build/release/noop-publish" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == "--self-test" ]]; then
  print -u2 -- 'private-summary days=30 sleeps=26'
  exit 0
fi
[[ "$1" == "--out" && "$3" == "--inbox-dir" && "$5" == "--skip-unless-after" && "$7" == "--max-age-hours" && "$8" == "240" ]]
out=$2; inbox=$4; last=$6; frontier=${FAKE_FRONTIER:-1000}
print -r -- "$last" > "$FAKE_CAPTURED_LAST"
committed=0; rejected=0
: > "$out/processed-ids"
for f in "$inbox"/*.json(N); do
  print -r -- "${f:t:r}" >> "$out/processed-ids"
  if [[ "${FAKE_REJECT:-0}" == 1 ]]; then rejected=$((rejected+1)); else committed=$((committed+1)); fi
done
[[ "${FAKE_BAD_ID:-0}" == 1 ]] && print -r -- '../../etc/passwd; rm -rf /' >> "$out/processed-ids"
print -r -- "inbox: committed=$committed duplicate=0 rejected=$rejected" > "$out/inbox-summary"
print -u2 -- 'private-summary days=30 sleeps=26 recovery=61'
if [[ "${FAKE_PUBLISH_FAIL:-0}" == 1 ]]; then
  print -u2 -- 'noop-publish: verify mismatch recovery 61 vs 62'
  print -u2 -- 'noop-publish-reason: stale-frontier age=99.0h'
  exit 1
fi
(( frontier > last || committed > 0 )) || exit 3
print -r -- '{"ciphertextB64":"sealed"}' > "$out/noop-data.json"
print -r -- "$frontier" > "$out/frontier"
EOF
chmod +x "$fake_project/.build/release/noop-publish"

cat > "$fake_bin/swift" <<'EOF'
#!/bin/zsh
print -- 'Building for production...'
exit 0
EOF
chmod +x "$fake_bin/swift"

cat > "$fake_bin/scp" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == "-q" ]] && shift
source=$2
destination=$3
print -r -- "$source" > "$FAKE_CAPTURED_SCP_SOURCE"
if [[ "${FAKE_SCP_FAIL:-0}" == 1 ]]; then
  exit 1
fi
cp -- "$source" "$FAKE_REMOTE/${destination:t}"
EOF
chmod +x "$fake_bin/scp"

# Fake ssh: dispatches on the remote command. Every command is logged for the assertions.
mkdir -p "$fake_remote/inbox"
cat > "$fake_bin/ssh" <<'EOF'
#!/bin/zsh
set -euo pipefail
command=$3
print -r -- "$command" >> "$FAKE_SSH_LOG"
case "$command" in
  *"ls -1"*) ls -1 "$FAKE_REMOTE/inbox" ;;
  *"tar -cf -"*)
    names=${command##*tar -cf - -- }
    (cd "$FAKE_REMOTE/inbox" && tar -cf - -- ${=names}) ;;
  *"rm -f --"*)
    names=${command##*rm -f -- }
    (cd "$FAKE_REMOTE/inbox" && rm -f -- ${=names}) ;;
  *"mv -f"*)
    print -r -- "$command" > "$FAKE_CAPTURED_SSH_COMMAND"
    [[ -s "$FAKE_REMOTE/.noop-data.json.pending" ]]
    mv -f -- "$FAKE_REMOTE/.noop-data.json.pending" "$FAKE_REMOTE/noop-data.json" ;;
  *) print -u2 "fake ssh: unexpected command"; exit 9 ;;
esac
EOF
chmod +x "$fake_bin/ssh"

run_wrapper() {
  PATH="$fake_bin:$PATH" \
  NOOP_PHONE_STATE_DIR="$state_dir" \
  FAKE_REMOTE="$fake_remote" \
  FAKE_CAPTURED_SCP_SOURCE="$test_root/captured-scp-source" \
  FAKE_CAPTURED_SSH_COMMAND="$test_root/captured-ssh-command" \
  FAKE_SSH_LOG="$test_root/ssh-log" \
  FAKE_CAPTURED_LAST="$test_root/captured-last" \
  "$wrapper"
}
assert_no_leak() {
  if rg -q 'private-summary|days=30|sleeps=26|recovery|Building for production' "$1"; then
    print -u2 "wrapper leaked publisher/build output into its log ($2)"
    exit 1
  fi
}

# 1. First publish: transfers, records the frontier, logs nothing private.
FAKE_FRONTIER=1000 run_wrapper >"$test_root/out1" 2>&1
assert_no_leak "$test_root/out1" 'first publish'
[[ -s "$fake_remote/noop-data.json" ]]
[[ "$(<"$test_root/captured-scp-source")" == */noop-data.json ]]
[[ "$(<"$test_root/captured-ssh-command")" == *"mv -f"*"/srv/noop-health/noop-data.json"* ]]
[[ "$(<"$state_dir/last-published-frontier")" == 1000 ]]
rg -q 'published encrypted payload bytes=[0-9]+ frontier=1000' "$test_root/out1"

# 2. Frontier unchanged: silent skip, exit 0, no transfer.
rm -f "$test_root/captured-scp-source"
FAKE_FRONTIER=1000 run_wrapper >"$test_root/out2" 2>&1
[[ ! -e "$test_root/captured-scp-source" ]] || { print -u2 'skip run still transferred'; exit 1; }
[[ ! -s "$test_root/out2" ]] || { print -u2 'skip run was not silent'; exit 1; }

# 3. Frontier advanced but the copy fails: wrapper fails, remote untouched, state NOT advanced.
print -r -- existing-encrypted-payload > "$fake_remote/noop-data.json"
before=$(cksum "$fake_remote/noop-data.json")
if FAKE_FRONTIER=2000 FAKE_SCP_FAIL=1 run_wrapper >"$test_root/out3" 2>&1; then
  print -u2 'wrapper succeeded despite failed copy'
  exit 1
fi
[[ "$before" == "$(cksum "$fake_remote/noop-data.json")" ]]
[[ "$(<"$state_dir/last-published-frontier")" == 1000 ]]
rg -q 'transfer failed \(scp\)' "$test_root/out3"

# 4. Publisher fails: the safe reason is logged, the detail line (with values) is not.
if FAKE_PUBLISH_FAIL=1 run_wrapper >"$test_root/out4" 2>&1; then
  print -u2 'wrapper succeeded despite publisher failure'
  exit 1
fi
rg -q 'noop-publish failed: stale-frontier age=99.0h' "$test_root/out4"
assert_no_leak "$test_root/out4" 'publisher failure'
if rg -q 'verify mismatch|61 vs 62' "$test_root/out4"; then
  print -u2 'wrapper logged the publisher detail line'
  exit 1
fi

# 5. The retry after a failed copy publishes the new frontier.
FAKE_FRONTIER=2000 run_wrapper >"$test_root/out5" 2>&1
[[ "$(<"$state_dir/last-published-frontier")" == 2000 ]]

# 6. Pull/delete flow. Valid-id files plus junk names: only validated names are fetched; entries force a
#    publish even though the frontier is unchanged; exactly the processed ids are deleted; a malformed id
#    never reaches ssh.
id1=3f2b8a14-5c6d-4e7f-8a9b-0c1d2e3f4a5b
id2=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
for id in $id1 $id2; do print -r -- '{}' > "$fake_remote/inbox/$id.json"; done
print -r -- '{}' > "$fake_remote/inbox/evil;touch-pwned.json"
print -r -- '{}' > "$fake_remote/inbox/.tmp-partial"
print -r -- '{}' > "$fake_remote/inbox/NOT-A-UUID.json"
: > "$test_root/ssh-log"
FAKE_FRONTIER=2000 FAKE_BAD_ID=1 run_wrapper >"$test_root/out6" 2>&1
assert_no_leak "$test_root/out6" 'inbox flow'
rg -q 'inbox committed=2 duplicate=0 rejected=0' "$test_root/out6"
rg -q 'ignored a malformed processed id' "$test_root/out6"
rg -q 'published encrypted payload' "$test_root/out6"
[[ "$(<"$state_dir/last-published-frontier")" == 2000 ]]
tar_cmd=$(rg 'tar -cf -' "$test_root/ssh-log")
[[ "$tar_cmd" == *"$id1.json"* && "$tar_cmd" == *"$id2.json"* ]]
if [[ "$tar_cmd" == *evil* || "$tar_cmd" == *NOT-A-UUID* || "$tar_cmd" == *'*'* ]]; then print -u2 'pull fetched an unvalidated name'; exit 1; fi
rm_cmd=$(rg 'rm -f --' "$test_root/ssh-log")
[[ "$rm_cmd" == *"$id1.json"* && "$rm_cmd" == *"$id2.json"* ]]
if [[ "$rm_cmd" == *passwd* || "$rm_cmd" == *'*'* || "$rm_cmd" == *';'* ]]; then print -u2 'delete used an unvalidated id'; exit 1; fi
[[ ! -e "$fake_remote/inbox/$id1.json" && ! -e "$fake_remote/inbox/$id2.json" ]]
[[ -e "$fake_remote/inbox/evil;touch-pwned.json" && -e "$fake_remote/inbox/NOT-A-UUID.json" ]]
[[ ! -e "$state_dir/publish-pending" ]]
rm -f "$fake_remote/inbox/evil;touch-pwned.json" "$fake_remote/inbox/NOT-A-UUID.json" "$fake_remote/inbox/.tmp-partial"

# 7. Publisher fails AFTER the inbox pass (guard failure): the processed ids are still deleted, the failure
#    is still reported with its safe reason only, and a pending marker forces the next run to publish.
print -r -- '{}' > "$fake_remote/inbox/$id1.json"
: > "$test_root/ssh-log"
if FAKE_FRONTIER=2000 FAKE_PUBLISH_FAIL=1 run_wrapper >"$test_root/out7" 2>&1; then
  print -u2 'wrapper succeeded despite publisher failure'; exit 1
fi
rg -q 'noop-publish failed: stale-frontier age=99.0h' "$test_root/out7"
assert_no_leak "$test_root/out7" 'guard failure with entries'
[[ ! -e "$fake_remote/inbox/$id1.json" ]]
rg -q "rm -f -- $id1.json" "$test_root/ssh-log"
[[ -e "$state_dir/publish-pending" ]]
FAKE_FRONTIER=2000 run_wrapper >"$test_root/out7b" 2>&1
[[ "$(<"$test_root/captured-last")" == 0 ]]
rg -q 'published encrypted payload' "$test_root/out7b"
[[ ! -e "$state_dir/publish-pending" ]]

# 8. Rejected-only inbox: still deleted server-side and counted in the log; with nothing else new the run
#    is a skip (exit 0, no transfer).
print -r -- '{}' > "$fake_remote/inbox/$id2.json"
: > "$test_root/ssh-log"; rm -f "$test_root/captured-scp-source"
FAKE_FRONTIER=2000 FAKE_REJECT=1 run_wrapper >"$test_root/out8" 2>&1
rg -q 'inbox committed=0 duplicate=0 rejected=1' "$test_root/out8"
[[ ! -e "$fake_remote/inbox/$id2.json" ]]
[[ ! -e "$test_root/captured-scp-source" ]] || { print -u2 'rejected-only inbox triggered a publish'; exit 1; }

# 9. Empty inbox + unchanged frontier stays completely silent, and runs no tar/rm.
: > "$test_root/ssh-log"
FAKE_FRONTIER=2000 run_wrapper >"$test_root/out9" 2>&1
[[ ! -s "$test_root/out9" ]] || { print -u2 'empty-inbox skip was not silent'; exit 1; }
if rg -q 'tar -cf|rm -f' "$test_root/ssh-log"; then print -u2 'empty inbox ran tar/rm'; exit 1; fi

print -- 'publish-daily wrapper contract tests passed (9 cases)'

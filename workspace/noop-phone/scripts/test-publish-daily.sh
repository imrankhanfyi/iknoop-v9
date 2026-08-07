#!/bin/zsh
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
mkdir -p "$fake_project/.build/release" "$fake_bin" "$fake_remote"

wrapper="$fake_project/publish-daily.sh"
sed "s|^PROJECT_DIR=.*|PROJECT_DIR=$fake_project|" "$wrapper_source" > "$wrapper"
chmod +x "$wrapper"

cat > "$fake_project/.build/release/noop-publish" <<'EOF'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == "--self-test" ]]; then
  print -u2 -- 'private-summary days=30 sleeps=26'
  exit 0
fi
[[ "$1" == "--out" ]]
print -u2 -- 'private-summary days=30 sleeps=26'
print -r -- '{"ciphertextB64":"sealed"}' > "$2/noop-data.json"
EOF
chmod +x "$fake_project/.build/release/noop-publish"

cat > "$fake_bin/swift" <<'EOF'
#!/bin/zsh
exit 0
EOF
chmod +x "$fake_bin/swift"

cat > "$fake_bin/scp" <<'EOF'
#!/bin/zsh
set -euo pipefail
source=$2
destination=$3
print -r -- "$source" > "$FAKE_CAPTURED_SCP_SOURCE"
if [[ "${FAKE_SCP_FAIL:-0}" == 1 ]]; then
  exit 1
fi
cp -- "$source" "$FAKE_REMOTE/${destination:t}"
EOF
chmod +x "$fake_bin/scp"

cat > "$fake_bin/ssh" <<'EOF'
#!/bin/zsh
set -euo pipefail
command=$3
print -r -- "$command" > "$FAKE_CAPTURED_SSH_COMMAND"
[[ -s "$FAKE_REMOTE/.noop-data.json.pending" ]]
[[ ! -e "$FAKE_REMOTE/noop-data.json" ]]
mv -f -- "$FAKE_REMOTE/.noop-data.json.pending" "$FAKE_REMOTE/noop-data.json"
EOF
chmod +x "$fake_bin/ssh"

run_wrapper() {
  PATH="$fake_bin:$PATH" \
  FAKE_REMOTE="$fake_remote" \
  FAKE_CAPTURED_SCP_SOURCE="$test_root/captured-scp-source" \
  FAKE_CAPTURED_SSH_COMMAND="$test_root/captured-ssh-command" \
  "$wrapper"
}

run_wrapper >"$test_root/wrapper-output" 2>&1
if rg -q 'private-summary|days=30|sleeps=26' "$test_root/wrapper-output"; then
  print -u2 'wrapper leaked publisher summary into its output'
  exit 1
fi

captured_scp_source=$(<"$test_root/captured-scp-source")
captured_ssh_command=$(<"$test_root/captured-ssh-command")
[[ -s "$fake_remote/noop-data.json" ]]
[[ "$captured_scp_source" == */noop-data.json ]]
[[ "$captured_scp_source" != *"plaintext"* ]]
[[ "$captured_ssh_command" == *"mv -f"* ]]
[[ "$captured_ssh_command" == *"/srv/noop-health/noop-data.json"* ]]

print -r -- existing-encrypted-payload > "$fake_remote/noop-data.json"
before=$(cksum "$fake_remote/noop-data.json")
if PATH="$fake_bin:$PATH" \
  FAKE_REMOTE="$fake_remote" \
  FAKE_CAPTURED_SCP_SOURCE="$test_root/captured-scp-source" \
  FAKE_CAPTURED_SSH_COMMAND="$test_root/captured-ssh-command" \
  FAKE_SCP_FAIL=1 \
  "$wrapper"; then
  print -u2 'wrapper succeeded despite failed copy'
  exit 1
fi
after=$(cksum "$fake_remote/noop-data.json")
[[ "$before" == "$after" ]]

print -- 'publish-daily wrapper contract tests passed'

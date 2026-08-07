#!/bin/zsh
set -euo pipefail

PROJECT_DIR=/Users/imrankhan/Projects/NOOP/workspace/noop-phone
REMOTE_HOST=root@94.130.96.213
REMOTE_DIR=/srv/noop-health
PRIVATE_TMP_ROOT=/private/tmp

log() {
  print -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
}

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
log "published encrypted payload bytes=$bytes"

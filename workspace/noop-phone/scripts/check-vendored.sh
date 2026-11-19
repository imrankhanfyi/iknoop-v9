#!/bin/zsh
# Fails if the vendored analytics in Sources/noop-publish/Vendored/ drifted from Packages/StrandAnalytics.
# Vendored copies are the upstream files with `public` stripped (same sed as below), plus a
# ScoreConfidence subset whose case list must match.
set -euo pipefail
here=${0:A:h}; repo=${here:h:h:h}
up="$repo/Packages/StrandAnalytics/Sources/StrandAnalytics"
vend="$here/../Sources/noop-publish/Vendored"
strip() { sed -E 's/^(\s*)public /\1/; s/([^a-zA-Z])public (static|let|var|func|init|struct|enum)/\1\2/g' "$1"; }
rc=0
for f in BehaviorInsights EffectRanker CorrelationEngine; do
  if ! diff -q <(strip "$up/$f.swift") "$vend/$f.swift" >/dev/null; then
    print -u2 "DRIFT: $f.swift differs from upstream (re-vendor and re-run --self-test)"; rc=1
  fi
done
if ! diff -q <(grep -E '^    case ' "$up/ScoreConfidence.swift") <(grep -E '^    case ' "$vend/ScoreConfidence.swift") >/dev/null; then
  print -u2 "DRIFT: ScoreConfidence cases differ from upstream"; rc=1
fi
(( rc == 0 )) && print 'vendored analytics match upstream'
exit $rc

// VENDORED SUBSET of Packages/StrandAnalytics/Sources/StrandAnalytics/ScoreConfidence.swift:
// only the three cases EffectRanker uses. The per-score derivation helpers (charge, effort…) pull in
// BaselineState and are not needed here. Drift-checked by scripts/check-vendored.sh (case list).
enum ScoreConfidence: String, Equatable, Sendable, Codable {
    case calibrating
    case building
    case solid
}

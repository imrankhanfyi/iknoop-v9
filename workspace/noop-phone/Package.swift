// swift-tools-version:5.9
import PackageDescription

// noop-publish — extracts the summary tier of the NOOP store into a small encrypted payload for
// the phone viewer. Deliberately dependency-free: SQLite3, CryptoKit, CommonCrypto and Compression
// are all system frameworks on macOS, so this never joins the GRDB-pinned dependency graph in
// Packages/* (which pins GRDB to an exact version — see Packages/NoopLocalAccess/Package.swift).
//
// This package lives under workspace/ on purpose: per the repo CLAUDE.md, workspace/ is a purely
// additive local directory that never conflicts on an upstream rebase. It is NOT part of any
// XcodeGen target (every target's `sources:` in project.yml is an explicit path).
let package = Package(
    name: "noop-publish",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "noop-publish", path: "Sources/noop-publish")
    ]
)

# Rust signed feed assembly

Local implementation of `maintainer update-feed assemble` and deprecated
`update-feed assemble`, based on signing SDK head `0294647b`. Six `runtime
update` lifecycle leaves remain explicitly blocked. No consumer network,
production private key, update installation, live signing credential, or device
operation was used. TASK-XPA-018/G5 remain incomplete.

The codec pins the existing production public key and signature domain, checks
the exact canonical envelope and typed payload, verifies Ed25519 before trusting
payload fields, and enforces static and clock checks before atomic output. CLI
reads are bounded to the codec limit plus one overflow sentinel. It has no
caller-selected public key or production signing API. Existing output is not
touched on verification refusal. The maintainer replay store remains empty and
in-memory, as in Swift; durable consumer replay is a separate remaining slice.

Feed JSON uses its own typed UInt64 encoding, not the CLI canonical-json/1
53-bit limit. `prepare` also uses the corrected encoding. Percent escapes in
artifact URLs are validated, then the decoded path is checked for `.dmg`,
preserving Swift's URLComponents behavior. Timestamp parsing refuses non-ASCII
before byte slicing, including malformed Unicode dates. No global canonical
JSON or URL policy was relaxed.

The existing actual Swift CLI oracle now replays all 31 cases (26 prepare,
5 assemble refusals). A new actual Swift XCTest produces ten public fixture-key
CryptoKit signatures, with full UInt64 and percent-escape boundaries. Rust
verifies those exact bytes and outcomes. Additional unit cases cover tampering,
wrong keys/domain, canonicality, malformed Base64, size and time boundaries.
Successful **production-key** feed creation was not run: the release private key
is deliberately unavailable. Fixture signatures are not production evidence.

The new dependency pins pass cargo-deny, but **cargo-vet still fails** for four
packages. See `update-feed-dependency-review.md` and exact public registry facts.
No trust rule, exemption, source-audit certification or approval was created.

## Local targeted checks

Window: 2026-09-26 approximately 14:23–14:32 UTC, one build/test lane at a time;
Rust used `CARGO_BUILD_JOBS=2` and independent target
`/private/tmp/arkdeck-takeover-d79c-target`.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0,
  **439 passed, 0 ignored** across 64 result groups,
  `/private/tmp/arkdeck-update-feed-cli-full.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings`:
  exit 0, `/private/tmp/arkdeck-update-feed-clippy-final.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter UpdateFeedSignedRustOracleTests`
  with `ARKDECK_RUST_SIGNED_FEED_RECORD=/private/tmp/arkdeck-update-feed-signed-oracle`:
  exit 0, **1 XCTest / 10 fixtures**, `/private/tmp/arkdeck-update-feed-swift.log`.
  The generated `signed.json` was copied byte-for-byte into the existing fixture directory.
- `cargo deny --locked check` from `rust/`: exit 0; advisories, bans, licenses,
  sources all pass, `/private/tmp/arkdeck-update-feed-deny.log`.
- `cargo vet --locked --no-registry-suggestions` after existing-source import
  refresh: **exit 255**, four missing source-audit chains,
  `/private/tmp/arkdeck-update-feed-vet-after-refresh.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check`:
  exit 0. `sh scripts/check-sdd.sh`: exit 0, 121 acceptance IDs,
  `/private/tmp/arkdeck-update-feed-sdd.log`.

The first CLI targeted attempt failed the obsolete blocked-leaf count of eight;
the test now counts the six remaining lifecycle leaves, and the full suite passed.
Sandbox-only cargo fetch failed DNS, and sandbox-only vet could not lock its
cache; permitted read-only public fetch/cache access resolved those environmental
failures. No full local unified gate, App UI test, or real device acceptance ran.
Contract input files were unchanged, so contract generation was not rerun.

## CI

No PR/run for this local slice. Remote push remains awaiting direct authorization
in this thread after automatic approval review rejected it. Local verification
does not imply dependency-gate success, maintainer approval, or merge.

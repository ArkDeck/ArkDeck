# Swift download and handoff oracle follow-up

Base: local consumer implementation `10a353db4ee42b3157ade360883a7a2e6ce77548`.
This follow-up changes only tests, their actual Swift recording and this record.
It does not change production code or the acceptance scope.

`RuntimeUpdateNetworkHandoffOracleTests` runs the existing Swift
`RuntimeUpdateApplicationFacade`, `AutoUpdateService`, lifecycle store and sealed
artifact cache under a temporary directory. Only transport, signature policy,
preferences and Finder reveal are injected. No production request, preference
write, Security success, Finder activation, installation or device operation runs.
The available feed is preseeded; feed verification is covered separately.

Eight scenarios execute download, handoff and repeated handoff: success, missing
consent, cancellation during an observed reveal, reveal failure, signature
validation failure, transport failure, oversized stream and cancellation before
materialization. The recording captures return success/refusal, durable phase,
failure category, generation, clock, busy/cancellation flags, material/partial
counts, validation/reveal counts and ordered events after every action. Paths,
random file names, operation UUIDs and inode identities are not compared; each
implementation independently verifies its actual sealed material.

The Rust integration test consumes the immutable Swift recording and exercises
the existing Rust consumer with the corresponding injected effects. It does not
reinterpret the expected Swift outcomes or generate them from Rust. This is
fixture behavior parity, not network delivery or hardware acceptance.

## Local targeted checks

All Rust commands use `CARGO_BUILD_JOBS=2` and the isolated
`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`; heavy commands are
serial. No broad suite was repeated for this tests-only follow-up.

- Actual Swift record mode: exit 0, one XCTest / eight scenarios / 24 observations,
  `/private/tmp/arkdeck-runtime-update-network-swift-record-3.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test runtime_update_network`:
  exit 0, one test comparing all 24 observations,
  `/private/tmp/arkdeck-runtime-update-network-rust-2.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --test runtime_update_network
  -- -D warnings`: exit 0, `/private/tmp/arkdeck-runtime-update-network-clippy.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  RuntimeUpdateNetworkHandoffOracleTests`: final ordinary comparison exit 0, one
  XCTest, `/private/tmp/arkdeck-runtime-update-network-swift-compare-final.log`.
  The final recorder fails on cache enumeration errors instead of treating them
  as empty directories; the unchanged recording still compares exactly.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`,
  `sh scripts/check-sdd.sh` and `git diff --check`: exit 0; logs
  `/private/tmp/arkdeck-runtime-update-network-fmt.log`,
  `/private/tmp/arkdeck-runtime-update-network-sdd.log` and
  `/private/tmp/arkdeck-runtime-update-network-diff.log`.
- Contract generation and App build were not repeated: no contract input,
  production source or App source changed.

The committed fixture is an unchanged copy of
`/private/tmp/arkdeck-runtime-update-network-oracle-3/consumer.json`, SHA-256
`3a2a7514aa1914aaaf8164221dd4e6d4d093b5a1ed840478e1f6cc904f89a1ec`.

The first Swift build failed because
JSONValue.integer requires Int64; the test now converts counts explicitly.
The first completed recording exposed a harness URL distinction: without
`.isDirectory`, the injected cache URL lacks the directory form used by both
production and existing Swift tests, so Swift's parent-URL equality rejects
material removal. The harness now uses those existing directory constructors;
the original recording remains at
`/private/tmp/arkdeck-runtime-update-network-oracle/consumer.json`. No production
cleanup semantics or expected fixture were manually changed.

## CI

No remote push or CI run for this follow-up. Remote destination authorization
remains pending after automatic approval review rejected the earlier push.
The four dependency audit gaps, maintainer release review, installed cutover,
GJ-1–5 device evidence and Swift target retirement are unchanged.

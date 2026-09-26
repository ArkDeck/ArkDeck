# Rust update lifecycle status, cancellation and cleanup

Local continuation of signed-feed head `f0e76727`. Rust now serves
`runtime update status|cancel|cleanup` against the same App container, immutable
state JSON and flock names as Swift. `check|download|handoff` remain explicitly
blocked. No production update network, installation, Finder action, signing
credential or device operation was used. TASK-XPA-018/G5 remain incomplete.

The store checks canonical typed JSON, ownership, single-link regular records,
0400 mode, bounded reads and generation CAS. Writes fully sync the staged inode,
seal it, sync again, rename and sync the directory. Fault injection exercises
pre-publication failure and unknown outcomes both before and after rename;
unknown outcomes are never rolled back or replayed. Operation leases remain
separate from short state locks, so status/cancel do not wait for a live owner.

Recovery settles abandoned active transitions while holding the operation lease.
It preserves referenced verified artifacts for ordinary status, while explicit
cleanup first publishes idle and then removes the selected cache artifact.
Cleanup uses anchored immediate unlink, never follows links or recurses through
directories. Projections omit local paths and URLs. The UInt64 state remains
lossless, including Swift's machine-envelope refusal beyond its 53-bit number
contract. Unsupported JSONL is refused as a JSON parse error before any owner
transition, matching the actual Swift CLI.

The Swift state oracle records 12 Codable snapshots and ten URL boundaries.
The process oracle records 20 actual Swift CLI cases under isolated
CFFIXED_USER_HOME roots, including a real parent-held flock, recovery/cache
outcomes, corrupt/writable records, maximum generation and all three JSONL
refusals. Only validated volatile timestamps and generated parse correlations
are normalized. Public fixture bytes and temporary files are test evidence,
not real-device or production-update acceptance.

## Local targeted checks

Rust used `CARGO_BUILD_JOBS=2` and independent target
`/private/tmp/arkdeck-takeover-d79c-target`; one build/test lane at a time.

- Initial `cargo test --manifest-path rust/Cargo.toml` with the two changed
  crates and their nine direct dependents exited **101** at the CLI process
  oracle: the new JSONL fixture exercised the already-built old refusal
  renderer. Before that failure, `arkdeck-agentd` and `arkdeck-bootstrap`
  completed with **226 passed / 1 ignored** across 23 result groups.
  Log: `/private/tmp/arkdeck-runtime-update-crates.log`.
- After the parser-rendering fix, `cargo test --manifest-path rust/Cargo.toml
  -p arkdeck-platform -p arkdeck-cli -p arkdeck-client -p arkdeck-soak
  -p arkdeck-hoststore -p arkdeck-rockchip-binding -p arkdeck-provider-workspace
  -p arkdeck-provider-hdc -p arkdeck-provider-arkforge`: **exit 0**, **1704 passed /
  22 ignored**, 213 result groups. Log:
  `/private/tmp/arkdeck-runtime-update-crates-final.log`. This completes the
  previously unexecuted crates and reruns CLI, without repeating agentd/bootstrap.
  Counts include nested subprocess test result groups, not acceptance scenarios.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform
  sealed_record_publication`: exit 0, one fault-injection test,
  `/private/tmp/arkdeck-runtime-update-publication.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  RuntimeUpdateRustOracleTests` with `ARKDECK_RUST_UPDATE_STATE_RECORD`:
  exit 0, one XCTest producing 12 states plus ten URL cases;
  `/private/tmp/arkdeck-runtime-update-state-swift-2.log` and
  `/private/tmp/arkdeck-runtime-update-state-oracle-2/states.json`.
- `python3 rust/scripts/record-runtime-update-oracle.py --swift-cli
  /Users/fuhanfeng/Library/Caches/com.arkdeck.ArkDeck/SwiftPM/ArkDeckKit/build/out/Products/Debug/arkdeck
  --out /private/tmp/arkdeck-runtime-update-cli-oracle-3`: exit 0, 20 actual
  Swift CLI cases, `/private/tmp/arkdeck-runtime-update-cli-swift-3.log`.
  The checked-in `cli.json` exactly matches that output. The final Rust CLI
  suite above replays all 20 through its integration test.
- All-target Clippy for the same 11 crates initially exited 101 on
  `items_after_test_module` in `owner.rs`; the test module was moved intact
  below the implementation, with no behavior change. Initial log:
  `/private/tmp/arkdeck-runtime-update-clippy.log`; final rerun:
  `/private/tmp/arkdeck-runtime-update-clippy-final.log`, **exit 0**.
- `python3 rust/scripts/generate-contract.py --check`: exit 0,
  `/private/tmp/arkdeck-runtime-update-contract.log` (105 methods, 1043 shapes).
  `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check`
  and `sh scripts/check-sdd.sh`: **exit 0**; SDD reports 121 acceptance IDs,
  `/private/tmp/arkdeck-runtime-update-sdd-final.log`.

Ignored tests retain their existing reasons: explicit real signed/native
installation or registry input is unavailable, performance measurements need a
quiet host, or a crash child is invoked only by its parent test. They are not
claimed as passed. The full logs retain each name and reason. No full local
unified gate, App UI acceptance, production update run or real device acceptance
was executed. The serial direct-dependency tests exceeded the ten-minute target;
no second heavy lane was started alongside them.

### First-creation lock race and ordinary oracle replay follow-up

A consumer watermark concurrency test exposed a first-creation race in the
shared updater lock primitive. Concurrent macOS `openat` calls with
`O_CREAT|O_NOFOLLOW|O_NONBLOCK` can return ENOENT to one opener even when the
other created the permanent lock. A separate Python `os.open` reproduction and
an unsandboxed Rust single-test run confirmed the observation. The primitive
now opens the existing immediate name once without O_CREAT on that error only.
It retains O_NOFOLLOW/O_CLOEXEC/O_NONBLOCK and all regular-file, ownership,
single-link, mode, flock and linked-inode checks. It does not sleep, loop,
delete/recreate the lock, repair a missing entry or retry a device operation.

Native regression tests race two first creators over 16 separate lock names,
prove they hold the same inode, and refuse linked/directory entries and an
unlinked root. The original publication failure test remains in that group.
Consumer replay tests also prove that two owners cannot accept different
payload digests at one sequence. Logs include the original failure:
`/private/tmp/arkdeck-runtime-update-replay-race-native.log`, and the corrected
three-case replay run: `/private/tmp/arkdeck-runtime-update-replay-fixed.log`.
Final native lock test group: **exit 0, three passed**,
`/private/tmp/arkdeck-runtime-update-lock-race-final.log`.

The state and signed-feed XCTest recorders shared fixture directories with
other producers, but the generic harness's ordinary comparison demanded an
exact whole-directory file set. Their normal mode now compares only each
producer's own file, still byte-for-byte. Actual fresh CryptoKit recording also
showed different signature bytes with identical key, payload and verdicts;
the signed-feed replay now verifies the original signed envelope through
CryptoKit and the current field verifier, comparing its payload and complete
output to the committed fixture. It never replaces or weakens the fixture's
signature. The third recording used to identify this difference remains at
`/private/tmp/arkdeck-update-feed-signed-oracle-3/signed.json` and was not copied
over the committed signed.json.

`sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
'RuntimeUpdate.*RustOracleTests|UpdateFeedSignedRustOracleTests'` without record
environment variables: **exit 0, three XCTests**, including the consumer replay
class under development, `/private/tmp/arkdeck-runtime-update-swift-replay-final.log`.
The preceding ordinary-mode run failed only the regenerated-signature byte
comparison; it is retained at `/private/tmp/arkdeck-runtime-update-swift-replay-default.log`.
The 11-crate checks above belong to the pre-follow-up owner implementation;
these focused regressions cover this newly discovered boundary. Final candidate
checks remain required before any authorized push. Platform/CLI all-target
Clippy, fmt, diff check and SDD (121 acceptance IDs) pass for this follow-up;
logs: `/private/tmp/arkdeck-runtime-update-followup-clippy.log` and
`/private/tmp/arkdeck-runtime-update-followup-sdd.log`.

## CI

No PR/run for this local slice. Remote push still awaits direct authorization in
this thread following automatic approval-review rejection. The preceding feed
slice still has four missing cargo-vet source-audit chains; no dependency trust
rule or exemption is added here. Local tests do not imply CI success, maintainer
approval, deployment or G5 completion.

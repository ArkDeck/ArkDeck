# Rust consumer update check, download and Finder handoff

Local continuation of `68611028a392dd1d0b5a063cb4f7a26afb17aa58`, dated
2026-09-27. The remaining three blocked registry leaves now route to the Rust
consumer implementation: `runtime update check|download|handoff`. The obsolete
blocked-leaf handler is removed; registry validation/help remain, and the other
three update lifecycle leaves retain their existing actual Swift process oracle.
This is local implementation evidence, not TASK-XPA-018/G5 acceptance.

Rust owns the pinned feed verification, durable replay watermark, allowlisted
HTTPS/redirect policy, byte budgets, artifact hashing, signature requirements,
operation lease, cancellation, terminal CAS and CLI projection. A narrow
Objective-C SDK bridge in `arkdeck-platform` provides Foundation URL syntax,
URLSession transport, Bundle/ProcessInfo metadata, standard preferences, Unified
Logging and main-thread NSWorkspace selection. No Swift sidecar or raw command
is introduced. Security.framework checks use the running program's validated
Team ID rather than a hard-coded Team or caller-supplied trust override.

The ephemeral HTTP session disables URL cache and cookie storage, rebuilds GET
headers for each approved redirect and delivers at most 64 KiB per callback.
Redirect authorization and the five-hop limit remain in Rust. Closing the
borrowed callback context is serialized on the delegate queue, then drained;
late callbacks see the closed state. Test-only unwind capture proves the ABI
boundary in an unwind-enabled test build; production panic=abort is unchanged.
No production update endpoint was contacted.

Downloads use immediate descriptor-relative random `.part`/`.dmg` names,
bounded streaming SHA-256, exact length, 0400 sealing, exclusive rename and
before/after inode metadata checks. Cache/diagnostic fsync fallback follows the
existing explicitly approved Swift durability downgrade; state/replay strict
sync is unchanged. Unknown publication is not rolled back or retried. An alias
such as `cache/alias/../file.dmg` could make lexical-parent checks hash one file
while Security/Finder reads another. The consumer now rejects these spellings:
decoded path bytes must equal the cache's immediate target, and hashing,
signature verification and reveal use that same target. A real temporary
symlink and encoded dot-segment variants prove zero signing calls on refusal.

Each operation holds its process lease until terminal publication. Cancellation
and terminal CAS are decided under one state transaction, closing Swift's
load-to-CAS gap while preserving the published cancellation semantics. Consent,
cancel and validation failures precede reveal. Once reveal has returned, a late
cancel cannot truthfully replace the observed handoff; terminal write failure
returns without replaying the external effect. Fixture tests separately cover
reveal refusal, material cleanup and lost state after an observed reveal.

Static review also found that reusing request-now for terminal state writes
could move `updatedAtUtc` backwards after another process's later cancel. The
production Store now uses an injected clock evaluated inside each short state
transaction, including initialization, replace, cancellation and completion.
Feed verification and preference attempt time retain request-now. Deterministic
fixtures keep the explicit-time fallback. Clock regression tests advance time
without sleeping and assert that clock evaluation occurs while the state lock
is held, and that a long download and cancel/reveal/finish report write time.

Diagnostics use the existing segment names, record format and defaults:
16 MiB quota, 1 MiB segment, 72 KiB record, directory/writer flock, owner-only
single-link entries, final torn-tail recovery and a poisoned writer after I/O
or binding failure. Only eight closed public updater events can enter either
sink; Unified Logging follows successful durable append. Unavailable logging
uses the existing no-op fallback. Rust reproduces the actual Swift Date
millisecond-boundary outputs captured in the logging oracle.

## Local targeted checks

All Rust work uses `CARGO_BUILD_JOBS=2` and the worktree-specific
`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`. Build/test commands
run serially. Final CLI and Clippy checks both passed after the clock correction.
The 11-crate run began before the transaction-clock correction. Its complete
compilation finished before subsequent source edits; those preclock sources are
bound by `/private/tmp/arkdeck-runtime-update-consumer-preclock-manifest.json`
(38 source/fixture entries and base HEAD). Its result will not be represented
as verification of the later clock change. A final CLI run covers that change.

- Final `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0,
  **477 passed / 0 ignored**, 65 result groups including nested subprocesses,
  `/private/tmp/arkdeck-runtime-update-consumer-cli-final.log`. Both clock
  regressions and all 20 owner plus 13 consumer process oracle cases pass.
- Final `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-platform
  -p arkdeck-cli -p arkdeck-agentd -p arkdeck-bootstrap -p arkdeck-client
  -p arkdeck-soak -p arkdeck-hoststore -p arkdeck-rockchip-binding
  -p arkdeck-provider-workspace -p arkdeck-provider-hdc
  -p arkdeck-provider-arkforge --all-targets -- -D warnings`: exit 0,
  `/private/tmp/arkdeck-runtime-update-consumer-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`,
  `python3 rust/scripts/generate-contract.py --check`, `sh scripts/check-sdd.sh`
  and `git diff --check`: each exit 0. Logs are respectively
  `/private/tmp/arkdeck-runtime-update-consumer-fmt.log`,
  `/private/tmp/arkdeck-runtime-update-consumer-contract.log`,
  `/private/tmp/arkdeck-runtime-update-consumer-sdd.log` and
  `/private/tmp/arkdeck-runtime-update-consumer-diff-check.log`.

- Preclock `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform
  -p arkdeck-cli -p arkdeck-agentd -p arkdeck-bootstrap -p arkdeck-client
  -p arkdeck-soak -p arkdeck-hoststore -p arkdeck-rockchip-binding
  -p arkdeck-provider-workspace -p arkdeck-provider-hdc
  -p arkdeck-provider-arkforge`: **exit 0, 1971 passed / 23 ignored**, 237 result
  groups, `/private/tmp/arkdeck-runtime-update-consumer-crates.log`. Counts
  include nested subprocess result groups, not acceptance scenarios. This
  serial direct-dependency run took about 15 minutes, beyond the ten-minute
  target; no parallel heavy lane was started. Existing ignored native-input,
  performance and parent-driven child cases keep their logged reasons.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform --lib
  update_http`: exit 0, six tests, `/private/tmp/arkdeck-update-http-tests-6.log`.
  These use local loopback sockets or an unresumed SDK task. The logged fixture
  callback panic is the expected unwind-boundary test.
- Native artifact writer: three tests, exit 0,
  `/private/tmp/arkdeck-update-download-tests.log`. Cache and cancelled-stream
  integration: two tests each, exit 0,
  `/private/tmp/arkdeck-runtime-update-cache-tests-2.log` and
  `/private/tmp/arkdeck-runtime-update-download-flow.log`.
- Actual Security.framework requirement parsing/unsigned artifact refusal:
  one test, exit 0, `/private/tmp/arkdeck-runtime-update-signing-native.log`.
  Fixture signing/order/alias checks: four tests, exit 0,
  `/private/tmp/arkdeck-runtime-update-artifact-tests-2.log`. This does not prove
  acceptance of a real Developer ID artifact.
- Consumer lifecycle: four multi-scenario tests, exit 0,
  `/private/tmp/arkdeck-runtime-update-consumer-flow-3.log`, including a reveal
  error followed by no replay. All reveal calls are fixture counters.
- Diagnostic store: three tests, exit 0,
  `/private/tmp/arkdeck-runtime-update-diagnostic-log.log`. Production metadata
  is read-only: one test, exit 0,
  `/private/tmp/arkdeck-runtime-update-production-metadata.log`.
- Logging codec/actual Swift rotation and time replay: two tests, exit 0,
  `/private/tmp/arkdeck-runtime-update-logging-replay-2.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  'RuntimeUpdate(Logging|Replay|URL)RustOracleTests'`: exit 0, three XCTest tests in
  ordinary compare mode, `/private/tmp/arkdeck-runtime-update-consumer-swift-compare.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test
  runtime_update --test runtime_update_registry`: exit 0, three tests,
  `/private/tmp/arkdeck-runtime-update-consumer-cli-rust.log`. Two tests replay
  20 owner and 13 consumer actual Swift process cases, including real parent-held
  flock. Every consumer case refuses before a production network/Finder effect.

Actual recorders use temporary directories and explicit record mode. Fixture
hashes (SHA-256) and producers:

| Fixture | Cases | Hash |
| --- | --- | --- |
| `runtime-update/replay.json` | 14 Swift watermark transactions | `fc30c8eb161d86847a614c5d0d0698241e946111c6dd6b13634b0c9a18e9a7a1` |
| `runtime-update/urls.json` | 16 artifacts + 8 redirects + 2 feeds | `1cc7c1bc618ff7e9c54fc4952939a4fd8229e684add5765410681f08ea20f0c4` |
| `runtime-update/logging.json` | 8 events/rotation snapshots + 6 timestamp boundaries | `6a048c48da7de1e5d88f8b45f5f6ef2da5b70974513d415db7087f4c622c9f25` |
| `runtime-update/consumer-cli.json` | 13 actual Swift CLI refusals | `734918bb3c5c58011d4cd8f2c93438f7eea34241099ee9bd0ee9d735dd01c238` |

The first logging replay failed because Swift formats the parsed `.123` instant
as `.122`; the second actual recording adds reference clock inputs/boundaries,
and Rust matches them without changing expected outputs. Initial cache-test
compilation referenced a dependency absent from CLI; it was replaced with the
existing contract hash helper, adding no dependency. Initial Clippy found a
collapsible conditional and passed after the mechanical correction. The first
lost-state consumer test expected resourceConflict, but `complete_operation`
explicitly returns recordUnreadable for a missing record; the exact expectation
was corrected, retaining both no-replay assertions. Initial consumer process
recording failed on a parse-generated correlation; known missing/invalid consent
cases now validate and normalize that UUID just like the JSONL parse cases.

## CI

No remote push, PR or CI run exists for this local consumer slice. Explicit
authorization for the remote code destination remains pending following the
automatic approval review rejection. The four signed-feed dependency audit
gaps also remain open; no trust, exemption or audit approval was added here.

No App UI build/acceptance, production update download, real Developer ID success,
Finder activation, installation or device operation was executed. Fixture,
loopback and SDK refusal results do not constitute hardware evidence. Protected
main publication, maintainer review, installed-runtime/App cutover, current
Catalog GJ-1–5 acceptance and Swift target retirement remain separate goal work.

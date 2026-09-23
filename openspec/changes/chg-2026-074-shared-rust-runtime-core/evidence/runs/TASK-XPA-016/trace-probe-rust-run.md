# TASK-XPA-016 — `trace.probe` on the Rust daemon (M1 Observe)

Base: protected main `f06f83d0585499c327563c064d4ab17aa05175bc` (#2132); developed on `7d6382c9e`
(#2129) and rebased (see Local targeted checks).
Branch: `agent/xpa-016-trace-probe-rust`. CHG-2026-074, M1 (GJ-1 Observe), G5 queue slice 3.

## What a user sees

The Overview capability matrix's hitrace/bytrace rows and the Trace workspace ask the Runtime
`trace.probe` for one adopted Target. The isolated Rust daemon now answers it with Swift's
verdicts, through its production Host and verified HDC dispatch, and the standalone signed-App
ingress admits it with exactly `{"targetId": <string>}`. Rust `handle_frame` routes 94 of the
105 published methods (93 before), and the App ingress admits 26 non-Job methods (25 after
#2132).

## Swift semantics (the oracle)

`FoundationTraceRuntimeProbe` reads, with the daemon's runner (15 s each, 64 KiB kept for
help and tag lists, 4 KiB for a parameter):

- `-t <key> shell hitrace --help` and `-t <key> shell bytrace --help` concurrently, keeping
  any exit status. Only the registered `OPENHARMONY-TRACE-PROBES@1.0.0` bytes select a tool.
  A family needs an empty stderr and the exact size, and the SHA-256 of everything after a
  calendar-valid `YYYY/MM/DD HH:MM:SS ` must match. `hitrace` can be `captureEligible`,
  `bytrace` only `probeOnly`. Anything else is `unrecognized`, and a read that throws or
  truncates stdout is `probeFailed`. A non-zero exit adds `probe exited non-zero` without
  changing the verdict;
- `-t <key> shell hitrace -l` only after a registered hitrace help. When its registered tag
  list reads back, `adapterDisposition` becomes `captureEligible` with the 81 registered tags.
  An unregistered list is `unsupported`. A read with a transport marker, a non-zero exit, a
  truncated stdout, a signal or a timeout fails the whole probe: `rejected`,
  `Trace Runtime probe failed: <Swift's description>`;
- the nine catalog parameters (`param get`) beside them. OpenHarmony's exact, quiet
  `Get parameter "<key>" fail! errNum is:106!` is `missing`, and so is empty output. A value
  goes through the shared `key = value` echo rule. `unreadable` comes with its reason: a
  transport marker, a non-zero exit, truncation, output that is not UTF-8, a value over 400
  bytes, or the runner's `outcomeUnknown(...)`.

`rawHelp`/`rawHelpSha256` are the hitrace help text and digest whenever its read completed. The
text is null when the read was not UTF-8, and both are null when it failed. Missing
`targetId` (or a non-string) is `invalidParams: targetId is required`, and every other member
is ignored. With no probe composed, the answer is
`internalError: Trace Runtime probing is not configured`.

`TraceProbeOracleContractTests` (Swift-only, first commit) records this once. The daemon's
control-plane handler is composed with the production probe over the shared fake HDC. The fake
answers with the registered resources, copied under `resources/` and held byte-equal to the
integration registry by the test. It covers 22 exchanges: the portrait, a restamped family,
help with a non-zero exit, drifted help, an impossible month, a stderr diagnostic, swapped
families, a killed hitrace read beside a flooded bytrace read, help that is not UTF-8, three
unregistered tag lists, five lost tag lists (non-zero exit, `[Fail]` marker, signal, flood past
64 KiB, a 15 s timeout), two parameter matrices of nine cases each, an unadopted target, an
empty target and no parameters. The oracle directory is `rust/tests/fixtures/trace-probe/`:
the fake, its answers and resources, each exchange's calls sorted, the Target document, cases
and provenance. Recorded once, then compared byte for byte twice more.

Finding, not recorded: `ArkDeckProcess` spawns without close-on-exec. A child spawned while a
sibling's pipes are open inherits them and holds that sibling's output open. In the first
recording, one parameter read that hung (`sleep 30`) left four of its eight siblings reported
as `outcomeUnknown("process timed out before completion")` as well. Which siblings depends on
how the spawns interleave, so that case cannot be an oracle. The recorded timeout is the tag
list's, spawned alone after held help reads. The Rust spawn is close-on-exec by default
(`POSIX_SPAWN_CLOEXEC_DEFAULT`), so only the read that ran out of budget is unknown; the
provider test covers that.

### Schema

The published `trace.probe` schema came from a test double (`tools: []`, `rawHelp: null`).
It accepted none of the 14 production portraits recorded here, and the Rust control layer
rewrites a non-conforming answer to `internalError`. Re-derived from the committed corpus
plus these 22 frames only (the #1925/#1929 narrowing trap avoided: no other method was
derived), it widens `tool`, `family`, `rawHelp`, `rawHelpSha256`, `parameters[].value` and
`parameters[].detail` to `null | string`. It gives `tools[]` its only producer shape: a
closed object whose `detail`, `family` and `rawHelpSha256` are `null | string`. No item was
ever recorded before. `request`, `errorCode` and `errorDetails` are byte-identical. The
corpus keeps both committed lines and adds 11, one per new shape.
`spec/baselines/swift-single-v1.json` was regenerated (947 recorded shapes, 936 before;
contract identity unchanged).

## Rust

- `arkdeck-provider-hdc/src/trace_probe.rs`: the adapter (`evaluate_help`,
  `evaluate_tag_list` with the registered sizes and suffix digests) and `trace_probe`. The two
  help reads and nine parameter reads run on scoped threads together, then the tag list runs.
  Argv is fixed and target-bound (`-t <route key>`), with the budgets above. Swift's decoding
  rules are ported exactly:
  - strict UTF-8 with one leading byte-order mark dropped (Swift `String(data:encoding:)`
    does this, and the oracle records it);
  - stdout-only truncation: the dispatch reports either stream, and a stdout shorter than
    its capture beside a full stderr was whole;
  - Swift's `String(describing:)` of `RuntimeDispatchFailure`, quoted as
    `Unicode.Scalar.escaped` spells it.
- `arkdeck-hoststore/src/trace_probe.rs`: `HdcComposition::trace_probe` projects Swift's
  snapshot over the Target owner's route (`facts`, shared with the Debug reads).
- `arkdeck-control`: `trace.probe` route (string `targetId`, all Swift reads) and
  `HostServices::trace_probe` (default: Swift's unconfigured refusal).
- `arkdeck-agentd`: the Host composes it beside `debug_read`. The App ingress admits it with
  closed parameters (`targetId` only, schema-valid), as #2126/#2132 do.
- `rust/scripts/check-readonly.py`: `trace.probe` without parameters is `invalidParams`.
  A well-shaped request with no composed probe gets `internalError`, and a non-string target
  gets `invalidParams`.
- `rust/scripts/check-corpus-replay.py` now also replays probe oracles:
  - `trace.probe` is served;
  - a Target is seeded unless the oracle adopts one;
  - an oracle's `resources/` are installed;
  - where an oracle records `hdc-calls.log`, each exchange's sorted calls are compared
    instead of the driver's log.

Declared differences (all answer as Swift or fail closed):

1. When the tag list fails, Swift cancels the parameter reads it still awaits. Rust answers
   after they end, each within its 15 s budget. The answer is identical.
2. Descriptor inheritance: see the finding above. Rust never reports a sibling of a hung read
   as timed out.
3. Stdout and stderr both filled their capture and the dispatch reports truncation: Rust
   cannot tell which stream overflowed and counts the read as truncated. Swift's runner
   knows. This case is not reachable from the oracle.
4. Pre-existing and unchanged here: the shared `property_value` compares scalars where Swift
   compares Characters. So a `param get` echo whose `=` carries a combining mark keeps its
   whole text in Swift and is cut in Rust (also true of `observe.device`). Not recorded.

## Local targeted checks

All Rust commands use `CARGO_BUILD_JOBS=2` and
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target` with `--manifest-path rust/Cargo.toml`
(`check-contracts.py` gives each view its own target). Logs are `/private/tmp/arkdeck-s10-*`;
`-r-` marks the runs on the tree rebased onto `f06f83d05` (#2132, which merged meanwhile and
touched the App ingress allow-list lines this change extends; resolved by keeping both).

- Swift record: `ARKDECK_RUST_TRACE_PROBE_RECORD=… ARKDECK_CONTROL_FRAME_LOG=… sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  ArkDeckContractTests.TraceProbeOracleContractTests`: exit 0, 1 test, 22 frames
  (`-swift-record2.log`). Without a record variable, twice before the rebase and once after
  it together with `DebugProbeOracleContractTests`, whose harness gained the optional probe:
  exit 0, byte-equal (`-swift-compare-{1,2}.log`, `-r-swift-oracles.log`).
- Schema: `generate-control-contract.py --derive-method-schemas` over (committed
  `trace.probe.jsonl` ∪ the 22 frames); structural check: every old property and type kept,
  `tools[]` newly typed; jsonschema 4.26 over the 22 frames, both old corpus lines and the new
  corpus (37 values): 0 refusals; `ControlMethodSchemaContractTests` with only those frames in
  `ARKDECK_CONTROL_FRAME_LOG`: exit 0, 5 tests (`-swift-schema.log`).
- `python3 rust/scripts/generate-contract.py --write` then `--check`: exit 0; `--check` again
  after the rebase: exit 0 (`-generate-*.log`).
- `cargo fmt --all --check`: exit 0 (`-r-fmt.log`).
- `cargo clippy -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-control
  -p arkdeck-agentd -p arkdeck-soak -p arkdeck-contract -p arkdeck-cli -p arkdeck-client
  --all-targets -- -D warnings`: exit 0 (`-r-clippy.log`).
- `cargo test --no-fail-fast` for the same eight crates, after building `arkdeck-agentd` and
  `arkdeck-cli`: exit 0, 141 targets, 1,054 passed, 14 ignored, all pre-existing
  (`-r-tests-8crates.log`). The new tests:
  - `arkdeck-provider-hdc`: `tests/trace_probe.rs` 7 and `trace_probe::tests` 4;
  - `arkdeck-control` `read_only`: 2;
  - `arkdeck-agentd`: `trace_probe_control` 2 and `app_ingress::…::trace_probe_tests` 2.
  The replay test passes all 22 Swift answers and the 222 sorted calls through the production
  Host.
- `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/trace-probe`
  against the built daemon and CLI: PASS, 22 exchanges replayed, 28 checks, before and after
  the rebase. With the harness change, `observe-device` (PASS, 28 exchanges, 64 checks) and
  `target-adoption` (PASS, 18 exchanges, 26 checks) were also re-run.
- `rust/scripts/check-contracts.py --output-dir /private/tmp/arkdeck-s10-contract-check`:
  exit 0. The published view ran against merge base `f06f83d05` (5 commands, including
  workspace clippy and tests and `check-readonly.py`) and the candidate view ran all 18
  commands; both passed.
- `rust/scripts/test_contract_checks.py`: 42 tests, OK. `sh scripts/check-sdd.sh`: exit 0,
  0 errors, 0 warnings.
- No fake HDC process or oracle root was left after any run.

The shared validation venv (`/private/tmp/arkdeck-validation-venv`) had lost its
`pyvenv.cfg` and the `jsonschema` sources to host temp cleanup. The Python checks above ran in
a scratch venv with CI's pins (Python 3.14, PyYAML 6.0.3, jsonschema 4.26.0).

Not run: the App scheme, any other Swift class, signed Mach acceptance, any device, the
installed Runtime.

## CI

PR #2133, two commits, head `807f32118`; merged as `bfe959c74`.

- SDD Guard `35898141427` passed (`guard`, `ds-tokens`); Agent PR `35898141397` passed.
- Swift CI `35898141944` passed: `plan`, `swift-tests`, `ds-interactions`, Rust host-independent
  checks, the Rust workspace on ubuntu-latest, macos-26 (job `107307220625`) and windows-latest,
  and the `swift` aggregate. `app-build` was skipped by the plan; a skipped job is not a pass.

## Remaining

- The probe is composed only where the isolated development root composes an HDC dispatch
  and Target owner. The production standalone composition is G5 slice 6.
- Signed App ↔ Rust Mach acceptance (Q3), Rust CLI `trace probe` leaf (slice 14),
  `trace.inspect` (slice 13) and the capture legs the Trace workspace runs (slice 4).
- The Swift descriptor inheritance above is a Swift defect, left for the maintainer to judge
  (the Swift Runtime is a retirement target).

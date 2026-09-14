# TASK-XPA-016 — M1 run record: the HDC runtime status observer

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M1 (GJ-1), lane B's platform
executor: the object `runtime.hdc.status` answers with, recorded once from Swift as a T0 oracle
and answered by Rust byte for byte in the same slice. Host measurement only — not hardware,
platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device, no HDC server, no
daemon: the observer is driven in-process over the shared fake HDC driver at a fixed root under
`/private/tmp`, and the kernel-facing pieces are exercised against this test process.

Base: protected main `0ae4fe45` (#1944). Branch `agent/xpa-016-hdc-status-observer-20260914`; no
stacking. Files: one Swift test (additive), the oracle fixture (24 files), `arkdeck-platform`
(two functions and one visibility change), `arkdeck-provider-hdc` (`status.rs`, its test, one
`pub(crate)` and `serde_json` as a dependency), this record, one README section. No `agentd`,
`arkdeck-control`, schema, corpus or Swift production file changes.

## What was missing

The map of `HeadlessHDCStatusObserver` (`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/
DeviceProviders/HeadlessHDCStatusObserver.swift`) found Rust holding only `arkdeck-control`'s
six-field doctor summary (`HdcStatus`, a different vocabulary), no `runtime.hdc.status` arm, no
reader of a process's argv, and a `VerifiedTool::revalidate` the crate kept to itself; and the
repository held no recorded bytes of the twenty-three-member object beyond the three corpus
frames (an `invalidParams` refusal, the unconfigured shape, one `selectedServerNotObserved`
answer with a test-only signature). Nothing pinned the reason-code table, the ownership
decision, or what a failing tool withdraws.

## What the oracle records

`Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCStatusOracleContractTests.swift` composes
Swift's observer through its module-internal seam — the identity observation, the managed
process verdict and the launch record are the case's inputs; the signature inspection is the
production one — over the shared fake HDC driver (`HDCOracleFake.driver`, SHA-256
`208ff918…`, unsigned, so the production `SecStaticCode` inspection answers the unsigned
object) at the fixed root `/private/tmp/arkdeck-hdc-status-oracle`, under a fixed clock
(`2026-09-14T00:00:00Z`) and a fixed daemon version, and records twenty-two cases into
`rust/tests/fixtures/hdc-status/`: `cases.json` (every case's inputs), `provenance.json` (the
producer, root, tool path and digest, clock, the two registered identity families with their
digests, versions, exact endpoint and 1000 ms deadline, and every file's SHA-256) and
`snapshots/NN-<name>.json` (the answer's canonical bytes plus one newline).

| # | Case | Inputs departing from the managed baseline | availability / ownership / reasonCode |
| --- | --- | --- | --- |
| 00 | `unconfigured` | no tool (`unconfigured()`, no daemon version) | unavailable / unknown / `hdc.notConfigured` |
| 01 | `observed-managed` | launch `42@100.000023`, observed generation `100000023`, verified | available / arkDeckManaged / `hdc.identityObserved`; `generation` `"100000023"`, `processId` 42, the unsigned signature object |
| 02 | `…-unproven-no-launch` | no launch record | available / unknown / `hdc.ownershipUnproven` |
| 03 | `…-unproven-process-differs` | the live process not verified | the same |
| 04 | `…-unproven-birth-differs` | launch born at 101 s | the same |
| 05–10 | `…-identity-mismatch-{endpoint,digest,path,generation}`, `…-identity-missing`, `…-generation-zero` | the receipt at `:8711`, with digest `f`×64, at `other-hdc`, generation 7 vs the receipt's, no receipt, generation 0 | **unknown** / unknown / `hdc.identityMismatch`; `generation` and `processId` null |
| 11 | `unavailable` | | unavailable / unknown / `hdc.selectedServerNotObserved` |
| 12 | `unsupported` | | unavailable / unknown / `hdc.identityFamilyUnavailable` |
| 13–15 | `timed-out`, `cancelled`, `unknown` | | **unknown** / unknown / `hdc.identityObservationTimedOut`, `…Cancelled`, `hdc.identityUnknown` |
| 16–17 | `tool-changed-during-{observation,ownership}` | the tool's mode taken and restored under the read / under the verification | unavailable / unknown / `hdc.toolIdentityOrSignatureInvalid`; `executableSHA256`, `signature`, `clientVersion(+Source)`, `generation`, `processId` null |
| 18 | `tool-missing` | `absent-hdc` | the same |
| 19 | `tool-digest-mismatch` | configured digest `0`×64 | the same, `configuredExecutableSHA256` the zeros |
| 20 | `explicit-endpoint-unavailable` | `127.0.0.1:9000` / `explicit` | `hdc.selectedServerNotObserved`; `serverEndpointRef` of `:9000` |
| 21 | `inherited-endpoint-observed-unproven` | `127.0.0.1:8720` / `inheritedEnvironment`, receipt at `:8720`, no launch | `hdc.ownershipUnproven`; `serverEndpointRef` `hdc-endpoint:` + SHA-256(`127.0.0.1:8720`) |

Every answer has exactly the twenty-three members; `serverHealth` is `unknown`,
`healthReasonCode` `hdc.commandlessIdentityDoesNotProveHealth`, `serverVersion` null,
`newDispatchCount` 0 and `clientVersion` null (the driver's digest is registered to no family)
in all of them. Not recorded: the supervisor route of the ownership decision (an
`HDCServerSupervisor` actor cannot be composed in the seam) and a registered client version
(needs the real 3.2.0d/3.2.0f binaries) — both are unit-tested on the Rust side instead.

Recorded with `ARKDECK_RUST_HDC_STATUS_RECORD=/private/tmp/xpa016-hdc-status-r1`
(`oracle-status-record.log`: 1 test, 0 failures, after one compile fix of an `await` inside
`XCTUnwrap`'s autoclosure) and installed as `rust/tests/fixtures/hdc-status/` — 24 files. A
second run in compare mode reproduced every file byte for byte (`oracle-status-compare.log`: 1
test, 0 failures). The Swift test and the Rust replay share the root's lock
(`/private/tmp/arkdeck-hdc-status-oracle.lock`).

## What Rust answers

`arkdeck_provider_hdc::HdcStatusObserver` (`rust/crates/arkdeck-provider-hdc/src/status.rs`,
macOS) is the observer: `StatusExecutable` (Swift `ResolvedExecutable`), `StartupDiagnostics`
(`HDCManagedRuntimeDiagnostics`), `ManagedLaunch` (`HDCManagedProcessLaunch`, with `matches`),
`IdentityObservation` (`HDCSupervisorObservationResult`), the seam traits `IdentityObserver`,
`SignatureInspector`, `ManagedProcessVerifier`, `SupervisorState` (over `SupervisedServer`, the
part of `HDCServerState` the decision reads), `snapshot`, `unconfigured_status`,
`server_endpoint_ref`. The decision is Swift's line for line: the tool pinned by
`VerifiedTool::open` and re-proved by `revalidate` (now `pub`) after the signature, after the
observation and after the ownership check; the receipt matched on generation, digest, path and
endpoint; ownership through the launch read three times unchanged and matching the receipt with
the verifier's verdict, else through the supervisor's unchanged healthy managed record of the
observed generation; the reason-code table; the withdrawal on any tool failure.

The production pieces: `CommandlessIdentity` (`HDCCommandlessServerIdentity.observe`: the 3.2.0f
family only at `127.0.0.1:8710`, the 3.2.0d family at the selected loopback endpoint — the
crate's existing digest table — then `LoopbackServerLease::acquire` on a thread raced against
the 1000 ms deadline, `NotFound` as unavailable, other refusals as unknown, and the receipt
checked against the selected tool's canonical path, digest, endpoint and a representable birth);
`NativeSignature` (`inspect_native_code_signature` as `{state, identifier, teamIdentifier,
platformTrust: "unverified", executionAssessment: "notPerformed"}`); `SystemManagedProcess` over
the new `arkdeck_platform::verifies_managed_process` (Swift `verifiesManagedProcess` +
`SystemHDCManagedServerProcessInspector.matches`: a representable generation, the observed
birth before and after, the process alive (`kill(pid, 0)`), executable by `access(X_OK)`,
running the receipt's executable by `proc_pidpath`, its complete argv after argv[0] equal to
the launch's — `process_arguments`, the new `KERN_PROCARGS2` reader with Swift's exact walk —
declaring `-s <endpoint>`, and owning a TCP listener on the port bound to the loopback or a
wildcard, through the existing C listener scan).

`tests/hdc_status.rs` recreates the oracle's root with the driver from
`rust/tests/fixtures/observe-device/hdc` (its digest asserted equal to the provenance), replays
the twenty-two cases through the seam and the production signature inspection, and compares
`serde_json::to_vec` + newline with each snapshot — the first run matched all twenty-two. Its
second test checks the family table against the provenance's registered identities, that the
driver's digest is unsupported before any scan, that the production signature reading of the
driver equals case 01's object, and that this test process is never a managed server.

Unit tests: `arkdeck-platform` `macos_server` (the kernel argv of this process equals its own
argv after argv[0], none for a dead PID; a loopback and a wildcard listener bound by this
process are owned on their ports and not on another port, host or PID, nor after closing; the
mapped-loopback and wildcard IPv6 forms; this process with its real birth and argv is never
managed, nor with an extra argument, another birth, a dead PID or a zero birth) and
`arkdeck-provider-hdc` `status` (the empty object's twenty-three members and the unconfigured
shape; the launch route managed, unproven when unverified, when the third read changes, and
without a launch; the supervisor route managed, unproven for another generation, a drifted
record or an unhealthy one; the family table and the driver unsupported).

```
cargo test -p arkdeck-platform --lib macos_server      5 passed (3 new)
cargo test -p arkdeck-provider-hdc --lib status        4 passed
cargo test -p arkdeck-provider-hdc --test hdc_status   2 passed (22/22 cases byte for byte)
cargo clippy -p arkdeck-platform -p arkdeck-provider-hdc --all-targets -- -D warnings   clean
```

## Declared differences from Swift (T1/T2)

- A server another user owns: Swift's observer may observe it; the Rust lease refuses it
  (`hdc.identityUnknown`), as the Windows lease requires.
- The deadline abandons the kernel scan on its thread rather than cancelling it; the Rust
  observer never produces `Cancelled` (the code stays in the table for the seam).
- A receipt's endpoint is a `SocketAddrV4`, Swift's any string; the oracle's endpoints are all
  numeric and the comparison is by spelling.
- The supervisor route compares `SupervisedServer` (endpoint, health, generation, managed) where
  Swift compares the whole `HDCServerState`; the four fields are the ones the decision reads.

## What stays with other owners

- The `runtime.hdc.status` arm in `arkdeck-control`/`agentd` (lane A, M1 method layer): the
  daemon's launch record (`ManagedHdcServer` → `ManagedLaunch`), its version, its supervisor.
- The corpus and schema: `spec/control/methods/runtime.hdc.status.json` was derived from frames
  that carry only null `generation`, `processId`, `clientVersion` and a `{state}`-only signature,
  so a live-valued answer would fail the outbound validation until Swift frames of the live
  shapes are recorded and the schema regenerated — a contract input, to be sequenced with the
  method owner.
- `runtime.hdc.impact-preview` (read-only projection) is the next lane-B candidate;
  `runtime.hdc.restart` stays lane A's.

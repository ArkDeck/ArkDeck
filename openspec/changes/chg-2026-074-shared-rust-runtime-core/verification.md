# Verification — CHG-2026-074

> Change:CHG-2026-074-shared-rust-runtime-core@r5
> Status:planned; nothing in this file approves the change, and no host, fixture or simulation
> result counts as platform or hardware support (POL-VERIFY-001, POL-MODE-001).

## Environment

- Core baseline CORE-3.0.0 (ratified) with CORE-4.0.0 candidate; platform profiles `PLATFORM-MACOS`
  0.2.0 (`needsReverification`) and `PLATFORM-WINDOWS` 0.2.0 (this change).
- Reference hosts: macOS 26.6 / Xcode 26.6 / Apple silicon (8 cores, 16 GB) release builds; Windows
  11 x64 and Windows 11 ARM64 hosts (to be selected in SPK-3) release builds; Rust 1.98 pinned by
  `rust-toolchain.toml`; .NET 10 LTS; Windows App SDK 2.x stable.
- Device: DAYU200 `TGT-958780b2ffb7` (binding revision as recorded at run time), hdc `3.2.0f`,
  firmware `OpenHarmony-7.0.0.37`; HDC executable SHA-256 recorded per run.
- Required fixtures: `openspec/contracts/cli-canonical-json-vectors.json`, CBOR permit vectors,
  HDC Golden/Probe packs, the 219 CLI argv fixtures, the 10k-event journal generator, the 128 MiB /
  1 GiB artifact fixtures, the 20k-node Viewer fixture; clean-host images for the trust matrix.

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| XPA-AC-1 byte-for-byte contract parity | `arkdeck-conformance` replays every canonical JSON/CBOR/digest vector, HDC fixture, CLI argv fixture and durable document sample in Rust; Swift's current strict decoders read Rust-written documents and vice versa; the key set of every durable record equals the Swift `CodingKeys`, and a negative vector with one extra key is refused (field-set freeze, design §G.2, r3) | zero differences; Catalog digest equal; no schema version bump; no field added to any durable record | `evidence/runs/TASK-XPA-002/`, `TASK-XPA-005/`, `TASK-XPA-012..014/` |
| XPA-AC-2 admission and lowering semantics | contract tests against the Rust daemon: published admission order, `-t <connectKey>` on every device-scoped argv, plan-only zero dispatch, `job.plan` digest equality with Swift | identical pass/fail; zero dispatch in plan-only and in every refusal | `TASK-XPA-005/`, `TASK-XPA-014/` |
| XPA-AC-3 control-plane compatibility | negotiation and frame matrices (`AgentDaemonContractTests.swift:1840-1917` black-box, parameterised by `ARKDECK_DAEMON_UNDER_TEST`); old client/new daemon and new client/old daemon | structural refusals only; 1.x frames byte-frozen; 2.1.0 additive | `TASK-XPA-001/`, `TASK-XPA-003/` |
| XPA-AC-4 capability authority | capability minted only by the Rust authority from fresh facts and a fully materialised plan; zero consumption when provider/plan unavailable; lineage chain continues | no caller-provided capability accepted; ledger decodes in Swift | `TASK-XPA-008/`, `TASK-XPA-014/` |
| XPA-AC-5 performance budgets | design §I.2 metrics on the reference hosts, release builds, stated data scales; archived and compared to the committed baseline. Since r2 the constant-size and paged-projection IPC rows are budgeted separately, and two rows (paged projection, idle resident set) carry provisional ceilings pending design §L.1 items 15–16 | every finalised budget met on both platforms; regression thresholds respected for 30 days; a provisional row is a regression baseline, not a release gate; the lanes measure the Rust daemon before `TASK-XPA-017` starts | `TASK-XPA-023/`, `TASK-XPA-025/` nightly artefacts |
| XPA-AC-6 local IPC identity | foreign-euid UDS peer, wrongly signed XPC peer, cross-account named pipe client, remote pipe client; pipe name squatted before daemon start by a foreign account and by a same-account process with a different image; a server whose pipe owner SID is not the client's; a server whose image or signature is not the installed daemon's (where the connection's server PID is obtainable, SPK-3); an origin line on the public UDS socket; a client frame carrying a forged origin object (r3) | all refused before any handler runs; a squatted name fails daemon start closed and `doctor` names the holder; the client sends zero frames to a server that fails the owner check or, where available, the instance check; a same-account squat with the instance check unavailable is reported by the daemon side only, as the design §F.2 boundary states (r5); TCP/HTTP endpoints do not exist | `TASK-XPA-002/`, `TASK-XPA-003/`, `TASK-XPA-007/`, `TASK-XPA-022/` |
| XPA-AC-7 crash windows and recovery | kill matrix (Rust authority / Swift sidecar × before and after intent, before and after consume); façade kill matrix (before the frame is forwarded; after it is forwarded and before the reply; Swift daemon killed mid-request, r3); daemon restart; `outcomeUnknown` lanes carried across owner changes; cutover preflight against the blocking/parked split of design §G.4 (a parked `waitingForRecovery` Job must not block the switch, an in-flight or reconciling Job must, r5) | fail closed; zero replay; `recoverActiveJobs` dispatches nothing; the zero-dispatch proof (`details.phase`, `newDispatchCount`) appears only where the frame provably never reached the authority, a post-forward interruption is reported without that proof and resolved by read-back, and the façade never re-sends a forwarded frame | `TASK-XPA-003/`, `TASK-XPA-005/`, `TASK-XPA-013/`, `TASK-XPA-014/` |
| XPA-AC-8 UX parity | AX (macOS) and UIA (Windows) semantic snapshots for the same fixtures; bilingual catalog generation; keyboard, live region, high contrast, text scaling checks | same names, states, actions and next-action intents; no disabled placeholder; AC-I18N-001-01 passes on both | `TASK-XPA-007/`, `TASK-XPA-019/`, `TASK-XPA-020/` |
| XPA-AC-9 cutover and rollback | preflight refuses active jobs; state-directory snapshot; owner switch; rollback to the Swift daemon; Swift reads Rust-written bytes with its current strict decoders (no tolerant-reader change assumed, r3); the updated App against the rolled-back Swift daemon of the same release through the raw-xpc listener, by `AgentXPCTransportContractTests` and an App UI smoke (r5) | each drill completes with byte checks; no schema bump; no field added; the App/daemon pair of one release rolls back together | `TASK-XPA-012..014/`, `TASK-XPA-017/`, `TASK-XPA-022/` |
| XPA-AC-10 artifact and privacy invariants | immutability, digest re-verification, quota refuse-not-evict, retention, export refusing overwrite/symlink, sensitive opt-in, secret scan of journals/receipts | unchanged behaviour on both platforms | `TASK-XPA-006/`, `TASK-XPA-013/`, `TASK-XPA-011/` |
| Core conformance (121 scenarios) | current CORE-CONFORMANCE suite run on Windows and re-run on macOS with the Rust daemon | all applicable scenarios pass; `integration_conditional` exclusions unchanged | `openspec/platforms/windows/conformance-cases.yaml` (skeleton by `TASK-XPA-002`, rows by the Windows Golden Journey tasks XPA-006/008/009/010/011, final by `TASK-XPA-022`; r3 named the owners), `openspec/platforms/macos/**` by `TASK-XPA-017` |
| Golden Journeys | headless runbook on the current Catalog digest: Windows GJ-1..5 first pass; macOS GJ-1..5 re-pass after every owner change | `REAL_DEVICE_PASS` with redacted metadata | `docs/design/references/v1.6-goal/gj-headless-rerun-<date>-<platform>.json` |

## Negative and recovery tests

- Failure injection: malformed and oversized frames; unknown method/major; provider unavailable;
  tool identity drift; lock contention; torn journal tails (exhaustive); SQLite busy; quota exhausted.
- Cancellation/safe boundary: `job.cancel` during a critical step waits for the safe boundary;
  cancel latency budgets in design §I.2.
- Crash/restart/reconcile: the kill matrix above; `job.reconcile` read-back only; recovery epochs
  continue from durable state.
- Disk/server/device disconnect: volume removal, HDC server generation change, USB reconnect (HAR
  `physicalConnection`), rebind with zero/multiple candidates.
- Privacy and secret scan: no connect key, serial bytes, keystore password or SSH credential in any
  journal, receipt, artifact metadata or machine output.

## Deviations

Any deviation must be written here and confirmed in PR review; no implicit exemption. Known
candidates for maintainer ruling: Windows Trace Viewer scope (design decision 5), Windows daemon
lifecycle (decision 11), FFI kernel adoption (decision 12), the idle resident-set ceiling
(decision 15, added in r2), the paged-projection budget (decision 16, added in r2) and the same-user trust boundary (decision 17, added in r5).

## Result gate

- [ ] All applicable ACs passed with reviewable evidence on both platforms
- [ ] Simulation/fake/host results not counted as platform or hardware support
- [ ] macOS re-verified on the pure Rust daemon; Windows `verified` only for the exact OS/arch/build tuples evidenced
- [ ] Traceability updated (`openspec/verification/traceability.md`, platform lock file): macOS column by `TASK-XPA-017`, Windows column by `TASK-XPA-022`; no other task edits these files (r3)

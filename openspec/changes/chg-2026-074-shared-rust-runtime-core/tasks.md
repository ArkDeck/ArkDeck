# Tasks — CHG-2026-074

> Approval is the maintainer's merge of the proposal PR. Before that merge no `TASK-XPA-*` may be
> declared by an implementation PR (`scripts/check_pr_paths.py` refuses head-only tasks). After the
> merge, `ready` tasks may start; `blocked` tasks wait for the listed dependency or spike and flip
> to `ready` inside the PR that instantiates their readiness pins. Task semantics, DAG, sizes and
> gates are explained in `docs/design/cross-platform/rust-core-cross-platform-architecture.md` §J.

Revision 6 consumes [CHG-2026-075](../chg-2026-075-single-v1-contracts/proposal.md).
Its prerequisite implementation is TASK-SVC-001..004. This PR proposes the r6 dependency and
scope correction for maintainer review; the existing proposal status does not approve r6.
Every later reference to the Swift oracle, unchanged schema, rollback or a frozen field set
means the latest Swift single-v1 baseline after those tasks. Historical pre-SVC formats,
negotiation and authority branches must not be revived by a Rust port.

Revision 8 (2026-09-09) sequences the macOS side before the Windows side. The maintainer ruled
that the macOS strangler chain — TASK-XPA-003 → 012 → 013 → 014 → 015 → 016, then 018 ∥ 019 and
025, then 017 — is completed and GJ-1..5 re-passed headless on the pure Rust daemon (design §J.5
gate G5) before any Windows Golden Journey task starts, so that the Windows side is built once,
on the final Rust runtime, rather than on a read-only snapshot that the macOS differential then
reshapes. TASK-XPA-003 depends on TASK-XPA-002's delivered macOS read-only foundation (#1768,
`evidence/xpa-002-readonly-foundation.md`), not on its Windows acceptance, and is `ready`; no
macOS task depends on a Windows task any more (TASK-XPA-014 no longer waits for TASK-XPA-005;
TASK-XPA-024's macOS half waits for TASK-XPA-019); TASK-XPA-004 and the Windows acceptance of
TASK-XPA-002 wait for TASK-XPA-017. SPK-3 is a platform fact and may run whenever a Windows host
exists, but nothing Windows-side is built on it before G5. This PR proposes r8 for maintainer
review; its merge is the attestation.

Revision 9 (2026-09-10) reconciles the Allowed paths of the macOS chain with the modules its
deliverables actually live in. Between 2026-09-09 and 2026-09-10 TASK-XPA-003 needed one
implementation PR (#1833) and five scope PRs (#1828 packaging scripts, #1829 HDC host lifecycle
and rollback smoke, #1830 read projections, #1831 refusal proofs, #1834 pbxproj registration),
because its paths were written file by file at proposal time. r9 rewrites TASK-XPA-012..018 at
module granularity, verified against the current tree: the host-only stores' Swift consumers,
the tool/bundle registry and the trace cache reader (012); the shared models, fixtures, cutover
switch, paired packaging and rollback-drill UI smoke every cutover repeats (012–016); the
durable-store hand-off, the sidecar process face and the runtime models (014); the analyzer
contracts and composition root (015); the process executor, the HDC provider and supervisor
observation modules (016); and the CI lane files that the retirements must edit (017, 018,
precedent TASK-XPA-002 r3/r5). `Forbidden paths` keep carrying the narrowing for reviewers, and a
scope supplement PR is from now on expected only for a security-kernel exception, not for an
adjacent file. TASK-XPA-003's live supplements stand as they are. r9 changes no dependency,
status, acceptance criterion, hardware criterion or design text.

Revision 10 (2026-09-10, implementation review) applies the user's unreleased-product
premise: ordinary existing state is rebuildable test data. Development proceeds by actual
interfaces and runnable milestones, not the old numbered serial DAG. There is no seven-day
nightly wait and no same-release Swift rollback or universal old-data interread goal.
Existing differential tests, fixes and immutable receipts remain regression evidence.
A: Rust host/artifact/Job execution plus HDC Observe/Diagnostics and CLI persistence;
B: remaining macOS features, ClientKit, performance and soak along their actual dependencies;
C: remove Swift targets and the facade only after consumers detach, then verify final
GJ-1..5, App UI, installation/signing/IPC identity and recovery. Windows follows macOS.
Compatibility note (PRODUCT-LOOP §2/§16): old readiness and sequencing labels do not block
isolated implementation. Normal path checks and maintainer review still apply. New roots
never erase Raw Artifact, real intent/outcome, capability/recovery or evidence, nor bypass
pending effects on the same device. Device activation still requires one published Runtime,
fresh facts and complete mechanical safety proof. No approval or hardware pass is implied.

Conventions shared by every task:

- One task = one vertical PR that carries production code, tests, applicable real-device
  verification, minimal documentation and a completion conclusion (`PRODUCT-LOOP.md:187-224`).
- Every implementation task advances one Golden Journey hop on Windows or re-passes the affected
  Golden Journeys headless on macOS on the current Catalog digest (design §B.2 assumption A4).
- `Allowed paths` are the proposed authority for the implementation PR; `scripts/check_pr_paths.py`
  decides mechanically once the task exists on `main`. `Forbidden paths` are for humans.
- Readiness pins are instantiated when a task moves from `blocked` to `ready`; the blocks below are
  placeholders (`yaml pin-example`).
- Every task's Allowed paths include `openspec/changes/chg-2026-074-shared-rust-runtime-core/**` (r3). The
  implementing PR flips its own `Status`, instantiates its readiness pins and writes
  `evidence/runs/<task-id>/`, and `scripts/check_pr_paths.py` reads Allowed paths from the base
  tree, so a task that omits the directory cannot deliver the record this file demands. Verified on
  2026-09-05 with synthetic commits on `main`: an evidence path declared under `TASK-XPA-003` or
  `TASK-XPA-012` was refused, the same path under `TASK-XPA-002` was accepted.
- Sizes: S ≤ one engineer-week, M two to three weeks, L four to eight weeks (assumption: one senior
  engineer per lane, AI-assisted, hardware windows excluded).
- No task in this change carries a `D0` decision grade: none is suitable for the unattended
  repository loop (`scripts/host_loop`, AGENTS.md control-plane section), because each needs a
  Windows host, a reference measurement host, real hardware or UI review. A maintainer may regrade
  a task later.

## Spikes (not tasks, no PR; results are recorded as evidence under the approving task)

| Spike | Purpose | Pass | Fail | Unlocks |
| --- | --- | --- | --- | --- |
| SPK-1 | macOS performance baseline for the 13 metrics in design §I.2 | ≥3 runs with stable p50/p95/p99 (< 30% p95 spread), `perf-baseline-<date>.json` archived | spread > 30% | most budgets in §I.2 (the paged-projection and idle-RSS rows and the `artifact.open` / FFI decisions stay open, see §I.2 notes 1–2 and §L.1 items 15–16) |
| SPK-2 | A Rust process vends the launchd Mach service `com.arkdeck.agentd` through the libxpc C API; the sandboxed App connects with the existing entitlements; peer code-signing requirement enforced | connect without entitlement changes; wrongly signed peer refused; 1,000 round trips p95 ≤ 8 ms | new entitlement needed or NSXPC-only semantics cannot be reproduced | TASK-XPA-003（r7: passed on 2026-09-05 on the macOS reference host, `evidence/runs/TASK-XPA-003/spk-2-run.md`; XPA-003 now waits on TASK-XPA-002 and maintainer review only; r8: `ready`, its dependency being TASK-XPA-002's delivered macOS read-only foundation）|
| SPK-3 | Windows W0 (`openspec/platforms/windows/profile.md:71-81`) plus a Rust named-pipe daemon and `hdc.exe list targets -v` against a DAYU200 | cross-account connect refused (Win32 error 5); packaged App and unpackaged CLI both reach the pipe; MotW/SmartScreen behaviour recorded; Golden fixtures parse identically | driver needs silent elevation or pipe unreachable from a packaged App | TASK-XPA-002, Windows support tuple, packaging |
| SPK-4 | WinUI 3 gate (design §H.4 a–e) | all pass | any fails and cannot be fixed in two weeks | WinUI 3 vs WPF |
| SPK-5 | NTFS durability primitives (`FlushFileBuffers`, `MoveFileExW` write-through, `LockFileEx`, torn-tail exhaustive test) | torn-tail matrix passes; append p95 recorded | atomic replace cannot be proven | TASK-XPA-005 write path design |

## TASK-XPA-001 — Publish per-method typed schemas from the single v1 contract for Rust consumers

- Status:done（2026-09-09: the recording seam, the derivation and the per-method schemas of the single v1 control table are delivered and every method's result shape is published by success-path contract tests; the re-derivations after TASK-SVC-002/003/004 and the AFA-001 `flash.reconcile-alias` publication are recorded and the baseline is pinned at `main` `8c6a376c` / identity `8a662759…`; the headless re-pass on the current digest `508783ac…` is complete — GJ-1 (incl. §2.1 HAR crash-resume), GJ-2, GJ-3 and GJ-5 through the TASK-SVC-005 windows of 2026-09-08/09, and GJ-4 `REAL_DEVICE_PASS` on the published `6e8c3ed5` build on 2026-09-09 after DEC-016 admitted the complete-overwrite recovery under a named campaign; `evidence/runs/TASK-XPA-001/run.md`）
- Platform:macos（contract is platform-neutral）
- Requirements:CLI-REQ-013, CLI-REQ-014, CLI-REQ-025 as aligned by CHG-2026-075; no Core REQ edited by this task
- Acceptance:XPA-AC-1, XPA-AC-3; the post-SVC single-v1 positive and negative frame corpus
- Depends on:TASK-SVC-001, TASK-SVC-002, TASK-SVC-003, TASK-SVC-004
- Readiness input pins（post-SVC-004: all four SVC merges have landed and the schemas were re-derived on the result）:

  ```yaml pins
  - path: main
    commit: 8c6a376cff3b6212cabf61fa6e203e123ade8654
  - path: Packages/ArkDeckKit/Contracts/control-protocol.json
    blob: 9c5bec149513faecb967b72ef6dd9b990193448f
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocolGenerated.swift
    blob: 35c66af882807939bf13da4d1deacece7e466bd1
  ```

  The commit is `main` on 2026-09-09 (#1808). The earlier pins were `main` after TASK-SVC-001 (#1733, `600e4b72…`) and after TASK-SVC-004 (#1742, `eac476cd…`, control blobs `f47372fe…`/`6d3c1fb6…`, identity `1054d17b…`, 96 methods). Since then TASK-AFA-001 published `flash.reconcile-alias` (#1794) and re-derived all 97 schemas under the new identity `8a662759721a2081e974306399997801246de4022047365c050107de5dce2912` (#1795); the request/result/error shapes of the 96 earlier methods did not move (AFA-001's own diff record). The old r1–r5 protocol/journal blobs are historical inputs, not this task's baseline.
- Applicable failure patterns:AF-004, AF-006, AF-014
- Production reachability:`arkdeck` CLI → UDS → `RuntimeControlPlaneHandler` → the single v1 method table → existing handlers; no new effect or dispatch point
- Trusted fact sources:the method set and current document shapes come from the protected-main Swift implementation after SVC-001..004 and its canonical generators; per-method schemas are checked against actual request/result/error frames; callers cannot widen the method set
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `Packages/ArkDeckKit/Contracts/**`
  - `Packages/ArkDeckKit/Scripts/generate-control-contract.py`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/**`（generated single-v1 schema consumption only; no version selection or fallback）
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `openspec/contracts/runtime-control-plane.schema.json`
  - `openspec/contracts/journal-event.schema.json`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`Catalog/**`、`openspec/platforms/**`
  - changing the post-SVC frame/document shape or any method's effect; reintroducing multi-version negotiation, downgrade, legacy readers or old authority
- Risk:low（publishes typed schemas for the existing single-v1 behavior）
- Hardware required:yes（DAYU200 for the headless rerun of GJ-1..5）
- Decision-Grade:D1

### Deliverables

- `spec/control/methods/<method>.json` with request/result/error-details for every method in the final single-v1 table; the control-plane schema references them.
- Generate Swift/Rust/client contract inputs from one canonical method/schema source, preserving the post-SVC wire and durable bytes and the current method effects.
- Publish the single current journal contract for Rust consumption; do not restore the historical generation union or change the cleanup delivered by CHG-2026-075.
- Record the post-SVC baseline commit, contract digests and corpus used by every later XPA differential test.

### Verification

- XPA-AC-3 → every current recorded frame validates; malformed/unsupported-version/unknown-method frames fail structurally with zero dispatch; no negotiation or downgrade path exists.
- XPA-AC-1 → generated schema and Swift runtime agree on current request/result/error and durable document shapes; historical inputs stay rejected or isolated according to CHG-2026-075.
- Real device → `docs/design/cli-golden-journey-headless-runbook.md` using the normal single-v1 CLI: GJ-1..5 `REAL_DEVICE_PASS` on the current digest; this re-pass does not replace SVC-005.

### Notes / handoff

- Stop condition: any mismatch against the pinned post-SVC contract, loss of a required method, changed effect, or return of compatibility logic removed by CHG-2026-075.
- Rollback: revert this schema-publication change as a unit; migration rollback pairs clients with the post-SVC Swift daemon of the same release, never selects an older protocol.
- Size: M.

## TASK-XPA-002 — Rust contract kernel and the first Windows GJ-1 hops (doctor, device candidates)

- Status:in-progress（the macOS read-only foundation against the pinned Swift development baseline is delivered — #1768, baseline re-pinned at `main` `a61848f9` — and is TASK-XPA-003's input (r8); the Windows acceptance — SPK-3, Windows 11 x64 + DAYU200 with a trusted installed daemon and a reviewed Windows HDC tuple — is the first step of the Windows phase after TASK-XPA-017 (r8), and maintainer review remains outstanding, see `evidence/xpa-002-readonly-foundation.md`）
- Platform:windows（the same crates run read-only on macOS as a shadow tool）
- Requirements:`toolchain-hdc-server` REQ-HDC-006/REQ-HDC-009 (unchanged), CLI-REQ-001/005/006/013/014
- Acceptance:XPA-AC-1, XPA-AC-3, XPA-AC-6; Windows GJ-1 `NOT_STARTED → IMPLEMENTING`
- Depends on:TASK-XPA-001（implementation input: its published single-v1 method schemas and recorded Swift corpus, pinned in `spec/baselines/swift-single-v1.json`; neither TASK-SVC-005 nor TASK-XPA-001's remaining real-device re-pass blocks this bounded implementation）
- Acceptance prerequisites:the unchanged XPA-AC-1/3/6 and verification rows below, including SPK-3 and Windows 11 x64 + DAYU200 with a trusted installed daemon and a reviewed Windows HDC tuple/output family; the development baseline and host tests do not satisfy them or establish approval, verification or completion. This dependency clarification changes no Allowed paths, operation, Core requirement or hardware criterion. r8: this acceptance is sequenced after TASK-XPA-017 and runs against the final Rust runtime; the foundation keeps evolving with the macOS chain meanwhile.
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Catalog/generated/effect-authorization-matrix.md
    blob: <40-hex git OID>
  - artifact: Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/registry.json
    sha256: <64-hex sha256>
  ```

- Applicable failure patterns:AF-002, AF-003, AF-004, AF-007, AF-011
- Production reachability:`arkdeck.exe doctor` / `operation list` / `device candidates` → user-private named pipe → `arkdeck-control` → `doctor` / `operation.list` / `device.observations` → `hdc.exe list targets -v` as an argument array with handle-bound hash verification → parser → projection; read-only, no durable write, no capability
- Trusted fact sources:catalog digest from `Catalog/operations/*.json` via the generator; canonical JSON/CBOR/digest vectors from `openspec/contracts/cli-canonical-json-vectors.json` and the permit vectors; HDC output classification from the hash-pinned Golden/Probe fixtures; pipe peer identity from the logon SID DACL plus server-side SID/elevation check; pipe **server** identity from the pipe object's owner SID and, where the connection's server PID is obtainable, from the daemon instance's image and signature/package identity (design §F.2, r3/r5)
- Allowed paths:
  - `rust/**`
  - `spec/**`
  - `.github/workflows/rust-ci.yml`
  - `.github/workflows/swift-ci.yml`（wire the planner's `rust` output to a hosted job; no other edit）
  - `scripts/ci/plan.py`
  - `scripts/ci/test_plan.py`
  - `scripts/test_agent_pr_workflow.py`（r5: the `swift` aggregate's `needs` list is pinned there verbatim）
  - `scripts/catalog_gen/**`
  - `openspec/architecture/core-portability.md`
  - `openspec/platforms/windows/**`（profile 0.2.0 and the skeleton of `conformance-cases.yaml`）
  - `openspec/platforms/macos/profile.md`
  - `openspec/platforms/linux/profile.md`
  - `openspec/platforms/PLATFORM-PROFILES.lock.yaml`
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**` production sources（this task changes no Swift semantics）
  - `openspec/specs/**`、`openspec/constitution.md`、`Catalog/operations/**`
  - any Core strategy wording that overrides or relaxes a Core Requirement (POL-PLATFORM-001)
- Risk:medium（new toolchain and CI lane; read-only surface）
- Hardware required:yes（Windows 11 x64 host + DAYU200）
- Decision-Grade:D1

### Deliverables

- Rust workspace (`arkdeck-contract`, `arkdeck-platform`, `arkdeck-control`, `arkdeck-provider-hdc` parsers, `arkdeck-client`, `arkdeck-cli`, `arkdeck-agentd`) with `cargo deny`/`cargo vet` in CI.
- Catalog generator emits Rust alongside Swift; digest equality asserted.
- Named pipe transport (`FILE_FLAG_FIRST_PIPE_INSTANCE`, `PIPE_REJECT_REMOTE_CLIENTS`, logon-SID DACL, client SQOS identification, server SID/elevation check) and UDS transport (0700/0600, peer euid check).
- Client-side server authentication on the pipe, in two layers (r3/r5). **Layer 1, account:** after `CreateFileW` with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION` the client reads the pipe object's owner SID (`GetSecurityInfo`, `OWNER_SECURITY_INFORMATION`) and sends no frame unless it equals its own token owner SID — the client-side semantics of .NET `PipeOptions.CurrentUserOnly` (`NamedPipeClientStream.ValidateRemotePipeUser`), which also covers elevation because an elevated token's owner is the Administrators group. This layer cannot tell a same-user impostor apart: its pipe carries the same owner SID. **Layer 2, instance:** the client resolves the server PID of *this connection* (`GetNamedPipeServerProcessId`; its reference page says the handle "must be created by the `CreateNamedPipe` function", which contradicts the function's purpose, so SPK-3 must confirm it on a `CreateFileW` handle), opens it with `PROCESS_QUERY_LIMITED_INFORMATION`, requires the image path to equal the installed daemon path and its Authenticode publisher or MSIX package family to equal the product's, and keeps the process handle open for the life of the connection so the PID cannot be recycled underneath it. **Boundary:** a same-user, same-integrity process that *is* the product's own signed daemon binary is trusted by construction; same-user arbitrary code is outside the trust boundary on both platforms — ADR-0005 decision 1 says so for the UDS, and a same-uid process could equally replace the socket file in the 0700 directory on macOS. If SPK-3 shows that the server PID is not obtainable from a client handle, layer 2 is unavailable and a same-account squat is detected on the daemon side only: `FILE_FLAG_FIRST_PIPE_INSTANCE` makes the second instance fail with `ERROR_ACCESS_DENIED` and `doctor` reports the held name; the design then claims nothing for the client (r5 withdraws r3's "same-account squat → zero frames").
- CI planner lane (r3): `scripts/ci/plan.py` gains a `rust` lane selected by `rust/**`, `spec/**` and `.github/workflows/rust-ci.yml` and included in the planner/workflow self-validation branch; `--run-local` runs `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace` and `cargo deny check`; the hosted job keys off the same planner output. Today `classify_paths` selects no lane for a diff confined to `rust/**` (checked mechanically on 2026-09-05), so without this the local gate passes without compiling the new code. The hosted job is a `needs` entry of the `swift` aggregate with the same selected-or-skipped test the other lanes use, so its failure is carried by the check branch protection already requires; `scripts/test_agent_pr_workflow.py:412-421` pins that aggregate's `needs` list and result tests verbatim and is updated in the same PR (r5).
- Windows `doctor`, `operation list`, `device candidates` with machine output byte-equal to the macOS fixtures.

### Verification

- XPA-AC-1 → vectors and fixtures replayed in Rust → all equal.
- XPA-AC-3 → single-v1 validation and frame-limit matrix against the Rust daemon → structural refusals, zero dispatch.
- XPA-AC-6 → cross-account pipe connect → refused.
- XPA-AC-6 → pipe name squatted before daemon start: by a foreign account → the client refuses on the owner SID and sends zero frames; by a same-account process with a different image, with layer 2 available → the client refuses on instance identity and sends zero frames; by a same-account process with layer 2 unavailable → daemon start refused with `ERROR_ACCESS_DENIED` and `doctor` reports the held name, and no client-side claim is made (r5).
- SPK-3 → `GetNamedPipeServerProcessId` on a `CreateFileW` client handle returns the connection's server PID: recorded as pass or fail; a fail flips the boundary statement above and design §F.2 (r5).
- Planner → `scripts/ci/test_plan.py` asserts that `rust/**` selects the rust lane, that the self-validation branch includes it, and that a `rust/**`-only diff selecting no lane fails (r3); `scripts/test_agent_pr_workflow.py` passes with the rust lane in the aggregate (r5).
- Real device → `device candidates` lists the DAYU200 on a Windows 11 x64 host; recorded as Windows GJ-1 `IMPLEMENTING` in `docs/design/references/v1.6-goal/`.

### Notes / handoff

- Stop condition: any raw path/argv enters a contract; any durable write; a `rust/**`-only diff for which the planner selects no lane.
- Size: L.

## TASK-XPA-003 — Rust control-plane façade on macOS with peer hardening

- Status:done（2026-09-10: paired macOS facade implementation merged in #1833; the #1834 scope permits the final UI-test registration. XPA-AC-3/5/6/7 pass; the physical GJ-1 HAR and both facade/same-release Swift Overview/History UI runs pass, completing the task's XPA-AC-9 drill and GJ-1..5 on Catalog digest `508783ac…`. Final evidence and test registration are submitted together for maintainer review; this status is not an approval or verified designation. See `evidence/runs/TASK-XPA-003/run.md`）
- Platform:macos
- Requirements:ADR-0005 decisions 1–4 (transport, single-v1 frames, transport-free handler, single instance); no Core REQ edited
- Acceptance:XPA-AC-3, XPA-AC-5, XPA-AC-6, XPA-AC-7
- Depends on:TASK-XPA-002's macOS read-only foundation（delivered 2026-09-08 by #1768; r8: not its Windows acceptance, which follows TASK-XPA-017）, SPK-2（passed）
- Readiness input pins（r8: instantiated at `main` on 2026-09-09）:

  ```yaml pins
  - path: main
    commit: ad816795cddf8f8ef480d4819a48cedc697999b0
  - path: Packages/ArkDeckKit/LaunchAgents/com.arkdeck.agentd.plist
    blob: aa941bbee4d65c746ce74bf50650f6930ce22159
  - path: spec/baselines/swift-single-v1.json
    blob: a58db1350b712061f7ba092b11bdbe33cf239eff
  ```

  The LaunchAgent template is the file the façade takes over; the baseline is the delivered
  read-only foundation's contract input (97 methods, 435 recorded shapes, identity `8a662759…`).

- Applicable failure patterns:AF-002, AF-007, AF-014, AF-018
- Production reachability:client → Rust façade (UDS + Mach service) → forwarded frame to the Swift daemon on a private socket → existing admission; the façade validates the single-v1 frame, admits by peer identity and frame shape, and never interprets, caches or rewrites a frame. **Origin context (r3):** the Swift daemon derives `RuntimeControlRequestContext` for every frame from kernel facts of the accepted socket (`AgentDaemon.swift:5095,5149-5194`: peer euid, `LOCAL_PEERPID`, the peer's process group equals its controlling terminal's foreground group, stdin/stderr are that terminal, start time re-checked) and issues the interactive impact-approval challenge only for `unixSocket && hasForegroundConsole` (`:3978`), otherwise returning the HAR unchanged (`:4007-4010`). Behind a transparent forwarder that peer would be the façade — a background daemon with no terminal — and console confirmation would never work again. Therefore the façade derives the same facts on its own accepted descriptor at the moment it forwards each frame and writes to the private socket one origin line `{arkdeckOrigin:1, transport:"unixSocket"|"appXPC", foregroundConsole, peerEUID, peerPID, frameSHA256}` followed by the raw frame bytes; the Swift private listener accepts origin lines only on the private socket, checks `frameSHA256` against the following line, and builds the context from it. No request field participates; an `arkdeckOrigin` object inside a client frame is an ordinary unknown field.
- Trusted fact sources:peer euid from `getpeereid`; App identity from the XPC peer code-signing requirement; the private socket is reachable only by the façade (0700 directory, pairing secret, `getpeereid` equal to the daemon euid); the origin line, which only the façade can write on that socket
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `Packages/ArkDeckKit/LaunchAgents/**`
  - `Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh`（façade/Swift same-release helper packaging only; preserve provisioning and signing checks）
  - `Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh`（same paired packaging for release; preserve provisioning, signing, notarization and assessment）
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`（private-socket listener and origin-line → context construction only; the handler and admission code are untouched, r3）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/HeadlessHDCServerHost.swift`（managed HDC startup/shutdown lifecycle synchronization and diagnostics needed for paired-daemon restart/rollback only; preserve identity-bound spawn, exact endpoint ownership, fail-closed readiness and all Supervisor admission rules）
  - `ArkDeckAppUITests/AppShell/FacadeRollbackUITests.swift`（read-only Overview/History smoke against the signed façade and same-release Swift rollback; no device mutation or fixture-as-hardware evidence）
  - `ArkDeck.xcodeproj/project.pbxproj`（register only the already-declared `FacadeRollbackUITests.swift` in the existing ArkDeckHDCUITests target; no product targets, build settings, entitlements or unrelated project changes）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`（read projections only: bounded in-memory reuse of validated decoded persisted records after reading and comparing exact current bytes; preserve all validation, admission, capability and persistence semantics）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentExecutionCoordinator.swift`（preserve the existing typed pre-admission refusal reason and owner-issued zero-dispatch proof after confirming no accepted Job; no admission, dispatch, retry, capability or persistence-format changes）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/XPCConnectionBox.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/AgentXPCContract.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `ArkDeckApp/**`（transport only; no visible copy or navigation change）
  - `docs/design/**`
- Forbidden paths:
  - Any admission/capability/storage source, including `RuntimeJobEngine.swift` and `AgentExecutionCoordinator.swift` outside their explicit read-projection/refusal-projection exceptions above; no changes to mutation callers or the shared persisted-record decoder
  - `ArkDeckApp/ArkDeckApp.entitlements`（the entitlement set must not widen）
- Risk:medium（production path change with a one-flag rollback）
- Hardware required:yes（DAYU200 for the GJ-1..5 re-pass）
- Decision-Grade:D1

### Deliverables

UI-test registration scope supplement (2026-09-10, proposed): PR #1833 added the
allowed `FacadeRollbackUITests.swift`, but the Xcode project uses explicit source
membership. The file is absent from that membership, so selecting the suite
returned `TEST EXECUTE SUCCEEDED` with zero tests and cannot satisfy XPA-AC-9.
Permit only its file reference, group membership and Sources build-phase entry
in the existing UI-test target. This scope change does not register the file
itself; the implementation and an actual nonzero test result follow after review.

Refusal-proof scope supplement (2026-09-09, proposed): the facade GJ-5 run
completed reproduction, analysis, isolated repair, build, signing and healthy
verification. Its stale-revision negative case was refused with an unchanged
62-Job ledger, but AgentExecutionCoordinator discarded the typed admission
reason after confirming that no Job had been accepted. The CLI therefore
reported only generic admissionDenied, without the required owner-issued
zero-dispatch proof. Permit forwarding that existing refusal through the
existing AgentExecutionControlFailure path after the same durable terminal
transition. Preserve accepted-Job reconciliation, terminal no-replay behavior,
all admission decisions, dispatch ordering and persistence formats. Tests must
cover the refusal proof, durable terminal readback and absence of dispatch;
ambiguous/internal failures must not gain proof. No acceptance criterion, Catalog,
readiness pin or task status changes. This exception requires maintainer merge.

Read-performance scope supplement (2026-09-09, proposed): release measurements
found standalone Swift job.status/job.list p95 already approximately 256%/196%
above SPK-1; sampling identifies repeated persisted-record decoding in read
projections. Permit a bounded process-local decoded-record cache only for those
reads: fetch current persisted bytes on every read, reuse only on exact byte
equality, and retain all row/record validation and fresh projection checks. Cache
misses use the unchanged decoder; mutation/admission callers remain unchanged.
Contract tests must cover changed/malformed bytes, eviction and fresh reads.
This proposal changes no code, task status, readiness pin, SPK-1 baseline or
AC-5 +20% threshold. The exception takes effect only after maintainer merge.

Acceptance scope supplement (2026-09-09, proposed): the complete implementation
path probe against protected main `62d5cffd` found two missing paths. Signed
pair/rollback testing currently encounters a managed-HDC startup failure
(`managed HDC launch identity was not retained`), including after restoring the
original daemon; the root cause remains to be diagnosed, so any correction in
that host file is restricted to lifecycle synchronization/diagnostics and must
retain every existing identity and admission check. The new UI test supplies
AC-9's real-service Overview/History smoke. This proposal changes no production
code, entitlement, task status, readiness pin or acceptance criterion; it takes
effect only after maintainer merge.

Packaging scope supplement (2026-09-09, proposed for maintainer review): the two
existing helper build entry points above currently package only the Swift daemon.
They need to include the façade/Swift pair before bundle signing so the existing
local and release commands can produce the required installation artifacts. This
supplement changes no task status, readiness pin, acceptance criterion, entitlement
or Runtime authority. The path extension takes effect only after maintainer merge;
this scope PR does not modify either script. See `evidence/runs/TASK-XPA-003/run.md`.

- Façade daemon owning the public socket and the Mach service; `runtime service install/update` accepts the façade/Swift binary pair; black-box contract tests parameterised by `ARKDECK_DAEMON_UNDER_TEST`.
- App transport pairing (r5): the Swift daemon's Mach service listener moves from `NSXPCListener` (`AgentXPCListener.swift:26`) to the raw libxpc frame listener the façade implements, and the App moves from `NSXPCConnection` (`XPCConnectionBox.swift`) to `xpc_connection`, **in the same PR**. The daemon is installed from the App bundle's nested helper (`ArkDeckRuntimeCommands.swift:1258` → `~/Library/Application Support/ArkDeck/Helpers/ArkDeckAgent.app`, receipt with `daemonSHA256`), so the rollback pair is always the updated App and the Swift daemon of the same release; a Swift daemon that still spoke NSXPC would leave that App unable to connect after `runtime service update --daemon <swift>`. A LaunchAgent pointing at a daemon of another release is detected by the receipt/executable identity check and reported as daemon-unavailable with the `runtime service update` remedy, never a silent hang.

### Verification

- XPA-AC-3 → `AgentDaemonContractTests`/`AgentXPCTransportContractTests` black-box subset against the façade → green.
- XPA-AC-5 → IPC p95 within +20% of the SPK-1 baseline, compared per row: constant-size replies and paged projections are separate rows since design §I.2 note 1.
- XPA-AC-6 → foreign-euid UDS peer refused; wrongly signed XPC peer refused; an origin line written to the public socket is `malformedFrame`; a foreign process on the private socket path (0700 directory, no pairing secret) refused.
- Origin context (r3) → through the façade, a CLI on a foreground terminal gets the console challenge from `human-action.resume` (`interactionOrigin == interactiveConsole`) and a redirected-stdin or background CLI gets the HAR unchanged, with the same reason strings as today; a client frame carrying a forged `arkdeckOrigin` object is refused as an unknown field with zero dispatch; XPC clients keep `appXPC` (no console semantics exist for them today, `AgentDaemon.swift:22`).
- XPA-AC-7, before forward (r3) → façade killed after accept or single-v1 validation but before the frame is written to the private socket → structured transport error; provably zero dispatch: the Swift daemon received no bytes and the journal is unchanged.
- XPA-AC-7, after forward (r3) → façade killed after the frame was written but before the reply is relayed, or the Swift daemon killed mid-request → structured interruption error **without** the `details.phase` / `newDispatchCount` proof (that proof is issued only by named owner refusals, `AgentDaemon.swift:4116-4125`, and the façade must never synthesise it); the durable state is whatever the Swift daemon wrote (journal intact and readable, possibly with intent and outcome); the façade never re-sends a forwarded frame; the client resolves the outcome by `job.status`/`job.list` read-back (a `job.submit` idempotency key makes re-submission safe). Test: no duplicate Job, no replay, journal consistent.
- XPA-AC-9 (r5) → rollback drill = `runtime service update --daemon <swift>` followed by the **updated App** against the rolled-back Swift daemon of the same release: `AgentXPCTransportContractTests` black-box subset against the raw-xpc Swift listener, a live App smoke (Overview/History) under UI test, and the headless CLI drill; a daemon of another release → the App reports the mismatch and the remedy, no hang.
- Real device → GJ-1..5 headless `REAL_DEVICE_PASS`; rollback drill (`runtime service update --daemon <swift>`) recorded.

### Notes / handoff

- Stop condition: any authority or durable write in the façade; any entitlement widening; any reply that claims zero dispatch for a frame the façade had already forwarded; an App build whose same-release Swift daemon cannot serve it.
- Rejected alternative (r3): handing the accepted descriptor to the Swift daemon with `SCM_RIGHTS` keeps the kernel facts first-hand but hides every later frame from the façade, which TASK-XPA-012 needs in order to serve host-only methods locally.
- Size: M.

## TASK-XPA-004 — Windows target adopt with durable binding and human trust stop

- Status:blocked（r8: waits for the macOS side to complete, TASK-XPA-017）
- Platform:windows
- Requirements:`device-targeting-auth` (identity before convenience, POL-TARGET-001); ADR-0006 decisions 1–5
- Acceptance:XPA-AC-1, XPA-AC-2; Windows GJ-1 hops 4–5
- Depends on:TASK-XPA-002（its Windows acceptance）, TASK-XPA-017（r8: GJ-1..5 on the pure Rust daemon — design §J.5 gate G5 — before any Windows Golden Journey task starts）
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/DeviceBootstrap.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-003, AF-004
- Production reachability:CLI → pipe → `target.adopt` → `arkdeck-runtime::bootstrap` (closed four-action observation vocabulary) → `targets/` under `.targets.lock`
- Trusted fact sources:stable identity = SHA-256 of the normalised serial exactly as Swift computes it; no serial fails closed; candidate lists come only from the pinned parser
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`、`openspec/specs/**`、`Catalog/**`
- Risk:low（structurally E0; no mutation constructor exists）
- Hardware required:yes（Windows host + DAYU200）
- Decision-Grade:D1

### Deliverables

- Bootstrap state machine, targets store (same JSON shape), HAR `physicalConnection` / `needsSelection`, `waitingForHuman` for unauthorised candidates.

### Verification

- XPA-AC-1 → same `list targets -v` bytes → same target ID on both platforms.
- XPA-AC-2 → repeated adopt is idempotent; >1 candidate never auto-selected; lock contention and torn writes fail closed.
- Real device → `target adopt` on Windows produces a durable binding and the trust stop when the device is unauthorised.

### Notes / handoff

- Size: M.

## TASK-XPA-005 — Windows observe.device@1 end to end with restart readback

- Status:blocked（also awaits SPK-5）
- Platform:windows
- Requirements:REQ-JOB-001, REQ-WF-004, POL-WORKFLOW-001, POL-SAFETY-001; `PRODUCT-LOOP.md:556-576` admission order; `:593-631` connect-key binding
- Acceptance:XPA-AC-1, XPA-AC-2, XPA-AC-4, XPA-AC-7; Windows GJ-1 hops 6, 9, 10
- Depends on:TASK-XPA-004
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/DurableFiles.swift
    blob: <40-hex git OID>
  - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeJobRepository.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-003, AF-004, AF-010, AF-011
- Production reachability:CLI → `job.submit` (default read-only policy) → post-SVC SQLite v1 admission + `job-record.json` + journal `jobCreated` → `stepIntent` → `hdc.exe -t <connectKey> …` through the single `deviceArguments` injection point → semantic verify → `stepOutcome` → artifact index → `job.events/status/result`
- Trusted fact sources:target facts from the durable binding; tool identity from handle-bound hash; the plan digest from canonical JSON of the materialised plan; callers provide only the operation reference, typed inputs and target reference
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`、`Catalog/**`、`openspec/specs/**`
- Risk:medium（first durable writer on Windows）
- Hardware required:yes（Windows host + DAYU200）
- Decision-Grade:D1

### Deliverables

- `arkdeck-durable` (journal fsync discipline, tail cursor, torn-tail repair, atomic replace, SQLite `runtime_job` in the pinned post-SVC layout without `user_version` drift), admission pipeline in the published order, observe lowering, minimal artifact store, `job.events` cursor pages, `recoverActiveJobs` read-back with zero dispatch.
- r8: the durable layer named above is delivered first on macOS — lock and atomic-replace primitives by TASK-XPA-012/013, the journal discipline and the SQLite `runtime_job` store by TASK-XPA-014 — against the Swift strict decoders. This task ports the platform primitives to NTFS (SPK-5: `FlushFileBuffers`, `MoveFileExW` write-through, `LockFileEx`, the torn-tail matrix) and delivers the Windows end to end on the same crates; it does not shape them.

### Verification

- XPA-AC-1 → Windows-written journal/record/index are decoded by the Swift decoders unchanged.
- XPA-AC-2 → fake process face asserts the real argv (with `-t`); torn-tail exhaustive matrix; restart returns identical `job show/result`.
- XPA-AC-7 → kill after `stepIntent` before dispatch → `outcomeUnknown`, no replay.
- Real device → `agent run --operation observe.device@1` succeeds on Windows and survives daemon restart.

### Notes / handoff

- Stop condition: any capability consumed when the plan cannot be fully materialised.
- Size: L.

## TASK-XPA-006 — Windows capture.diagnostics@1, artifact read/export and HAR crash-resume (GJ-1 pass)

- Status:blocked
- Platform:windows
- Requirements:`session-artifact-storage` (POL-ARTIFACT-001, POL-PRIVACY-001), ADR-0007 decisions 1–7, ADR-0008 decisions 1–5
- Acceptance:XPA-AC-2, XPA-AC-4, XPA-AC-10; Windows GJ-1 `REAL_DEVICE_PASS`
- Depends on:TASK-XPA-005
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: docs/design/cli-golden-journey-headless-runbook.md
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-005, AF-011, AF-012
- Production reachability:`agent.run` with a durable execution record → capture lowering (hilog/hidumper families) → missing products recorded as `missing(reason)` → `artifact.read` bounded pages / `artifact.export` refusing overwrite and symlinks → `agent status` / `human-action show` / `agent resume` after a client crash
- Trusted fact sources:artifact identity = job ID + declared name + SHA-256; sensitive products require explicit opt-in; execution identity from the durable execution store, not from the caller
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `openspec/platforms/windows/conformance-cases.yaml`（rows for the scenarios this Golden Journey exercises, r3）
  - `rust/**`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`、`Catalog/**`、`openspec/specs/**`
- Risk:medium
- Hardware required:yes（Windows host + DAYU200）
- Decision-Grade:D1

### Deliverables

- Windows GJ-1 closed loop per the headless runbook §GJ-1 including HAR crash-resume; `capture-summary.json`; Windows GJ record under `docs/design/references/v1.6-goal/`.

### Verification

- XPA-AC-2 → capture failure skips receive and cites the upstream root cause.
- XPA-AC-10 → export never overwrites; sensitive read without opt-in refused.
- Real device → runbook GJ-1 criteria all hold → `REAL_DEVICE_PASS` (Windows).

### Notes / handoff

- Stop condition: any raw HDC command.
- Size: M.

## TASK-XPA-007 — WinUI 3 walking skeleton showing the real Windows daemon (Overview, Device, History, Job Inspector, Recovery banner)

- Status:blocked（also awaits SPK-4）
- Platform:windows
- Requirements:REQ-UX-001, REQ-UX-003, REQ-UX-004, REQ-UX-005, REQ-UX-006, REQ-I18N-001, `openspec/architecture/system.md:34` (UI consumes use cases only)
- Acceptance:AC-UX-001-01, AC-UX-003-01, AC-UX-004-01, AC-UX-005-01, AC-UX-006-01, AC-I18N-001-01, XPA-AC-8
- Depends on:TASK-XPA-006
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: docs/design/implementation-coverage.json
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-004, AF-010
- Production reachability:WinUI → `ArkDeck.ClientKit` (generated records) → named pipe → read-only methods and the typed `job.submit` gate; the App holds no runtime semantics and no executable
- Trusted fact sources:all state is daemon projection (`job.status`, `operation.list`, HAR documents); strings come from the shared bilingual source generated into `.resw` and `.xcstrings`
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `windows/**`
  - `spec/ui-semantics/**`
  - `ArkDeckApp/Resources/**`（generated content only, values unchanged）
  - `.github/workflows/swift-ci.yml`（wire the planner's `windows` output to a hosted job; no other edit）
  - `.github/workflows/windows-*.yml`
  - `scripts/ci/plan.py`
  - `scripts/ci/test_plan.py`
  - `scripts/test_agent_pr_workflow.py`（r5: the `swift` aggregate's `needs` list is pinned there verbatim）
  - `docs/design/**`
- Forbidden paths:
  - `rust/**` runtime semantics、`Packages/**`、`openspec/specs/**`
- Risk:medium
- Hardware required:no（Windows host; device optional）
- Decision-Grade:D1（human-gated: needs a Windows host, a reference measurement host or UI review; not claimable by `scripts/host_loop`）

### Deliverables

- MSIX project, UIA names, live region for Job state changes, keyboard paths, bilingual catalog generator (one source → `.resw` + `.xcstrings`).
- CI planner lane (r3): `scripts/ci/plan.py` gains a `windows` lane selected by `windows/**` that builds and tests the WinUI/ClientKit solution on a Windows runner; on a non-Windows host `--run-local` reports the lane as not runnable and exits non-zero instead of passing silently. The hosted job is a `needs` entry of the `swift` aggregate with the selected-or-skipped test, and `scripts/test_agent_pr_workflow.py` is updated in the same PR (r5).

### Verification

- XPA-AC-8 → UIA tree snapshot semantically equal to the macOS AX snapshot for the same fixture; Narrator reads Job state changes; no disabled placeholder for unimplemented capabilities.
- AC-I18N-001-01 → long text and missing keys on Windows.
- XPA-AC-6 (r3) → `ArkDeck.ClientKit` refuses a pipe whose owner SID is not the current user's and shows the daemon-unavailable recovery banner instead of data from an impostor server.
- Planner (r3) → `scripts/ci/test_plan.py` covers `windows/**`.

### Notes / handoff

- Stop condition: any runtime semantic implemented inside the App.
- Size: L.

## TASK-XPA-008 — Windows GJ-2 HAP debug (durable import, deviceMutation admission, capability store)

- Status:blocked
- Platform:windows
- Requirements:POL-AGENT-002, REQ-JOB-006, `debug-workbench`, CLI-REQ-023 (imported input lifecycle)
- Acceptance:XPA-AC-2, XPA-AC-4, XPA-AC-7; Windows GJ-2 `REAL_DEVICE_PASS`
- Depends on:TASK-XPA-006
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeCapabilityStore.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-003, AF-005, AF-014
- Production reachability:`artifact.import.*` (2 MiB chunks, durable Import owner) → lease → deviceMutation admission where the protected Runtime generates, reserves, consumes and settles the `RuntimeCapability` → lowering → install/launch/pid readback → cleanup
- Trusted fact sources:capability minted only from fresh target/binding/tool facts and the full materialised plan; callers may only reference a capability by ID; lineage chain (`previousLineageSHA256`) identical to the macOS format
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `openspec/platforms/windows/conformance-cases.yaml`（rows for the scenarios this Golden Journey exercises, r3）
  - `rust/**`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`、`Catalog/**`、`openspec/specs/**`
- Risk:high（first deviceMutation on Windows）
- Hardware required:yes（Windows host + DAYU200）
- Decision-Grade:D1

### Deliverables

- Capability store and ledger port; durable import; `debug.hap@1` lowering. The WinUI Debug Apps/Logs surface is delivered by TASK-XPA-020 (r5: this task depends on TASK-XPA-006 only, so the TASK-XPA-007 skeleton it would build on need not exist yet).

### Verification

- XPA-AC-4 → capability consumption is zero when provider or plan is unavailable (`PRODUCT-LOOP.md:576`).
- XPA-AC-7 → kill after consume before dispatch → fail closed, use ordinal preserved.
- XPA-AC-1 → capability document and ledger decoded by Swift.
- Real device → runbook GJ-2 criteria → `REAL_DEVICE_PASS` (Windows).

### Notes / handoff

- Stop condition: any caller-provided capability accepted.
- Size: L.

## TASK-XPA-009 — Windows GJ-3 app-owned native library deploy with rollback

- Status:blocked
- Platform:windows
- Requirements:`debug-workbench`, `deploy.native-library.app-owned@1` descriptor semantics (unchanged)
- Acceptance:XPA-AC-2, XPA-AC-7; Windows GJ-3 `REAL_DEVICE_PASS`
- Depends on:TASK-XPA-008
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Tools/OpenHarmonyNativeCodeSignHelper/main.c
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-011
- Production reachability:ELF/ABI/Build-ID/hash validation (pure Rust) → staging → remote hash → atomic publish → process restart → `hashProcessAndMaps` verified → rollback leg on failure
- Trusted fact sources:library facts from the artifact store; device trust of the signing container is observed, never assumed
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `openspec/platforms/windows/conformance-cases.yaml`（rows for the scenarios this Golden Journey exercises, r3）
  - `rust/**`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`、`Catalog/**`、`openspec/specs/**`
- Risk:medium
- Hardware required:yes（Windows host + DAYU200 + signed test library）
- Decision-Grade:D1

### Deliverables

- Native library provider leg on Windows; code-sign helper built for Windows or ported to Rust. The WinUI Debug Artifacts tab is delivered by TASK-XPA-020 (r5).

### Verification

- Real device → runbook GJ-3 criteria including the rollback leg → `REAL_DEVICE_PASS` (Windows).

### Notes / handoff

- Stop condition: success reported while the device does not trust the signing container.
- Size: M.

## TASK-XPA-010 — Windows GJ-4 full-restore flash through the Rust ArkForge lane

- Status:blocked（external dependency: ArkForge AF-W1 green on a real Windows host）
- Platform:windows
- Requirements:REQ-FLASH-007, REQ-FLASH-015, REQ-FLASH-016/017/018, POL-AGENT-002, POL-RECOVERY-001
- Acceptance:AC-FLASH-014-01, XPA-AC-4, XPA-AC-7, XPA-AC-10; Windows GJ-4 `REAL_DEVICE_PASS`
- Depends on:TASK-XPA-008
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Package.swift
    blob: <40-hex git OID>   # ArkForge revision pin
  ```

- Applicable failure patterns:AF-002, AF-003, AF-005, AF-008, AF-014
- Production reachability:`arkdeck-provider-arkforge` → `arkforge-client` + `arkforge-arkdeck-adapter` → `arkforged.exe` spawned by the daemon with a stdin pairing secret → StepPermit (CBOR vectors) → readback / rebind / postflight → recovery epoch
- Trusted fact sources:destructive capability pins operation/version, stable identity, binding revision, exact inputs, plan digest, archive digest, expiry, budgets; 16 epochs / 4 h / concurrency one; unknown intents are never replayed
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `openspec/platforms/windows/conformance-cases.yaml`（rows for the scenarios this Golden Journey exercises, r3）
  - `rust/**`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`、`Catalog/**`、`openspec/specs/**`、`openspec/constitution.md`
- Risk:destructive
- Hardware required:yes（Windows host + DAYU200 + maintainer HardwareCampaign window）
- Decision-Grade:D2

### Deliverables

- Rust ArkForge lane on Windows. The WinUI Flash surface with the same single fully named primary button is delivered by TASK-XPA-020 (r5).

### Verification

- Differential (plan-only) → Swift and Rust compute the same plan digest for the same archive.
- Fault injection → rebind zero/multiple candidates, identity downgrade → zero dispatch.
- Real device → runbook GJ-4 criteria under maintainer authorisation → `REAL_DEVICE_PASS` (Windows).

### Notes / handoff

- Stop condition: any uncertain effect that cannot be bounded → zero dispatch.
- Size: L.

## TASK-XPA-011 — Windows GJ-5 bounded AI debug loop (workspace and analyzer providers)

- Status:blocked
- Platform:windows
- Requirements:`PRODUCT-LOOP.md:412-448` (GJ-5 budgets), CLI-REQ-022, POL-PRIVACY-001
- Acceptance:XPA-AC-2, XPA-AC-4, XPA-AC-10; Windows GJ-5 `REAL_DEVICE_PASS`
- Depends on:TASK-XPA-008
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/WorkspaceProvider/WorkspaceOperationsProvider.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-003, AF-007, AF-011
- Production reachability:workspace provider (git / node+hvigor / hap-sign-tool through registered toolchain references; keystore password in Credential Manager; presence gate through the HAR console challenge) and analyzer provider (crash signature, hilog summary) → `agent run` budgets → negative `revisionConflict` with zero dispatch
- Trusted fact sources:toolchain identity from registered references, never from PATH; secrets never in argv/env/receipts
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `openspec/platforms/windows/conformance-cases.yaml`（rows for the scenarios this Golden Journey exercises, r3）
  - `rust/**`
  - `spec/**`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`、`Catalog/**`、`openspec/specs/**`
- Risk:high
- Hardware required:yes（Windows host + DAYU200 + DevEco SDK）
- Decision-Grade:D1

### Deliverables

- Workspace and analyzer providers on Windows; `analyzer.*trace*` reports `unavailable(reasonCode)` until TASK-XPA-021. The WinUI surface of the bounded loop is delivered by TASK-XPA-020 (r5).

### Verification

- Differential → analyzer outputs byte-equal to Swift for the same artifacts.
- Real device → runbook GJ-5 criteria with the nine budgets recorded → `REAL_DEVICE_PASS` (Windows).

### Notes / handoff

- Stop condition: any secret in argv/env/receipt.
- Size: L.

## TASK-XPA-012 — Move host-only durable stores to the Rust owner on macOS

- Status:in-progress（2026-09-11: isolated Rust History, Session resources/export, Trace cache status and Bootstrap inspection and DevEco registration serve CLI/control; Bundle list also serves immutable pages through the Rust owner with native cross-language cursor checks; Bundle retirement connects exact-reference metadata retirement to its Rust owner while retaining immutable content; writes preserve their frozen formats and reads verify existing native content. the HDC capture/registration library preserves native bytes and passes strict Swift readback; the Rust CLI HDC registration RPC phase merged in PR #1860 at d00e4ec with isolated process/restart validation. The current tool list and metadata-retirement phase is tracked in evidence/runs/TASK-XPA-012/tool-list-retirement-run.md; it does not complete this Task. Cleanup apply, remaining host-store writes, installed integration and GJ-1 acceptance remain pending）
- Platform:macos
- Requirements:`session-artifact-storage` (storage owner), `docs/design/cli-runtime-storage.md:11-24`
- Acceptance:XPA-AC-1, XPA-AC-7, XPA-AC-9; macOS GJ-1 re-pass
- Depends on:TASK-XPA-003
- Readiness input pins（protected-main source baseline; candidate changes are tested against these inputs）:

  ```yaml pins
  - path: main
    commit: ccde4a2e87b69edf7aaa422f678b7aeef359e17f
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSessionStorageStore.swift
    blob: 5d4f994d33f8054c9cb6988aeaa94b0be7ce16ab
  ```

- Applicable failure patterns:AF-004, AF-005, AF-018
- Production reachability:the Rust daemon owns session storage, history filters, display names, trace cache, tool/bundle registry and storage policy; develop against an explicit isolated root, then detach Swift consumers before installed activation. The first slice serves `history.filter.*` directly without a Swift child.
- Trusted fact sources:generation-CAS documents under the same lock discipline; ordinary saved filters and display preferences may be rebuilt. These local preferences confer no device authority.
- Allowed paths:
  - `spec/baselines/swift-single-v1.json`（declared scope extension: refresh the published-main contract pin after conflict resolution）
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIArgumentParser.swift`（declared scope extension: allow transport options only for the existing DevEco registration variant）
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIBootstrapTools.swift`（declared scope extension: send existing DevEco registration through its typed Runtime method）
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLICommandRegistry.swift`（declared scope extension: describe the mixed local-HDC and Runtime-DevEco registration leaf accurately）
  - `openspec/contracts/cli-command-registry.yaml`（declared scope extension: export the same DevEco registration transport metadata）
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIBootstrapBundles.swift`（declared scope extension: route the existing bundle list leaf through its typed Runtime owner）
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIMachineContracts.swift`（declared scope extension: map additive inspection RPCs to their existing CLI leaves）
  - `openspec/contracts/cli-feature-coverage.json`（declared scope extension: export the two new inspection RPC coverage entries）
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIControlMethodRegistry.swift`（declared scope extension: classify the two additive Bootstrap inspection methods as read-only）
  - `Packages/ArkDeckKit/Contracts/control-protocol.json`（declared scope extension: add typed read-only Bootstrap inspection methods）
  - `spec/control/methods/*.json`（declared scope extension: Bootstrap inspection and registration schemas from native recordings and identity-only refresh of existing methods）
  - `openspec/contracts/runtime-control-plane.schema.json`（declared scope extension: export the same additive Bootstrap inspection contracts）
  - `Packages/ArkDeckKit/Package.swift`（declared scope extension: pin the reviewed ArkTrace strict metadata reader; no dependency product or target changes）
  - `Packages/ArkDeckKit/Package.resolved`（declared scope extension: pin the reviewed ArkTrace strict metadata reader; no dependency product or target changes）
  - `ArkDeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`（declared scope extension: pin the reviewed ArkTrace strict metadata reader; no dependency product or target changes）
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `Packages/ArkDeckKit/Scripts/generate-control-contract.py`（declared scope extension: publish the existing History owner error vocabulary alongside actual recorded responses）
  - `spec/control/methods/history.filter.*.json`（current empty/saved/deleted History response shapes, nullable identities and owner failures）
  - `spec/control/methods/runtime.storage.*.json`（declared scope extension: existing storage owner failures and nullable corrupt-catalog generation, backed by actual isolated Rust responses）
  - `spec/control/methods/session.list.json`（declared scope extension: current immutable cursor shapes and existing Session owner failures, backed by Swift and Rust control recordings）
  - `spec/control/methods/session.show.json`（declared scope extension: existing Session owner failure vocabulary）
  - `spec/control/methods/session.pin.json`（declared scope extension: existing generation-CAS and publication failure vocabulary）
  - `spec/control/methods/session.unpin.json`（declared scope extension: existing generation-CAS and publication failure vocabulary）
  - `spec/control/methods/session.cleanup.preview.json`（declared scope extension: existing cleanup preview owner failures, backed by actual Swift and Rust recordings）
  - `spec/control/methods/session.export.preview.json`（declared scope extension: existing export preview owner failures and nullable catalog accounting, backed by actual recordings）
  - `spec/control/methods/session.export.apply.json`（declared scope extension: existing export apply owner failures and durable result responses, backed by actual recordings）
  - `.github/workflows/swift-slow-lanes.yml`（proposed scope supplement: add the host-only read-only shadow nightly job and archive its comparison receipts; preserve existing jobs, triggers, permissions and gates; effective only after maintainer merge）
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`（disable the Swift owner of these stores）
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Tests/**`（r9: contract tests and the fixtures beside them）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`（r9: the Swift consumers of the host-only stores — `RuntimeSessionStorageStore`, `RuntimeHistoryFilterStore`, display names, `RuntimeTraceCacheApplicationFacade`, storage policy; no engine, admission or capability edit）
  - `Packages/ArkDeckKit/Sources/ArkDeckBootstrap/**`（r9: tool and bundle registry owner hand-off）
  - `Packages/ArkDeckKit/Sources/ArkDeckTraceAdapter/**`（r9: trace cache reader）
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`（r9: shared models）
  - `Packages/ArkDeckKit/LaunchAgents/**`（r9: cutover switch and install receipt）
  - `Packages/ArkDeckKit/Distribution/macOS/**`（r9: paired helper packaging as the cutover moves; provisioning, signing, notarization and assessment checks preserved）
  - `ArkDeckAppUITests/**`（r9: the rollback-drill App smoke of this cutover only; no fixture-as-hardware evidence）
  - `ArkDeck.xcodeproj/project.pbxproj`（r9: registration of those UI-test files in the existing UI-test target; scoped supplement: update only the ArkTrace package revision from `c85731b0f903261bd69cf789027774fde615c8de` to reviewed merge `e6e3133d410fbd7455df17c9486dcd369607e97f` for the strict host-store metadata reader; no target, product, build-setting or signing change）
  - `docs/design/**`
- Forbidden paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`（formats stay frozen）
  - `openspec/specs/**`
- Risk:medium
- Hardware required:yes（DAYU200 for the GJ-1 re-pass）
- Decision-Grade:D1

### Deliverables

- Preserve the existing read-only shadow regression and deliver actual Rust owners with bounded local/CI checks, restart read-back, locks, CAS and atomic publication. Nightly is background regression, not a calendar gate.

### Verification

- XPA-AC-1 → current consumers, wire schemas, canonical bytes and digest/reference identity remain correct; retain strict field checks. No requirement to read rebuildable legacy test data solely for rollback.
- XPA-AC-7 → lock contention and CAS conflicts fail closed.
- XPA-AC-9 → isolated-root restart and single-owner checks; preserve installed state and unresolved real-device records until the reviewed final activation.

### Notes / handoff

- Bundle registration phase (2026-09-12): bounded platform capture and exclusive immutable publication now compose with the Rust registry owner, additive typed `runtime.bundle.register`, and Rust CLI. Swift producer fixtures and isolated Rust process checks cover current interface/refusal/restart behavior. Native successful capture/publication acceptance remains explicitly unexecuted after the prior automatic approval refusal recorded in `evidence/runs/TASK-XPA-012/bundle-registration-run.md`; no installed activation or Task completion is claimed. Compatibility note: the existing inspection-related Allowed-path annotations describe their historical scope extension; this phase uses those already listed paths for the current additive Bundle registration classification and coverage under revision 10, without adding a path pattern or Scope-Extension trailer.
- Tool list/retirement phase (2026-09-12): combines the existing two CLI leaves in one product PR on `d00e4ec`. All changed paths are already allowed on that base; no new Allowed paths or Scope-Extension trailers. HDC registration from #1860 is preserved. Production Swift recordings, strict cross-owner readback and isolated CLI/daemon checks preserve existing business semantics; installed activation, selection, execution, Bundle capture and Session deletion are outside this phase.
- HDC RPC phase: `rust/**` connects the existing capture/registration owner to the Rust CLI and typed handler. The existing `spec/control/methods/*.json` inspection/registration scope and `Packages/ArkDeckKit/Tests/**` cover the actual HDC producer schemas and corpora, including native nullable/quarantine fields needed for restart inspect. The published-main pin refresh uses its existing exact path. No new Allowed paths are added, so this phase carries no Scope-Extension trailers. The four DevEco-only Swift CLI/export scope notes above are not HDC authorization; those files and the Swift CLI behavior remain unchanged. This phase does not complete TASK-XPA-012 or activate the installed owner.
- Stop condition: two processes holding the same store lock.
- Size: M.

## TASK-XPA-013 — Move the artifact store to the Rust owner on macOS

- Status:in-progress（2026-09-11: isolated Job Artifact read library and current inspect/read projections are implemented; Runtime routing, writes, owner cutover and GJ acceptance remain pending）
- Platform:macos
- Requirements:POL-ARTIFACT-001, POL-PRIVACY-001, POL-STORAGE-001, ADR-0007 decisions 1–7
- Acceptance:XPA-AC-1, XPA-AC-7, XPA-AC-9, XPA-AC-10; macOS GJ-1/2/3 re-pass
- Depends on:TASK-XPA-012
- Readiness input pins（published producer input for the read-library phase）:

  ```yaml pins
  - path: main
    commit: b315f371d188f6e0cf14e4d356bb0f50507fb80d
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift
    blob: 5cb2dd20d089617cf042cde6c041fca23ced071b
  ```

- Applicable failure patterns:AF-004, AF-005, AF-011, AF-018
- Production reachability:import/lease/read/export/quota/retention/cleanup-debt served by Rust; the Swift engine publishes through a private `artifact.publish` method authenticated by the pairing secret; GC only reclaims expired, unreferenced, unpinned entries
- Trusted fact sources:artifact identity and payload verification document unchanged; quota refuses new work and never evicts
- Allowed paths:
  - `spec/control/methods/artifact.inspect.json`（declared scope extension: existing nullable digest/revision and observation window recorded from the actual Swift producer）
  - `spec/control/methods/artifact.read.json`（declared scope extension: preserve existing resourceNotFound and integrity refusals from actual Swift producer recordings）
  - `spec/baselines/swift-single-v1.json`（declared scope extension: refresh the checkout manifest for native Import upload schemas and corpus）
  - `spec/control/methods/artifact.import.begin.json`（declared scope extension: existing Swift Import upload and unavailable-owner error frames）
  - `spec/control/methods/artifact.import.append.json`（declared scope extension: existing Swift Import upload and unavailable-owner error frames）
  - `spec/control/methods/artifact.import.abort.json`（declared scope extension: existing Swift Import upload and unavailable-owner error frames）
  - `spec/control/methods/artifact.import.inspect.json`（declared scope extension: existing Swift Import upload and unavailable-owner error frames）
  - `spec/control/methods/artifact.import.inspection.json`（declared scope extension: existing Swift Import upload and unavailable-owner error frames）
  - `spec/control/methods/artifact.import.release.json`（declared scope extension: existing Swift Import upload and unavailable-owner error frames）
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`（engine publish path only）
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Tests/**`（r9: contract tests and the fixtures beside them）
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`（r9: shared models）
  - `Packages/ArkDeckKit/LaunchAgents/**`（r9: cutover switch and install receipt）
  - `Packages/ArkDeckKit/Distribution/macOS/**`（r9: paired helper packaging as the cutover moves; provisioning, signing, notarization and assessment checks preserved）
  - `ArkDeckAppUITests/**`（r9: the rollback-drill App smoke of this cutover only; no fixture-as-hardware evidence）
  - `ArkDeck.xcodeproj/project.pbxproj`（r9: registration of those UI-test files in the existing UI-test target only）
  - `docs/design/**`
- Forbidden paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`、`openspec/specs/**`
- Risk:high（artifact bytes are evidence）
- Hardware required:yes（DAYU200 for the re-pass）
- Decision-Grade:D1

### Deliverables

- Rust artifact store owner; internal publish method; structural test that the Swift engine no longer writes `index.json` directly.

### Verification

- XPA-AC-1 → `index.json` and payload-verification bytes equal for the same publication; Artifact records and derived provenance carry exactly the Swift key sets (`ArtifactStorage.swift:73-79,1736-1741` reject anything else); negative vector with one extra key refused (r3).
- XPA-AC-7 → kill either process mid-publish → index consistent or product recorded missing; never a half-record.
- XPA-AC-10 → quota/retention/export rules unchanged.

### Notes / handoff

- Import upload phase (2026-09-12): the candidate resumes current Swift upload records through Rust begin/append/abort/inspect, durable chunk checkpoints and bounded CLI rediscovery. New daemon begin now resolves the published Target owner: workspace-patch/flash retain their existing snapshots and HAP/native-library use the exact adopted HDC route digest when no canonical alias exists. Canonical alias HDC routes, commit, release and Job-reference inspection remain unavailable until their complete owners join. Unknown commit responses are inspected once and never replayed. See `evidence/runs/TASK-XPA-013/import-upload-run.md` and `import-upload-target-integration.md`; this slice does not complete TASK-XPA-013 or activate the installed owner.
- Size: L.

## TASK-XPA-014 — Move admission, job store, capability and recovery to Rust with the Swift engine as executor sidecar

- Status:in-progress
- Platform:macos
- Requirements:REQ-JOB-001, REQ-JOB-006, REQ-WF-004, POL-AGENT-002, POL-RECOVERY-001, POL-MODE-001, POL-TARGET-001
- Acceptance:XPA-AC-1, XPA-AC-2, XPA-AC-4, XPA-AC-7, XPA-AC-9; macOS GJ-1..5 re-pass
- Depends on:TASK-XPA-013（r8: no longer TASK-XPA-005 — the shared durable and admission code is written here on macOS first and flows to Windows）
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift
    blob: <40-hex git OID>
  - path: openspec/specs/workflow-journal-recovery/spec.md
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-003, AF-004, AF-005, AF-008, AF-014
- Production reachability:Rust admission in the published order → journal intent → private `executor.step.execute{jobId, stepId, typedAction, planDigest, targetFacts, useOrdinal}` → Swift lowering + process + semantic verify → receipt → Rust outcome and artifact publication; plan-only never reaches the executor
- Trusted fact sources:the Rust authority alone reads fresh target/binding/tool facts, materialises the plan, mints/reserves/consumes capabilities and writes intents; the Swift sidecar receives typed actions only and cannot alter operation, target, plan or step set
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `spec/control/methods/artifact.inspect.json`（Job-backed Artifact read routing: actual Swift missing-owner/integrity refusals）
  - `spec/baselines/swift-single-v1.json`（refresh the current checkout manifest; the published test view remains the protected-main merge base）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `Packages/ArkDeckKit/LaunchAgents/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`（r9: owner hand-off and the strict-reader oracle only; formats frozen, no `user_version` bump）
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/**`（r9: the executor sidecar's process face）
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`（r9: runtime models and HAR types）
  - `Packages/ArkDeckKit/Distribution/macOS/**`（r9: paired helper packaging as the cutover moves; provisioning, signing, notarization and assessment checks preserved）
  - `ArkDeckAppUITests/**`（r9: the rollback-drill App smoke of this cutover only; no fixture-as-hardware evidence）
  - `ArkDeck.xcodeproj/project.pbxproj`（r9: registration of those UI-test files in the existing UI-test target only）
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`、`openspec/constitution.md`、`Catalog/**`
  - any `user_version` or schema version bump
- Risk:destructive（authority owner changes; covers GJ-4 flash paths）
- Hardware required:yes（DAYU200; GJ-4 needs a maintainer window）
- Decision-Grade:D2

### Deliverables

- Rust authority; executor-sidecar protocol; cutover preflight with the blocking/parked split of design §G.4 (r5) — blocking: any Job in `queued`, `preflight`, `running`, `waitingForDevice`, `awaitingRebindConfirmation`, `planning`, `cancelRequested`, `cancellingAtSafeBoundary`, `reconciling`, `recoveringByCompleteOverwrite`, `resumeAtConfirmedSafeBoundary`, `userAbandonRequested` or `finalizing`, any pending intent, any running agent execution, any reserved-but-unsettled capability use; parked and carried over unchanged: `waitingForRecovery` (the `outcomeUnknown` lane) and every terminal state; the predicate lives in the shared state table so both implementations agree; state-directory snapshot before cutover; rollback drill.
- r8: `arkdeck-durable`'s journal discipline (fsync, tail cursor, torn-tail repair) and the SQLite `runtime_job` store in the pinned post-SVC layout without `user_version` drift, previously listed under TASK-XPA-005, are delivered here against the Swift strict decoders; the atomic-replace and lock primitives arrive earlier with TASK-XPA-012/013.

### Verification

- XPA-AC-2 → `job.plan` digest equal between Swift and Rust for every operation (plan-only, zero dispatch).
- XPA-AC-1 → journal envelopes and payloads, checkpoints, recovery manifests and the authorization ledger written by Rust decode with the Swift strict validators (`JournalEventValidation.swift:651-660`, `DurableFiles.swift:485-487`, `RecoveryManifestContract.swift`, `AuthorizationUsageLedger.swift:208-218`); negative vector with one extra key refused (r3).
- XPA-AC-7 → crash-window matrix (Rust/Swift × before/after intent, before/after consume) → all fail closed; `outcomeUnknown` lanes carried over and never replayed.
- XPA-AC-9 → cutover and rollback drills recorded with journal/SQLite byte checks.
- Real device → GJ-1..5 headless `REAL_DEVICE_PASS` on the Rust authority.

### Notes / handoff

- Stop condition: any step dispatched without a durable intent; two owners writing SQLite.
- SQLite/read phase (2026-09-12): Rust reads the unchanged v1 SQLite Job index for list/status/show/timeline and gates Artifact inspect/read through the same Job owner. Actual current Swift fixture replies match Rust daemon/CLI across restart. Unknown record fields refuse; authority, execution, capability, journal and recovery writers remain pending. See `evidence/runs/TASK-XPA-014/job-artifact-read-run.md`.
- Size: L.

## TASK-XPA-015 — Port analyzer and workspace providers to Rust (shared with Windows)

- Status:blocked
- Platform:macos
- Requirements:CLI-REQ-022, POL-PRIVACY-001, `PRODUCT-LOOP.md:412-448`
- Acceptance:XPA-AC-1, XPA-AC-10; macOS GJ-5 re-pass
- Depends on:TASK-XPA-014
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AnalyzerProvider/AnalyzerProvider.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-003, AF-004, AF-007, AF-011
- Production reachability:Rust analyzer and workspace providers replace the sidecar for those families; Keychain through the `SecItem*` C API; presence gate through the HAR console challenge; `/usr/bin/git` replaced by a registered toolchain reference
- Trusted fact sources:toolchain identity from registered references; secrets never leave the credential store into argv/env/receipts
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`（sidecar coverage shrink only）
  - `Packages/ArkDeckKit/Tests/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`（r9: composition root of the shrinking sidecar）
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`（r9: shared models）
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`（r9: analyzer contracts and HAR types）
  - `Packages/ArkDeckKit/LaunchAgents/**`（r9: cutover switch and install receipt）
  - `Packages/ArkDeckKit/Distribution/macOS/**`（r9: paired helper packaging as the cutover moves; provisioning, signing, notarization and assessment checks preserved）
  - `ArkDeckAppUITests/**`（r9: the rollback-drill App smoke of this cutover only; no fixture-as-hardware evidence）
  - `ArkDeck.xcodeproj/project.pbxproj`（r9: registration of those UI-test files in the existing UI-test target only）
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`、`Catalog/**`
- Risk:medium
- Hardware required:yes（DAYU200 + DevEco SDK for GJ-5 re-pass）
- Decision-Grade:D1

### Deliverables / Verification

- Analyzer outputs byte-equal to Swift for the same artifacts; signing flow with zero secret leakage; GJ-5 re-pass. Size: L.

## TASK-XPA-016 — Port the HDC provider, supervisor observation and process executor to Rust

- Status:blocked
- Platform:macos
- Requirements:REQ-HDC-006, REQ-HDC-009, POL-HDC-001, POL-WORKFLOW-001, PORT-PROCESS-001
- Acceptance:AC-HDC-006-01, AC-HDC-009-01, XPA-AC-1, XPA-AC-2; macOS GJ-1/2/3 re-pass
- Depends on:TASK-XPA-015
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - artifact: openspec/integrations/openharmony/supervisor-observation-probes.yaml
    sha256: <64-hex sha256>
  ```

- Applicable failure patterns:AF-002, AF-004, AF-010, AF-011, AF-013
- Production reachability:Rust HDC provider (parsers, probe registries, supervisor observation through libproc, `posix_spawn` with the `/.vol/<dev>/<ino>` launch path, PTY secret exchange, persistent shell channel) replaces the sidecar for device-scoped operations
- Trusted fact sources:server identity/generation from commandless platform observation; executable identity from hash plus inode; Golden/Probe fixtures replayed in full
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/**`（r9: the process executor being ported）
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`（r9: the HDC provider and supervisor observation being ported）
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`（r9: composition root of the shrinking sidecar）
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`（r9: shared models）
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`（r9: runtime models and HAR types）
  - `Packages/ArkDeckKit/LaunchAgents/**`（r9: cutover switch and install receipt）
  - `Packages/ArkDeckKit/Distribution/macOS/**`（r9: paired helper packaging as the cutover moves; provisioning, signing, notarization and assessment checks preserved）
  - `ArkDeckAppUITests/**`（r9: the rollback-drill App smoke of this cutover only; no fixture-as-hardware evidence）
  - `ArkDeck.xcodeproj/project.pbxproj`（r9: registration of those UI-test files in the existing UI-test target only）
  - `docs/design/**`
- Forbidden paths:
  - `openspec/integrations/**`、`openspec/specs/**`、`Catalog/**`
- Risk:high
- Hardware required:yes（DAYU200）
- Decision-Grade:D1

### Deliverables / Verification

- Fake process face asserts the real argv; supervisor identity/generation equal to Swift; GJ-1/2/3 re-pass. Size: L.

## TASK-XPA-017 — Port the ArkForge lane and retire the Swift daemon, engine and storage targets

- Status:blocked
- Platform:macos
- Requirements:REQ-FLASH-007/015/016/017/018, POL-AGENT-002, POL-RECOVERY-001, `docs/ArchitectureRules.md` sections 1–4
- Acceptance:AC-FLASH-014-01, XPA-AC-1, XPA-AC-4, XPA-AC-6, XPA-AC-9; macOS GJ-1..5 on the pure Rust daemon
- Depends on:TASK-XPA-016, TASK-XPA-018, TASK-XPA-019（r3: both clients must be decoupled before anything is deleted）, TASK-XPA-025（r5: the performance lanes must already build and measure the Rust daemon and a Rust soak, because `rust-perf.yml` builds the SwiftPM products this task deletes and is outside this task's Allowed paths）
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Package.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-005, AF-008, AF-014, AF-015
- Production reachability:the Rust ArkForge lane consumes `arkforge-client` directly; the Swift sidecar is deleted together with `ArkDeckAgentDaemon`, `ArkDeckAgentDaemonMain`, the engine part of `ArkDeckWorkflows`, `ArkDeckStorage`, `ArkDeckProcess` and `ArkDeckOpenHarmony`; the LaunchAgent points permanently at the Rust binary. Deletion is legal only when nothing links the targets: `ArkDeckCLI` links `ArkDeckWorkflows` and `ArkDeckAgentComposition` (`Packages/ArkDeckKit/Package.swift:112-116`) and is removed by TASK-XPA-018; the App links the `ArkDeckWorkflows` product (`ArkDeck.xcodeproj/project.pbxproj:889`) and drops it in TASK-XPA-019; the Swift fixtures `ArkDeckJournalCrashFixture`, `ArkDeckEngineCrashFixture` and `ArkDeckRuntimeSoakFixture` go together with their targets once their Rust equivalents exist (TASK-XPA-014, TASK-XPA-023)
- Trusted fact sources:unchanged; the repository now holds exactly one runtime implementation and one ArkForge codec
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `Packages/ArkDeckKit/**`
  - `Packages/ArkDeckKit/LaunchAgents/**`
  - `ArkDeck.xcodeproj/**`
  - `docs/ArchitectureRules.md`
  - `openspec/platforms/macos/**`（macOS re-verified on the pure Rust daemon, r3）
  - `openspec/platforms/PLATFORM-PROFILES.lock.yaml`
  - `openspec/verification/traceability.md`（macOS column only）
  - `scripts/ci/plan.py`（r9: retire the lanes that build the SwiftPM products this task deletes; no other edit — precedent TASK-XPA-002 r3/r5）
  - `scripts/ci/test_plan.py`（r9: the matching planner tests）
  - `.github/workflows/swift-ci.yml`（r9: the same lane retirement; no other edit）
  - `scripts/test_agent_pr_workflow.py`（r9: the `swift` aggregate's pinned `needs` list）
  - `ArkDeckAppUITests/**`（r9: the retirement's App smoke only）
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`、`openspec/constitution.md`、`Catalog/**`
- Risk:destructive
- Hardware required:yes（DAYU200 + maintainer window for GJ-4）
- Decision-Grade:D2

### Deliverables / Verification

- No second runtime implementation in the repository; structural tests guard "Swift holds no runtime semantics"; release DMG contains the Rust daemon as nested code with empty entitlements; GJ-1..5 `REAL_DEVICE_PASS`; the macOS column of `openspec/verification/traceability.md` and the lock file flip here and nowhere earlier. Size: L.
- r3 note: r1/r2 depended on TASK-XPA-016 alone, which would have deleted modules the Swift CLI and the App still linked — an unreleasable intermediate state. The order is now decouple (018 ∥ 019), then delete.

## TASK-XPA-018 — Rust CLI full parity and Swift CLI retirement

- Status:in-progress（2026-09-11: the continuous Rust CLI foundation serves operation describe/example and consumes current Job queries with bounded deadlines; full leaf parity, export, Swift retirement and GJ acceptance remain pending）
- Platform:macos（r8: the Rust CLI becomes the only CLI on Windows when that side starts）
- Requirements:CLI-REQ-001..025, `docs/design/arkdeck-cli-product-spec.md` §14/§15/§18
- Acceptance:XPA-AC-3; `cli-feature-coverage.json` `fullFunction` on both platforms
- Depends on:TASK-XPA-002's macOS read-only foundation（continuous: the Rust CLI's read-only leaves, r8）, TASK-XPA-016（final: every leaf, including the macOS in-process compatibility leaves, is served by the Rust daemon or tombstoned per CLI spec §12; r3 — previously the final dependency was TASK-XPA-017, which is the wrong way round because `ArkDeckCLI` links the modules TASK-XPA-017 deletes）
- Readiness input pins（protected-main input for continuous CLI parity）:

  ```yaml pins
  - path: main
    commit: b315f371d188f6e0cf14e4d356bb0f50507fb80d
  - path: openspec/contracts/cli-command-registry.yaml
    blob: 594f4f03efbc1b30a83ecb1b3aed208baa6ebc74
  ```

- Applicable failure patterns:AF-004, AF-006, AF-010
- Production reachability:`arkdeck` (Rust) → same wire methods; `maintainer contracts export` produced by Rust must equal the published bundle before the fact source flips
- Trusted fact sources:219 argv fixtures, envelope/page/nextAction samples and the published contract bundle are the oracle until parity, then Rust becomes the oracle
- Allowed paths:
  - `spec/control/methods/job.timeline.json`（declared scope extension: existing invalid-cursor refusal backed by actual Swift producer recordings）
  - `spec/control/methods/job.list.json`（declared scope extension: current typed filters and result branches backed by actual Swift producer recordings）
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `Packages/ArkDeckKit/**`（Swift CLI removal）
  - `openspec/contracts/cli-*.yaml`、`openspec/contracts/cli-*.json`、`openspec/contracts/runtime-control-plane.schema.json`
  - `scripts/ci/plan.py`（r9: retire the lanes that build the SwiftPM products the Swift CLI removal deletes; no other edit — precedent TASK-XPA-002 r3/r5）
  - `scripts/ci/test_plan.py`（r9: the matching planner tests）
  - `.github/workflows/swift-ci.yml`（r9: the same lane retirement; no other edit）
  - `scripts/test_agent_pr_workflow.py`（r9: the `swift` aggregate's pinned `needs` list）
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`、`Catalog/**`
- Risk:medium
- Hardware required:yes（headless GJ-1..5 with the Rust CLI）
- Decision-Grade:D1

### Deliverables / Verification

- Byte-equal fixtures; zero-drift export from Rust; Swift CLI deleted; GJ-1..5 headless with the Rust CLI. Must complete before TASK-XPA-017 (r3). Size: L.

## TASK-XPA-019 — macOS App consumes ArkDeckClientKit and drops ArkDeckWorkflows

- Status:blocked
- Platform:macos
- Requirements:REQ-UX-001..007, REQ-DIAG-001/002, REQ-I18N-001, `openspec/architecture/system.md:34`
- Acceptance:AC-UX-001-01..AC-UX-007-01, AC-DIAG-001-01/02, AC-DIAG-002-01, AC-I18N-001-01, XPA-AC-8
- Depends on:TASK-XPA-001, TASK-XPA-014（delivered facade by facade, up to 13 sub-PRs）
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: ArkDeckApp/App/ArkDeckApp.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-002, AF-004, AF-010, AF-013
- Production reachability:App → `ArkDeckClientKit` (generated typed models, `xpc_connection` transport, presentation adapters) → Mach service; the App no longer links `ArkDeckWorkflows`
- Trusted fact sources:daemon projections and `spec/ui-semantics`; the App derives no state
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/ArkDeckKit/**`（`ArkDeckClientKit` target and the removal of App-facing facades）
  - `spec/ui-semantics/**`
  - `docs/design/**`
- Forbidden paths:
  - `rust/**` runtime semantics、`openspec/specs/**`
- Risk:medium
- Hardware required:no（UI tests; real device only where an AC requires App presentation）
- Decision-Grade:D1（human-gated: needs a Windows host, a reference measurement host or UI review; not claimable by `scripts/host_loop`）

### Deliverables / Verification

- `ArkDeckApp` has no `import ArkDeckWorkflows`; 59 UI tests pass; each facade switch is releasable. Must complete before TASK-XPA-017 (r3). Size: L (S/M per facade).

## TASK-XPA-020 — WinUI surfaces to parity (Debug, Flash, Viewer, Diagnostics, Settings, Device)

- Status:blocked
- Platform:windows
- Requirements:REQ-UX-001..007, REQ-DIAG-001/002, REQ-I18N-001, `ui-dump`, `debug-workbench`, `flashing` (presentation clauses)
- Acceptance:XPA-AC-5, XPA-AC-8; design §H.3 gates per surface
- Depends on:TASK-XPA-007 and, per surface, the matching Windows Golden Journey task: Debug Apps/Logs ← TASK-XPA-008, Debug Artifacts ← TASK-XPA-009, Flash ← TASK-XPA-010, the bounded AI debug loop surface ← TASK-XPA-011, Device/Diagnostics/Settings/Viewer ← TASK-XPA-006（r5: the Golden Journey tasks carry no WinUI deliverable any more, because none of them depends on the TASK-XPA-007 skeleton）
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: docs/design/macos-ux-interaction-spec.md
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-004, AF-010, AF-013
- Production reachability:WinUI → ClientKit → pipe; every surface renders daemon projections; unimplemented capabilities show `unavailable(reasonCode)` with the CLI-equivalent path, never a disabled placeholder
- Trusted fact sources:as TASK-XPA-007
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `windows/**`
  - `spec/ui-semantics/**`
  - `docs/design/**`
- Forbidden paths:
  - `rust/**` runtime semantics、`openspec/specs/**`
- Risk:medium
- Hardware required:yes for Device/Viewer/Debug presentation ACs（Windows host + DAYU200）
- Decision-Grade:D1

### Deliverables / Verification

- Six surface PRs; §H.3 parity gates; §I performance gates; accessibility gates. Size: L (per surface M).

## TASK-XPA-021 — Trace on Windows (capture/inspect/export parity; viewer scope per maintainer decision)

- Status:blocked（awaits maintainer decision 5）
- Platform:windows
- Requirements:`trace` spec (REQ-TRACE-006 job-scoped isolation among others), `analyzer.analyze-trace@1` / `analyzer.summarize-trace@1` descriptors (unchanged)
- Acceptance:XPA-AC-2, XPA-AC-8
- Depends on:TASK-XPA-020
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/manifest.json
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-004, AF-007, AF-013
- Production reachability:`trace_streamer` Windows build (upstream smartperf artefact, licence and provenance verified in-repo) → analyzer operations on Windows → `trace inspect/export` parity; viewer per decision
- Trusted fact sources:parser/engine version and SHA pinned as on macOS
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`
  - `windows/**`
  - `Packages/ArkDeckKit/ThirdParty/**`
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`、`Catalog/**`
- Risk:medium
- Hardware required:yes（Windows host + DAYU200）
- Decision-Grade:D1

### Deliverables / Verification

- `trace inspect/export` outputs equal to macOS; honest `unavailable` for the viewer if not delivered. Size: L.

## TASK-XPA-022 — Windows packaging, signing, update channel and clean-host smoke

- Status:blocked（awaits maintainer decisions 9–11）
- Platform:windows
- Requirements:`openspec/platforms/windows/profile.md:71-81` (trust and distribution spike), POL-PRIVACY-001
- Acceptance:XPA-AC-6, XPA-AC-9; release gate G9
- Depends on:TASK-XPA-007, TASK-XPA-010, TASK-XPA-011
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: docs/release/macos-auto-update.md
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-007, AF-012, AF-014
- Production reachability:MSIX packaged + self-contained Windows App SDK; Azure Artifact Signing with timestamp; App Installer feed; daemon and CLI also as xcopy artefacts for CI
- Trusted fact sources:package identity and signature; clean-host matrix results recorded as evidence
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `windows/**`
  - `.github/workflows/windows-*.yml`
  - `docs/release/**`
  - `openspec/platforms/windows/**`（final `conformance-cases.yaml` and profile status, r3）
  - `openspec/platforms/PLATFORM-PROFILES.lock.yaml`
  - `openspec/verification/traceability.md`（Windows column only）
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`、`openspec/platforms/macos/**`
- Risk:medium
- Hardware required:yes（clean Windows 11 x64 and ARM64 hosts）
- Decision-Grade:D1

### Deliverables / Verification

- Signed x64 and ARM64 packages; clean-host TRUST matrix; update channel; clean uninstall; the Windows column of `openspec/verification/traceability.md` and the lock file's `verified` tuples flip here and nowhere earlier (r3). Size: M.

## TASK-XPA-023 — Performance regression lanes on both platforms

- Status:done（SPK-1 measured on the macOS reference host 2026-09-04 and passed; harness, committed baseline and the PR/nightly/soak lanes delivered. Evidence: `evidence/runs/TASK-XPA-023/`. Two rows are deliberately not finalised and carry §L.1 items 15–16; CI lanes archive without gating until a baseline for the runner's own host is committed）
- Platform:macos and windows
- Requirements:design §I.2 budgets; `openspec/specs/workflow-journal-recovery/spec.md:296-298` clock contract
- Acceptance:XPA-AC-5
- Depends on:SPK-1
- Readiness input pins:

  ```yaml pins
  - path: .github/workflows/swift-slow-lanes.yml
    blob: 29c438c4f0f82511b52047ed0ae36eb40c42e964
  - path: Packages/ArkDeckKit/Tests/ArkDeckRuntimeSoakFixture/main.swift
    blob: 113e34039bec66f2e2dc2750fe39acc3dd99e2be
  ```

- Applicable failure patterns:AF-007, AF-010, AF-011
- Production reachability:not applicable（measurement only; no runtime effect）
- Trusted fact sources:benchmarks run on the reference hosts in release builds; results archived as workflow artefacts and compared against the committed baseline
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`（benchmarks and soak）
  - `.github/workflows/rust-perf.yml`
  - `Packages/ArkDeckKit/Tests/ArkDeckRuntimeSoakFixture/**`
  - `scripts/bench/**`
  - `scripts/README.md`（仅新增恰一个 boundary-map 表行，对应 `scripts/bench/`）
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`
- Risk:low
- Hardware required:no（device-bound metrics run in the real-device lane）
- Decision-Grade:D1（human-gated: needs a Windows host, a reference measurement host or UI review; not claimable by `scripts/host_loop`）

### Deliverables / Verification

- PR micro-benchmarks with ratio-based noise control; nightly absolute budgets; 24 h soak weekly; committed baseline; regression thresholds +20% (PR) / +10% (nightly). Size: M.
- Defect repairs after `done` ride under this task inside its Allowed paths, each with a run record under `evidence/runs/TASK-XPA-023/`; the first is the comparator's zero-reference and workload-scale rules plus the PR-lane trigger paths (`run-2026-09-05-comparator.md`, r5). Porting the lanes to the Rust daemon is TASK-XPA-025, not this task.

## TASK-XPA-024 — Optional FFI kernel for Viewer indexing and offline inspectors

- Status:blocked（trigger: §I measurements show the Viewer or offline inspectors miss budget on either platform, or search/hit-test results differ between platforms）
- Platform:macos and windows
- Requirements:`ui-dump` spec presentation clauses; REQ-DIAG-001
- Acceptance:XPA-AC-5, XPA-AC-8
- Depends on:SPK-1; TASK-XPA-019 for the macOS half, TASK-XPA-020 for the Windows half（r8）
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/UIDumpApplicationFacade.swift
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-004, AF-008
- Production reachability:not applicable for effects（pure functions; no I/O, no process, no capability）
- Trusted fact sources:inputs are daemon-served artifacts already verified by digest; the FFI computes projections only
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`（`arkdeck-contract-ffi`）
  - `Packages/ArkDeckKit/**`（`ArkDeckClientKit` binary target）
  - `windows/**`
  - `docs/design/**`
- Forbidden paths:
  - `openspec/specs/**`
- Risk:low
- Hardware required:no
- Decision-Grade:D1（human-gated: needs a Windows host, a reference measurement host or UI review; not claimable by `scripts/host_loop`）

### Deliverables / Verification

- Fixed-v1 ABI identity function with no version negotiation, `catch_unwind` on every export, 24 h fuzz without crash, `unsafe` confined to one ClientKit file, C# `LibraryImport`; index results byte-equal on both platforms. Size: M.

## TASK-XPA-025 — Port the performance lanes to the Rust daemon and a Rust soak fixture

- Status:blocked（r5; awaits the Rust authority of TASK-XPA-014）
- Platform:macos and windows
- Requirements:design §I.2 budgets; `openspec/specs/workflow-journal-recovery/spec.md:296-298` clock contract
- Acceptance:XPA-AC-5
- Depends on:TASK-XPA-014, TASK-XPA-023
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: .github/workflows/rust-perf.yml
    blob: <40-hex git OID>
  - path: scripts/bench/harness.py
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-007, AF-010, AF-011
- Production reachability:not applicable（measurement only; no runtime effect）. `rust-perf.yml` builds `arkdeck-agentd` and `ArkDeckRuntimeSoakFixture` with SwiftPM and the harness drives them; TASK-XPA-017 deletes both products but may not edit the workflow, so the lanes must be switched to the Rust daemon and a Rust soak fixture first, or the retirement either cannot close or breaks the lanes
- Trusted fact sources:the same 13 metrics of design §I.2 measured on the reference hosts in release builds; the Swift baseline archived as the migration's before/after record
- Allowed paths:
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/**`
  - `rust/**`（`arkdeck-soak` fixture and benchmark targets）
  - `scripts/bench/**`
  - `.github/workflows/rust-perf.yml`
  - `docs/design/**`
- Forbidden paths:
  - `Packages/**`（deleting the Swift fixture and daemon belongs to TASK-XPA-017）
  - `openspec/specs/**`
- Risk:low
- Hardware required:no（device-bound metrics run in the real-device lane）
- Decision-Grade:D1（human-gated: needs a reference measurement host; not claimable by `scripts/host_loop`）

### Deliverables / Verification

- `arkdeck-soak` (Rust) reproducing the `ArkDeckRuntimeSoakFixture` semantics and the `arkdeck-runtime-soak/v1` metrics schema; `scripts/bench` captures against the Rust `arkdeck-agentd` (same binary name, built by cargo); `rust-perf.yml` builds no SwiftPM product; a committed baseline re-taken on the Rust daemon on the reference host with the two-level resident-set split; PR, nightly and soak lanes green on the Rust daemon before TASK-XPA-017 starts; the last Swift baseline kept beside it as the before/after record. Size: M.

## Critical path, parallel groups, first three

- Critical path to "Windows/macOS supported": SPK-3 → XPA-001 → XPA-002 → XPA-004 → XPA-005 → XPA-006 → XPA-008 → XPA-010 (external: ArkForge AF-W1) → XPA-022 → gates G1–G10.
- Parallel groups: (1) Windows GJ chain; (2) macOS store cutover chain XPA-003/012/013/014/015/016, then XPA-018 ∥ XPA-019, then XPA-017 (r3: clients decouple before the Swift targets are deleted); (3) client chain XPA-007/019/020; (4) infrastructure SPK-1, XPA-023, XPA-025, XPA-022; XPA-017 also waits for XPA-025 (r5).
- First three: SPK-1, TASK-XPA-001, TASK-XPA-002 (with SPK-2/SPK-3 in parallel).

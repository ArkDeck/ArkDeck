---
id: CHG-2026-074-shared-rust-runtime-core
revision: 5
status: approved # 维护者 review + merge 本 proposal PR 后才生效；合入前任何 TASK-XPA 不开工，第一个实现 PR 只能在合入后声明
class: platform
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# CHG-2026-074 — Shared Rust runtime core with native SwiftUI and WinUI 3 clients

> **This file does not approve itself.** The change is approved only if a human maintainer
> reviews and merges this proposal PR into protected `main`. Nothing here creates authority:
> every `TASK-XPA-*` below stays `blocked` or `ready` until that merge, and `scripts/check_pr_paths.py`
> refuses any implementation PR that declares a task not yet present on `main`.

> **Four-category declaration.** This change publishes no new Catalog operation, no new provider ID,
> no new integration/device profile and no destructive admission policy change. It is a `platform`
> class change that (1) reverses the architecture decision in
> `openspec/architecture/core-portability.md:9,30,34` from "language-neutral contracts with
> conforming native implementations" to "one shared Rust runtime plus native UI ports", (2) updates
> the Windows platform profile from `planned` to W0/W1 in progress, and (3) fixes the physical form
> of Core for the macOS and Windows profiles. Core Requirements and Acceptance Scenarios are not
> edited, relaxed or renumbered (POL-PLATFORM-001).

> **Design input.** The complete analysis, decision matrix, diagrams, migration plan, UX parity
> contract, performance plan and task DAG are in
> `docs/design/cross-platform/rust-core-cross-platform-architecture.md` (sections A–L), pinned by
> `design.md` in this directory. This proposal only carries the governance-facing summary.
> The same content was first filed as a draft in PR #1712; this change supersedes that draft.

## Governance loop

1. **Why a change is required at all.** `core-portability.md:30` states that introducing a shared
   library or code generation must first go through an architecture/platform change that updates
   every affected Profile and verification plan, and `:34` reserves a shared Rust/C++/WASM library
   for "an approved implementation/architecture change". `PRODUCT-LOOP.md:702-725` allows
   structural change only in five situations; this proposal invokes situation 1 (the current
   module boundaries cannot complete a real closed loop on Windows) and situation 5 (a second
   native Runtime implementation would let a different execution path bypass the single safety
   kernel). Every implementation task below rides with a Golden Journey hop or re-pass, as
   `PRODUCT-LOOP.md:725` demands.
2. **Why now.** GJ-1 through GJ-5 are `REAL_DEVICE_PASS` on the current Catalog digest
   `508783ac…` with 29/29 canonical operations exercised
   (`docs/design/references/v1.6-goal/real-device-validation.md:209-227`), which is exactly the
   condition `PRODUCT-LOOP.md:1004-1029` sets for lifting the freeze on new platform support and
   package restructuring.
3. **Why Rust and why one daemon.** The product family already has a Rust daemon precedent with a
   Windows named pipe, a language-neutral spec and a Rust conformance oracle (ArkForge, pinned at
   `Packages/ArkDeckKit/Package.swift:44-47`). Re-implementing 157k lines of Swift runtime
   semantics in C# would create two authority implementations; putting the runtime into a client
   library would put authority into the sandboxed App and turn Rust aborts into UI crashes. The
   decision matrix is section C of the design document.
4. **No unattended claim.** No task carries a `D0` decision grade; every task is human-gated
   (D1) or destructive (D2), so `scripts/host_loop` can claim nothing from this change.
5. **Why the scope is finite and reversible.** The migration is a strangler: a Rust control-plane
   façade first, then durable stores move owner one at a time, then providers move family by
   family, and the Swift daemon is retired last. Every macOS step is releasable and rolls back by
   pointing the LaunchAgent at the Swift daemon again; no durable schema is bumped before the Swift
   daemon is gone.

## Why

- Windows is a declared target platform (`openspec/config.yaml:3`) with a `planned`/`notStarted`
  profile (`openspec/platforms/windows/profile.md:1-9`) and Slice D of the CLI product spec is the
  only open item on the cross-platform claim (`docs/design/arkdeck-cli-product-spec.md:1584-1586`).
- The current portability decision expects a second native implementation on Windows. That
  duplicates admission, journal, recovery, capability and artifact semantics that today exist only
  as Swift code (10,252-line `RuntimeJobEngine.swift`, 18k-line storage layer) with no
  per-method typed schema (`openspec/contracts/runtime-control-plane.schema.json` constrains only
  the envelope) and with 44 daemon methods published only on protocol 1.x
  (`Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocolGenerated.swift:11`).
- Users on both platforms must get the same product: same availability/effect/Job/Artifact/HAR/
  recovery/error semantics, bilingual meaning, accessibility and performance, with platform-native
  UI. That is only cheap when the semantics live once.

## What changes

- In scope:
  - `openspec/architecture/core-portability.md`: the Core physical form becomes one shared Rust
    runtime (`arkdeck-agentd`) consumed by native clients over local IPC; the language-neutral
    contract/vector suite stays mandatory and gains per-method typed schemas, a data-driven job
    state table, registries and bilingual UI semantics under a `spec/` root.
  - `openspec/platforms/macos/profile.md`, `windows/profile.md`, `linux/profile.md`: `Core
    strategy` value changes from `native-conforming-shared-contract-vector-suite` to
    `shared-rust-runtime-native-ui-shared-contract-vector-suite`; Windows profile version 0.2.0
    with the W0 spike started; `PLATFORM-PROFILES.lock.yaml` updated accordingly.
  - A Rust workspace under `rust/` (crates listed in design section D.1/E.4), a Rust CLI, a Windows
    WinUI 3 client under `windows/`, a Swift `ArkDeckClientKit`, and the strangler migration of the
    macOS daemon.
  - Protocol 2.1.0 additive methods so that Windows never needs protocol 1.x.
- Out of scope:
  - Any change to Core Requirements, Acceptance Scenarios, Safety invariants, `Catalog/`
    operations, provider IDs or destructive admission policy.
  - Linux delivery (profile stays `planned`).
  - Trace Viewer parity on Windows beyond capture/inspect/export (maintainer decision 5).
- Observable behaviour before/after:
  - macOS: no observable change until each cutover task; each cutover re-passes GJ-1..5 headless on
    the current digest before it ships.
  - Windows: from `NOT_STARTED` to a real `arkdeck doctor` / `device candidates` / `target adopt` /
    `observe.device@1` / `capture.diagnostics@1` walking skeleton, then GJ-2..5.

## Scope (Requirements / AC)

- Requirements: none edited. Implemented unchanged on both platforms: `workflow-journal-recovery`
  (REQ-JOB-001, REQ-JOB-006, REQ-WF-004), `device-targeting-auth`, `session-artifact-storage`,
  `toolchain-hdc-server` (REQ-HDC-006, REQ-HDC-009), `flashing` (REQ-FLASH-007/015/016/017/018),
  `debug-workbench`, `ui-dump`, `trace`, `desktop-ux-observability` (REQ-UX-001..007,
  REQ-DIAG-001/002, REQ-I18N-001).
- Acceptance: the current CORE-CONFORMANCE suite (121 scenarios) becomes a target obligation on
  Windows; change-level acceptance `XPA-AC-1..10` is defined in `verification.md`.
- Contracts/schemas: additive only. `runtime-control-plane.schema.json` gains protocol 2.1.0
  methods and per-method schemas; `journal-event.schema.json` records the generations 2.0.0–3.0.0
  that Swift already accepts (`Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEvent.swift:65-69`);
  new `spec/` assets are generated from the Swift oracle and frozen.
- Core baseline bump: **no** (`core_change_level: none`). Platform disposition: macOS stays
  `needsReverification` until GJ-1..5 pass on the pure Rust daemon; Windows moves from
  `notStarted` to in progress and may not claim support before gates G1–G10.

## Safety, privacy, and compatibility

- Failure modes: a second side-effect writer during migration (mitigated by store-level ownership
  moves, lock identity re-validation and a cutover preflight that refuses active jobs); semantic
  drift between Swift and Rust (mitigated by byte-for-byte differential tests, read-only shadow,
  crash-window matrices and a Rust conformance generator); Rust panic (daemon `panic=abort` plus
  restart recovery; FFI `catch_unwind` returning an error code); protocol mismatch
  (`protocolVersionUnsupported`, zero dispatch).
- Data/schema compatibility: every durable format (SQLite `runtime_job` v2, journal JSONL
  1.0.0–3.0.0, `job-record.json`, artifact `index.json`, capability document 2.0.0 and ledger,
  recovery epochs, evidence V1–V6) is read and written by Rust at the same schema version; no
  `user_version` or schema bump before the Swift daemon is retired, and no field is added to any
  durable record while the Swift decoders stay strict (r3); legacy generations stay decode-only. `outcomeUnknown` lanes are carried over unchanged and never replayed
  (POL-RECOVERY-001).
- Platform impact: macOS `needsReverification` (already) and must re-verify on the Rust daemon;
  Windows starts W0; Linux remains `planned` with no support claim.
- Rollback/migration: LaunchAgent points back to the Swift daemon; state directory snapshot before
  each cutover; Windows has no installed base to migrate.
- Privacy: no change to POL-PRIVACY-001; secrets never enter argv/env/receipts on either platform;
  Windows credentials go to Credential Manager (DPAPI) with the same redaction rules.

## Maintainer decisions requested

See section L.1 of the design document. The blocking ones for starting work are: (1) approve this
change and the `Core strategy` value change; (2) Rust dependency policy (vetted allowlist vs
zero-dependency); (3) control-plane peer hardening; (4) Golden Journey re-pass rule on runtime
replacement; (9) Windows support tuple (Windows 11 x64 + ARM64); (10) MSIX packaged + self-contained
Windows App SDK; (13) ADR-0009 open ruling before recovery is ported; (17) the same-user trust
boundary statement (r5).

## Revision 2 — SPK-1 outcome and one Allowed-paths correction

Revision 2 changes no scope, no Requirement, no Acceptance Scenario and no
platform disposition. It records what the first delivery under this change
measured, and repairs one defect in its own task table.

1. **`TASK-XPA-023` Allowed paths gained `scripts/README.md`.** The task
   authorises `scripts/bench/**`, but `scripts/README.md` is a boundary map
   that must name every first-level entry under `scripts/`, enforced by
   `scripts/test_check_pr_paths.py::AutomationConfigTests::test_readme_boundary_map_covers_every_first_level_scripts_entry`.
   Creating `scripts/bench/` without editing that map fails the gate, and
   editing it without this line fails `check_pr_paths.py`. As written the two
   rules could not both be satisfied, so the task could not deliver its own
   harness at all. The widening is held to the one boundary-map row this change
   is entitled to add by an annotation on the Allowed-paths line, following
   `chg-2026-008`; annotations are masked before the checker scans path tokens,
   so the restriction is documentation rather than machine-enforced, as
   `tasks.md` says of Forbidden paths generally.
2. **Most design section I.2 budgets are finalised** from the SPK-1 baseline
   taken on the macOS reference host on 2026-09-04 (release build, quiet host,
   three independent runs, widest p95 movement 5.8%): daemon cold start, the two
   constant-size UDS round trips, and idle CPU, thread and descriptor counts.
   The IPC row is split into constant-size replies and paged projections,
   because the single `<= 2/5/10 ms` ceiling was written for the former and a
   per-row projection costs 2.7x more than it allows. Two general rule gaps the
   spike exposed — a budget derived at the measurement floor, and a budget
   quoted at a data scale it was not measured at — are closed in the same
   section.

   **Two rows are deliberately not finalised**, and are registered as design
   section L.1 items 15 and 16 rather than decided here:
   - the paged-projection budget, because the row count every per-row figure
     divides by is not machine-recorded in the baseline document yet;
   - the idle resident-set ceiling, because SPK-1's 62.24 MB is not a cold-idle
     reading at all — the harness samples resources on the same daemon process
     immediately after 3,000 IPC round trips. That row keeps its provisional
     `<= 64 MiB`. Merging this revision selects neither option; the fix
     (restart the daemon before the sampling window) is follow-up work in
     `TASK-XPA-023`.

   For transparency: splitting the IPC row also edits SPK-1's own pass
   criterion in section I.3 from 12 rows to 13. The `< 30%` failure line and
   the "unmeasurable becomes a design gap" escape hatch are untouched; the
   count is a mechanical consequence of the split.

The pinned design blob in `design.md` is re-pinned in this revision, as that
file requires.

## Revision 3 — design review repairs (2026-09-05)

Revision 3 changes no scope, no Requirement, no Acceptance Scenario and no platform
disposition. An external design review of r2 raised eight findings; each was verified
against the code, the checker and the official platform documentation before being
repaired here. Seven are repaired in this revision; the eighth belongs to an open
`TASK-XPA-023` PR.

1. **Transparent forwarding loses the CLI's console origin (P1).** The Swift daemon derives
   the per-frame request context from kernel facts of the accepted socket
   (`AgentDaemon.swift:5095,5149-5194`) and issues the interactive impact-approval challenge
   only for a foreground-terminal UDS peer (`:3978`). Behind the façade that peer would be the
   façade itself. `TASK-XPA-003` now specifies a per-frame origin line that only the façade
   can write on the private socket, bound to the frame by digest, and the tests that prove
   console confirmation still works through it; design §F.2 gained the row, and the task's
   Allowed paths gained `Sources/ArkDeckAgentDaemon/**` for the private listener.
2. **The façade crash acceptance promised "zero dispatch" for both windows (P1).** Only the
   pre-forward window can prove it; after the frame is forwarded the client can only learn
   that the outcome is unknown. The acceptance is split into two windows, the façade is
   forbidden to synthesise the `details.phase`/`newDispatchCount` proof or to re-send a
   forwarded frame, and read-back is the resolution path (design §G.5, `TASK-XPA-003`,
   XPA-AC-7).
3. **"Additive fields are ignored on rollback" contradicts the decoders (P1).** Journal,
   Artifact, checkpoint, recovery-manifest, ledger, audit and toolchain records reject unknown
   keys (`JournalEventValidation.swift:651-660`, `ArtifactStorage.swift:73-79` and others
   listed in design §G.2). The migration now freezes every durable field set; Rust must write
   exactly the Swift key sets, conformance keeps a negative vector, and a new field requires a
   tolerant-reader Swift release first or a post-`TASK-XPA-017` change (design §G.2/§G.4/§G.5,
   XPA-AC-1/AC-9, `TASK-XPA-012/013/014`).
4. **Swift targets were deleted before the clients stopped linking them (P1).**
   `ArkDeckCLI` links `ArkDeckWorkflows`/`ArkDeckAgentComposition` (`Package.swift:112-116`) and
   the App links `ArkDeckWorkflows` (`project.pbxproj:889`), yet `TASK-XPA-017` depended on
   `TASK-XPA-016` alone and `TASK-XPA-018` on `TASK-XPA-017`. The order is now decouple
   (`TASK-XPA-018` ∥ `TASK-XPA-019`, both final on `TASK-XPA-016`) and then delete
   (`TASK-XPA-017`); the DAG, the parallel groups and `design.md` follow.
5. **The Windows pipe had no client-side server authentication (P1).**
   `FILE_FLAG_FIRST_PIPE_INSTANCE` only makes the second instance fail (`ERROR_ACCESS_DENIED`,
   Microsoft `CreateNamedPipe` reference). The client now reads the pipe object's owner SID
   (`GetSecurityInfo`, `OWNER_SECURITY_INFORMATION`) and refuses any server not owned by its
   own token owner — the client-side semantics of .NET `PipeOptions.CurrentUserOnly`
   (`NamedPipeClientStream.ValidateRemotePipeUser`) — with `SECURITY_SQOS_PRESENT |
   SECURITY_IDENTIFICATION` on `CreateFile`; a squatted name fails daemon start closed and is
   reported by `doctor`. Negative tests are in `TASK-XPA-002/007` and XPA-AC-6; risk R16 added.
6. **Most tasks could not submit their own status or evidence (P2).** Only `TASK-XPA-001/002`
   listed this change directory in Allowed paths, which `scripts/check_pr_paths.py` reads from
   the base tree; a synthetic commit confirmed that evidence under `TASK-XPA-003` or
   `TASK-XPA-012` is refused. Every task now lists the directory, and the final conformance and
   traceability edits have named owners: `openspec/platforms/windows/**`, the lock file and the
   Windows traceability column by `TASK-XPA-022` (conformance rows by the Windows Golden Journey
   tasks), `openspec/platforms/macos/**`, the lock file and the macOS column by `TASK-XPA-017`.
7. **The new toolchains were not wired into the unified CI planner (P2).**
   `scripts/ci/plan.py::classify_paths` selects no lane for a diff confined to `rust/**` or
   `windows/**`, so `plan.py --run-local` would pass without compiling the new code.
   `TASK-XPA-002` now delivers a `rust` lane (planner, tests, hosted wiring) and
   `TASK-XPA-007` a `windows` lane that fails loudly on a non-Windows host; both tasks' Allowed
   paths gained `scripts/ci/plan.py`, `scripts/ci/test_plan.py` and the workflow file, and a
   `rust/**`-only diff selecting no lane is a stop condition.
8. **The soak workflow loses its metrics exactly when a gate fails (P2).** Confirmed on `main`
   and on the open `TASK-XPA-023` PR: the fixture persists metrics before evaluating its gates,
   but the `cp` after it runs under `set -eu` and the `always()` upload watches the copied path.
   `.github/workflows/rust-perf.yml` is outside this governance PR and inside `TASK-XPA-023`;
   the fix (state directory in a separate step, upload from that directory) was handed to that
   PR and is not part of this revision.

No maintainer decision is added or removed by this revision; item 16 of design §L.1 and the
provisional budgets stand as in r2. The pinned design blob in `design.md` is re-pinned.

## Revision 4 — one Allowed-paths correction for `TASK-XPA-001` (2026-09-05)

Revision 4 changes no scope, no Requirement, no Acceptance Scenario and no platform
disposition. It repairs one defect in the task table that surfaced when `TASK-XPA-001`
started, of the same kind as the `TASK-XPA-023` correction in revision 2.

1. **`TASK-XPA-001` Allowed paths gained `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/**`.**
   The task publishes protocol `2.1.0` and requires the CLI's target leaves to negotiate it, with
   rollback "daemon binary revert; clients negotiate back to `2.0.0`". The client library decides
   target-protocol behaviour by comparing the negotiated exact version with the single constant
   `ArkDeckControlProtocol.targetVersion` (`AgentClient.swift:114` strict response-shape
   validation, `:136` structured admission errors with `details.phase`/`newDispatchCount`,
   `AgentRuntimeExecutor.swift:492` rethrow of a submit refusal instead of flattening it into a
   receipt). With two target exact versions that comparison is wrong in one direction whichever
   value the constant holds: a client that negotiates `2.1.0` would fall into the legacy branches
   and lose the §8.4 zero-dispatch evidence, or, if the constant moved to `2.1.0`, the same client
   would degrade the moment it negotiated `2.0.0` against a rolled-back daemon. The client library
   therefore has to learn the target-major predicate the daemon learns, and its directory was not
   in the task's Allowed paths (design §J.4 listed the daemon, the CLI and the contract tests, not
   the transport library between them). `scripts/check_pr_paths.py` reads Allowed paths from the
   base tree (r3 finding 6), so the implementation PR cannot supply the line itself. The widening
   is annotated on the Allowed-paths line as in revision 2: the version predicate only, no new
   method, transport or effect. The App's XPC facades in `ArkDeckWorkflows` keep sending the base
   target version without negotiation and are not widened; `targetVersion` itself stays `2.0.0`
   so that a newer App still reaches an older daemon's storage and trace-cache resources.

No maintainer decision is added or removed by this revision. The pinned design blob in
`design.md` is re-pinned; only the section J.4 path line of `TASK-XPA-001` changed.

## Revision 5 — second design review round (2026-09-05)

Revision 5 changes no scope, no Requirement, no Acceptance Scenario and no platform
disposition. A second external review of r3/r4 raised nine findings; each was verified against
the code, the checker, the comparator and the platform references before it was touched. Six are
governance repairs made here; three are defects in delivered code and were fixed in PR #1723 under
`TASK-XPA-023`. One maintainer decision is added (design §L.1 item 17).

1. **Same-user impersonation on the Windows pipe (P1).** r3's owner-SID check cannot tell a
   same-user impostor apart, so r3's "same-account squat → zero frames" was not true. §F.2 now
   has two layers: the owner SID (account and elevation) and an instance check that resolves the
   connection's server PID, pins it by an open handle and requires the installed daemon's image
   and signature or package identity. The reference page for `GetNamedPipeServerProcessId`
   contradicts itself about the handle it accepts, so SPK-3 must confirm it on a client handle;
   if it fails, the boundary is stated honestly: same-user arbitrary code is outside the trust
   boundary on both platforms (ADR-0005 decision 1; a same-uid process can replace the UDS
   socket file on macOS). That statement is item 17 for the maintainer. `TASK-XPA-002` and
   XPA-AC-6 carry the split expectations; risk R16 updated.
2. **App transport rollback (P1).** The App moves from `NSXPCConnection` to `xpc_connection`
   for the Rust façade, but rollback pointed the LaunchAgent at a Swift daemon that still
   vends `NSXPCListener` (`AgentXPCListener.swift:26`), so the CLI would recover and the updated
   App would not. The daemon is installed from the App bundle's nested helper
   (`ArkDeckRuntimeCommands.swift:1258`), so the rollback pair is always one release:
   `TASK-XPA-003` now converts the Swift daemon's listener to the raw libxpc frame protocol in
   the same PR as the App switch, and its rollback acceptance includes the updated App against
   the rolled-back Swift daemon by XPC contract tests and an App UI smoke (§G.1, §G.5, XPA-AC-9,
   risk R17).
3. **Cutover preflight contradicted the `outcomeUnknown` carry-over (P2).** "No non-terminal
   Job" rejects `waitingForRecovery`, which `JobState.isTerminal` classes as non-terminal. §G.4
   now names a blocking set (every in-flight, reconciling, recovering, human-waiting or
   finalising state, pending intents, running executions, unsettled capability uses) and a
   parked set (`waitingForRecovery` and the terminal states) that is carried over unchanged;
   `TASK-XPA-014` and XPA-AC-7 follow.
4. **Zero baseline bypassed the performance check (P2).** Fixed in PR #1723: a zero committed
   reference is judged against the absolute budget in `compare.ABSOLUTE_BUDGETS` (idle CPU 0.5%,
   design §I.2) in both modes and fails without one.
5. **The comparator ignored the workload scale (P2).** Fixed in PR #1723: the workload fields of
   the recorded `scale` are part of the metric's identity; a mismatch is incomparable and fails,
   and the PR lane no longer seeds a different scale from the committed baseline.
6. **The PR performance lane skipped the code it measures (P2).** Fixed in PR #1723: the
   `pull_request` filter now includes the Swift daemon's sources and build inputs.
7. **New CI lanes could not touch the pinned aggregate contract (P2).**
   `scripts/test_agent_pr_workflow.py:412-421` pins the `swift` aggregate's `needs` verbatim.
   `TASK-XPA-002` and `TASK-XPA-007` gained that file, and both lanes must be folded into the
   aggregate with the contract test updated in the same PR.
8. **A WinUI deliverable without its skeleton (P2).** `TASK-XPA-008/009/010/011` depend on
   `TASK-XPA-006` only yet carried WinUI surfaces that need the `TASK-XPA-007` skeleton. Their
   `windows/**` paths and surface deliverables moved to `TASK-XPA-020`, whose dependency line now
   maps each surface to its Golden Journey task.
9. **Retiring Swift would break the performance lanes (P2).** `rust-perf.yml` builds the SwiftPM
   products `TASK-XPA-017` deletes, `TASK-XPA-017` may not edit the workflow and `TASK-XPA-023` is
   done. New `TASK-XPA-025` ports the lanes to the Rust daemon and a Rust soak fixture (depends on
   `TASK-XPA-014` and `TASK-XPA-023`), and `TASK-XPA-017` depends on it.

The pinned design blob in `design.md` is re-pinned.

## Compatibility note

`PRODUCT-LOOP.md:99-116` forbids new proposals during the product-loop phase except for the
safety kernel and the four repository approval categories. This change is filed because
`core-portability.md:30` makes an architecture/platform change the only lawful carrier for a shared
runtime, and because `openspec/platforms/windows/profile.md:15-21` reserves the Windows engineering
decisions for a Windows platform change/ADR. The change ships no readiness, status, evidence or
archive-only follow-ups: approval is the merge of this PR, and every task delivers as one vertical
implementation PR that rides with a Golden Journey hop or re-pass.

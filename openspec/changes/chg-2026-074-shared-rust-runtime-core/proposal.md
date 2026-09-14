---
id: CHG-2026-074-shared-rust-runtime-core
revision: 11
status: proposed # r9 approval remains historical; the r10/r11 deltas require maintainer review
class: platform
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# CHG-2026-074 — Shared Rust runtime core with native SwiftUI and WinUI 3 clients

Revision 11 (2026-09-14) re-measures the macOS chain after four days of delivery and changes
how the remaining work is cut, verified and parallelised: Golden Journey milestones on the
isolated Rust daemon (M1 GJ-1 → M2 GJ-2/3 → M3 GJ-5 → M4 GJ-4 → M5 one-shot cutover and
retirement), a three-tier parity rule for XPA-AC-1/3 under the r10 premise, the withdrawal of
the installed store-by-store composition, `ready` status for TASK-XPA-015/016/019/025 on their
actual interface dependencies, spikes SPK-6..11, a decision package for design §L.1 item 13 and
a verification-overhead rule set. It changes no Requirement, Acceptance Scenario, Core baseline,
safety invariant or hardware criterion; the maintainer's merge is the attestation of the rulings
it records (§ "Revision 11" below).

Revision 10 is delivered with the Rust History owner implementation. The user confirmed
that ArkDeck is unreleased and ordinary existing data is rebuildable test state. It removes
seven-nightly-day waiting, universal legacy interread and same-release Swift rollback goals;
actual Rust requests, persistence, restart, lock/CAS and crash-window checks drive development.
`tasks.md`, `design.md` and `verification.md` describe the runnable milestones and the scoped
XPA-AC-1/9 adjustment. Existing corpus, fixes and historical receipts are preserved. Current
contracts, digest/reference identity, Raw Artifact, real-device intent/outcome and authority/
recovery safety are unchanged. A new root cannot bypass unresolved effects on the same device.
This revision is proposed for maintainer review and carries no new approval or hardware claim.
The existing tasks on protected main remain available under PRODUCT-LOOP §2/§16.

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

## Revision 6 dependency and review boundary

This revision is proposed for maintainer review; the retained `approved` front-matter value
records the existing change state and does not approve r6. It consumes
[CHG-2026-075 — single v1 contracts](../chg-2026-075-single-v1-contracts/proposal.md).
TASK-XPA-001 waits for TASK-SVC-001..004 and publishes typed schemas from their final single-v1
contract. All later Swift/Rust parity and rollback targets are that post-SVC Swift baseline.
Earlier scan facts and revision notes below describe pre-SVC history, not an obligation to
restore old protocol/document generations. SVC-005 owns the single-v1 release acceptance;
XPA tasks retain their separate hardware parity and migration acceptance.

## Revision 7 — SPK-2 outcome (2026-09-05)

Revision 7 changes no scope, no Requirement, no Acceptance Scenario and no platform
disposition, and it does not approve r6 or itself. It records the SPK-2 spike, which the design
lists as the feasibility gate of `TASK-XPA-003` (section J.3) and as an open item of section L
(availability and behaviour of `xpc_connection_set_peer_code_signing_requirement`).

1. **SPK-2 passed on the macOS reference host.** A Rust process held the launchd Mach service
   `com.arkdeck.agentd` through the libxpc C API; a sandboxed client signed with the App's
   Developer ID and the byte-identical `ArkDeckApp/ArkDeckApp.entitlements` completed 1,000
   round trips at p95 0.013 ms (budget 8 ms) with zero errors; the same client without the one
   `mach-lookup` exception never reached the listener; an ad-hoc peer, a same-team peer with
   another identifier and a bare unsandboxed tool were refused by libxpc before their first
   frame reached the handler; the unmodified production `ArkDeck.app` connected and satisfied
   the requirement. Record: `evidence/runs/TASK-XPA-003/spk-2-run.md`; report:
   `docs/design/cross-platform/spk-2-macos-libxpc-mach-service.md`; sources, LaunchAgent
   templates, raw results and listener logs under `evidence/runs/TASK-XPA-003/spk-2/`.
2. **`TASK-XPA-003` now waits on `TASK-XPA-002` and maintainer review only.** Its status line
   and the spike table say so; nothing else in the task changes, and it stays `blocked`.
3. **Facts for maintainer decisions 3 and 6 (design section L.1)**, written into the design's
   section F.2 identity row, section K risk R3 and the section L open-items table:
   (a) the API exists on macOS 12+, returns `EINVAL` for an invalid requirement, and refuses
   inside libxpc at the peer's first message — zero dispatch is a transport property;
   (b) the production-shaped requirement (`anchor apple generic` + `subject.OU` + `identifier`)
   admits same-team Apple Development signatures, so whether release builds add the Developer
   ID intermediate clause is decision 3's to make;
   (c) the same API pins the daemon from the client side (a wrong identifier yields
   `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` instead of the reply), the macOS counterpart of the
   Windows two-layer server check, and the pinned identity must cover the façade and the
   same-release Swift daemon;
   (d) the requirement costs about 1 ms per connection and nothing per message, so the App's
   connection-per-request pattern should not survive the move to `xpc_connection`;
   (e) an NSXPC client is recognisable on a raw listener by its message keys, so the mismatched
   App/daemon pair of XPA-AC-9 can be answered with a structured error rather than a hang.

The pinned design blob in `design.md` is re-pinned in this revision: the section F.2 identity
row, the section J.3 SPK-2 row, risk R3 in section K, one section L open-items row and the
notes on items 3 and 6 of section L.1 changed; nothing else.

## Revision 8 — the macOS side first (2026-09-09)

Revision 8 changes no scope, no Requirement, no Acceptance Scenario, no platform disposition, no
Allowed path and no hardware criterion, and it does not approve r6, r7 or itself; the maintainer's
merge of this PR is the attestation of the ruling it records. It re-orders the task DAG.

1. **Ruling.** The macOS strangler chain is completed first — `TASK-XPA-003` → 012 → 013 → 014 →
   015 → 016, then 018 ∥ 019 and 025, then 017 — and GJ-1..5 re-pass headless on the pure Rust
   daemon (design §J.5 gate G5) before any Windows Golden Journey task starts. Windows is built
   once, on the final Rust runtime. Reasons: (a) the macOS side carries the differential burden —
   byte-for-byte parity with the Swift single-v1 durable formats and the real acceptance on the
   reference host — so shaping the shared `arkdeck-durable`/`arkdeck-runtime`/`provider-*` crates
   on Windows first, as §J.5 recommended through r7, would let that burden reshape them afterwards
   and redo the Windows hops on the new shape; (b) the macOS reference host and the DAYU200 are in
   hand and GJ-1..5 are `REAL_DEVICE_PASS` on the current digest (`TASK-SVC-005` done on
   2026-09-09), while the Windows chain waits for hosts that do not exist yet, so macOS-first is
   also the only order that can start today.
2. **`TASK-XPA-003` is `ready`.** Its dependency is `TASK-XPA-002`'s delivered macOS read-only
   foundation (#1768, `evidence/xpa-002-readonly-foundation.md`, baseline re-pinned at `main`
   `a61848f9`), not `TASK-XPA-002`'s Windows acceptance; SPK-2 passed in r7. Its readiness pins are
   instantiated in this revision; the implementing PR flips it to `in-progress`.
3. **No macOS task depends on a Windows task.** `TASK-XPA-014` no longer waits for
   `TASK-XPA-005`: the journal discipline and the SQLite `runtime_job` store are delivered on macOS
   by `TASK-XPA-014` (lock and atomic-replace primitives earlier by 012/013) against the Swift
   strict decoders, and `TASK-XPA-005` ports the NTFS primitives (SPK-5) and runs the Windows end
   to end on the same crates. `TASK-XPA-018`'s continuous dependency is the foundation's Rust CLI;
   `TASK-XPA-024`'s macOS half waits for `TASK-XPA-019`. The design DAG edge `XPA-005 → XPA-015`
   is removed.
4. **The Windows phase starts after `TASK-XPA-017`.** `TASK-XPA-004` and the Windows acceptance
   of `TASK-XPA-002` (SPK-3, Windows 11 x64 + DAYU200 with a trusted installed daemon and a
   reviewed Windows HDC tuple) wait for `TASK-XPA-017`; the read-only foundation keeps evolving
   with the macOS chain and its Windows acceptance runs against the final runtime. `TASK-XPA-002`
   stays `in-progress` with that acceptance outstanding. SPK-3 is a platform fact and may run
   whenever a Windows host exists; nothing Windows-side is built on it before G5. XPA-AC-1/3/6, the
   Windows support tuple, packaging and the Windows conformance rows are unchanged. A Windows host
   arriving before `TASK-XPA-017` does not by itself re-open the Windows phase; only a further
   revision can.
5. **Design re-pin.** Sections A (item 6), G.1 (the walking-skeleton edge), J.2 (DAG edges), J.4
   (rows 002, 003, 004, 005, 014, 018, 024), J.5 (critical path, parallel groups, current entry,
   gate order) and L.1 (item 18) changed; nothing else.

## Revision 9 — path reconciliation for the macOS chain (2026-09-10)

Revision 9 changes no scope, no Requirement, no Acceptance Scenario, no platform disposition, no
dependency, no status, no hardware criterion and no design text, and it does not approve r6–r8 or
itself; the maintainer's merge of this PR is the attestation. It rewrites the Allowed paths of
`TASK-XPA-012..018` at the granularity of the modules their deliverables live in.

1. **Why.** `TASK-XPA-003` needed one implementation PR (#1833) and five scope PRs in a day
   (#1828 packaging scripts, #1829 HDC host lifecycle and rollback smoke, #1830 read projections,
   #1831 refusal proofs, #1834 pbxproj registration). `scripts/check_pr_paths.py` reads Allowed
   paths from the base tree only, which is right, so every adjacent file a task discovers costs a
   maintainer round trip and paused the executor at the first gap. Paths written file by file at
   proposal time cannot foresee packaging, test registration or a provider host file.
2. **What moved, checked against the tree.** 012: `ArkDeckWorkflows/**` (the store consumers
   `RuntimeSessionStorageStore`, `RuntimeHistoryFilterStore`, display names,
   `RuntimeTraceCacheApplicationFacade`, storage policy live there, not in the daemon targets),
   `ArkDeckBootstrap/**` (tool/bundle registry), `ArkDeckTraceAdapter/**`, `ArkDeckCore/**`;
   012–016: `Packages/ArkDeckKit/Tests/**`, `LaunchAgents/**`, `Distribution/macOS/**`,
   `ArkDeckAppUITests/**` and `ArkDeck.xcodeproj/project.pbxproj` for the rollback-drill smoke
   each cutover repeats (XPA-AC-9, r5); 014: `ArkDeckStorage/**` (owner hand-off and strict-reader
   oracle; formats frozen), `ArkDeckProcess/**`, `ArkDeckRuntime/**`; 015: the composition root,
   `ArkDeckCore/**`, `ArkDeckRuntime/**`; 016: `ArkDeckProcess/**` and `ArkDeckOpenHarmony/**`,
   which hold the process executor, the HDC provider and the supervisor observation the task
   ports; 017 and 018: `scripts/ci/plan.py`, `scripts/ci/test_plan.py`,
   `.github/workflows/swift-ci.yml` and `scripts/test_agent_pr_workflow.py` for the lane
   retirements, exactly as `TASK-XPA-002` r3/r5 granted them. Every addition carries a
   parenthetical stating the deliverable it serves; `Forbidden paths` are unchanged and keep the
   narrowing for reviewers (`ArkDeckStorage/**` stays forbidden for 012 and 013, `user_version`
   bumps for 014, `Packages/**` for 025).
3. **Boundary.** Wider paths are not wider scope: each task's Deliverables, Verification and stop
   conditions are unchanged, and a security-kernel exception (admission, capability, recovery or
   storage semantics outside a task's stated deliverable) still needs its own scope supplement
   PR. `TASK-XPA-003`'s live supplements stand. `TASK-XPA-019` and `TASK-XPA-025` already list
   their modules and are untouched.
4. **Companion.** What reconnaissance cannot foresee is handled by
   [CHG-2026-076](../chg-2026-076-declared-scope-extension/proposal.md), which lets a PR declare an
   adjacent-path extension in band under bounded, reviewed conditions.

## Revision 11 — Golden Journey milestones, tiered parity, four lanes (2026-09-14)

Revision 11 changes no scope, no Requirement, no Acceptance Scenario, no platform disposition, no
Core baseline, no safety invariant and no hardware criterion, and it does not approve r6–r10 or
itself; the maintainer's merge of this PR is the attestation of the rulings it records. It is an
acceleration review of the macOS chain measured on `main` `6cf99fb6` (#1905).

1. **Measured state.** Since the Rust tree appeared (#1768, 2026-09-08) 65 PRs have merged and
   the `.rs` tree grew from 0 to 2.84 MB (`.py` harnesses 0.43 MB); on 2026-09-13/14 a slice
   merged every 50–90 minutes. Against the chain's own sizing (013, 014, 015, 016, 017, 018,
   019 = L, 025 = M; 30–59 engineer-weeks) that pace is five to ten times the plan. Yet the
   distance to G5 is unchanged in the units that matter: the isolated Rust owner answers 54 of
   the 105 control methods natively while the installed facade serves 3 locally; 1 of the 30
   Catalog operations (`analyzer.extract-crash-signature@1`, one hostOnly step) runs in Rust;
   GJ-1..5 on the pure Rust daemon 0/5; App facades on ClientKit 0/13; Swift targets deleted
   0/6. In the last three engine slices recorded oracle fixtures were 44–60 % of the added lines
   and Rust product code 16–30 %; of the last 18 PRs, 10 advanced the port and 8 repaired locks,
   timing or CI cost.
2. **Ruling: milestones are Golden Journeys on the isolated Rust daemon.** M1 GJ-1
   (`observe.device@1`, `capture.diagnostics@1`, `agent.run/status/list/resume/abandon` with
   HAR, `human-action.*`, `target.adopt/availability`, `runtime.hdc.status/restart/impact-preview`,
   the restart carry-over of design §G.4); M2 GJ-2/3 (`artifact.import.commit` and private
   publication, capability mint/reserve/consume for `deviceMutation` admission, `debug.hap@1`,
   `debug.*`, `deploy.native-library.app-owned@1` with rollback, `capability.*`,
   `cleanupDebt.*`); M3 GJ-5 (the 13 `workspace.*` operations and `workspace.preset/project.*`
   with the registered toolchain, hap-sign-tool and Keychain `SecItem*`); M4 GJ-4 (the ArkForge
   lane through `arkforge-client`, `flash.*`, Rockchip binding and live-mode probes, the DEC-016
   recovery epoch); M5 the one-shot cutover and retirement of TASK-XPA-017 after the clients
   detach (TASK-XPA-018/019) and the performance lanes measure Rust (TASK-XPA-025). Each
   milestone is proven first on the isolated root against `ArkDeckFakeHDCFixture`, then
   headless on the DAYU200 (`REAL_DEVICE_PASS`, assumption A4 unchanged). The next TASK-XPA-014
   slice is `observe.device@1` end to end (SPK-7), not a further analyzer lane and not the
   capability store in isolation. The three analyzers on no Golden Journey
   (`analyze-trace`, `summarize-trace`, `summarize-hilog`) are delivered after M4; G5's "no
   regression" still requires them.
3. **Ruling: parity is tiered (interpretation of XPA-AC-1 and XPA-AC-3 under r10).** T0
   byte-equal: wire schemas and the envelope; digests and reference identity (plan digest,
   Artifact digests, canonical JSON/CBOR, receipt seals); the durable formats that are read
   after the cutover because the installed state holds real intent, outcome, capability and
   evidence (journal, `runtime_job` index, `job-record.json`, Session manifest and audit,
   capability ledger, Artifact index, recovery manifests). T1 semantically equal: state
   transitions, error codes, refusal conditions, zero-dispatch proofs (`details.phase`,
   `newDispatchCount`), next actions, evidence precedence. T2 free: `message` text and Swift
   debug renderings (`spec/control/methods/*.json` constrain codes and shapes, never text),
   timestamp precision beyond the schema, logs, incidental side-effect files
   (`.payload-verification-v1.json`, empty directories). Oracles record T0 files only; T1 is
   compared by code, shape and transition sequence; no new Foundation or ICU emulation is
   written for T2 output. XPA-AC-1's "zero differences in current product contract, safety and
   digest/reference identity" and XPA-AC-3's "byte-equal accepted frames" are read with these
   tiers; the rows themselves are unchanged.
4. **Ruling: the installed store-by-store composition is withdrawn.** #1888 moved three History
   filter methods into the facade and its own record shows the other stores cannot follow while
   the Swift engine consumes them (Session output and storage policy, Trace cache census,
   Bootstrap selection, Target bindings); the r10 route C already makes activation one event
   after the consumers detach. The History slice stays as delivered; every other owner is
   activated once at M5 through the design §G.4 preflight, with a snapshot digest of the old
   state directory and the facade bundle retained one cycle as rollback. Dual-owner lock
   coordination stops being a deliverable.
5. **Ruling: TASK-XPA-015, 016, 019 and 025 are `ready`** on their interface dependencies —
   the contract, the isolated Rust daemon as delivered, the recorded fixtures and the spike
   that precedes each — not on TASK-XPA-014 `done`. TASK-XPA-019 is on the critical path of
   M5 because the App's NSXPC transport cannot reach the Rust daemon; the DAG edges
   XPA-014 → XPA-015 → XPA-016, XPA-014 → XPA-019 and XPA-014 → XPA-025 become "acceptance
   only". Their readiness pins are instantiated in this revision. Four lanes run in parallel
   worktrees: A engine and device path (014, 013), B platform executor (016), C clients (019,
   018), D providers, ArkForge lane and performance (015, the ArkForge part of 017, 025); file
   ownership and the shared-file rules are in design §G.1 r11.
6. **Spikes SPK-6..11** (design §J.3) precede the lanes, each at most one day, each recording a
   go/no-go fact and a reusable library under `evidence/runs/<task>/`: SPK-6 the HDC process
   executor (PTY secret exchange, persistent shell channel, libproc observation, `/.vol`
   launch); SPK-7 `observe.device@1` end to end on the isolated daemon; SPK-8 the ClientKit
   `xpc_connection` transport and generator on the smallest facade; SPK-9 ArkForge Rust-to-Rust
   through `arkforge-client`; SPK-10 Keychain, DevEco password decoding and the signing tools;
   SPK-11 the performance harness and `arkdeck-soak` on the Rust daemon. If SPK-6, SPK-9 and
   SPK-10 pass, the executor sidecar of TASK-XPA-014 is never built.
7. **Decision package for design §L.1 item 13.** `evidence/adr-0009-decision-package-20260914.md` names the code that carries ADR-0009
   decisions 2 and 4 today, file and line, with the contract tests that pin each carrier, the
   Rust mirrors that already exist and the four symbols the ADR names that have no successor.
   The proposed ruling is to port the named carriers unchanged; recovery, `job.reconcile`,
   resumable Jobs and recovery epochs stay unported until the maintainer rules.
8. **Verification overhead.** The T0 oracles for M1 and M2 are recorded once in a Swift-only PR
   against the fake HDC fixture, so that the Rust slices that follow change no Swift file and
   the planner selects only the Rust lane; one corpus-replay harness over the recorded
   ControlFrames and the T0 fixtures replaces per-slice `check-<slice>.py` scripts; tests that
   spawn children keep their own binaries; oracles use no real-time budget below 30 s except
   the case that tests the timeout; corpus-count assertions are written `>=` the published
   count. `evidence/macos-remaining.md` carries a six-number dashboard — methods on the
   standalone Rust daemon, operations executable, Golden Journeys on Rust, App facades on
   ClientKit, CLI leaves on Rust, Swift targets deleted — updated on every merge.
9. **Proposed rulings attested by this merge**, recorded in design §L.1: item 7, the Swift CLI
   retires with M5 and the compatibility leaves are tombstoned per CLI spec §12; item 19 (new),
   the parity tiers above; item 14, a daily one-hour DAYU200 window once SPK-7 passes, GJ-4
   windows still on an explicit go. Item 13 is not ruled here; the decision package asks for it.
10. **Design re-pin.** Sections A (item 5), G.1 (r11 subsection), J.2 (four edges), J.3
    (SPK-6..11), J.4 (rows 012, 014, 015, 016, 019, 025), J.5 (r11 entry) and L.1 (items 7, 13,
    14, 19) changed; nothing else. `docs/design/cross-platform/macos-chain-agent-prompt.md` is
    re-issued at version 2026-09-14 for the executing agents.

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
  - Per-method typed schemas derived from the post-SVC single-v1 protocol for both platforms; no multi-version protocol publication.
- Out of scope:
  - Any change to Core Requirements, Acceptance Scenarios, Safety invariants, `Catalog/`
    operations, provider IDs or destructive admission policy.
  - Linux delivery (profile stays `planned`).
  - Trace Viewer parity on Windows beyond capture/inspect/export (maintainer decision 5).
- Observable behaviour before/after:
  - macOS: no observable change until each cutover task; each cutover re-passes GJ-1..5 headless on
    the current digest before it ships.
  - Windows: from `NOT_STARTED` to a real `arkdeck doctor` / `device candidates` / `target adopt` /
    `observe.device@1` / `capture.diagnostics@1` walking skeleton, then GJ-2..5 — after the macOS
    side is complete (r8, design §J.5 gate G5).

## Scope (Requirements / AC)

- Requirements: none edited. Implemented unchanged on both platforms: `workflow-journal-recovery`
  (REQ-JOB-001, REQ-JOB-006, REQ-WF-004), `device-targeting-auth`, `session-artifact-storage`,
  `toolchain-hdc-server` (REQ-HDC-006, REQ-HDC-009), `flashing` (REQ-FLASH-007/015/016/017/018),
  `debug-workbench`, `ui-dump`, `trace`, `desktop-ux-observability` (REQ-UX-001..007,
  REQ-DIAG-001/002, REQ-I18N-001).
- Acceptance: the current CORE-CONFORMANCE suite (121 scenarios) becomes a target obligation on
  Windows; change-level acceptance `XPA-AC-1..10` is defined in `verification.md`.
- Contracts/schemas: XPA-001 derives per-method schemas and language-neutral `spec/` assets from
  the final single-v1 control and durable contracts delivered by TASK-SVC-001..004. It does not
  publish 2.1.0, freeze pre-SVC 1.x frames or supplement the old journal generation union. The
  pre-release compatibility removal belongs to CHG-2026-075; this change preserves its outcome.
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
- Data/schema compatibility: Rust reads and writes the exact post-SVC Swift single-v1 durable
  formats, including SQLite layout, journal/manifest, job records, artifact indexes, capability
  ledger, recovery and current evidence. No schema/`user_version` drift or added durable field is
  permitted during the Swift/Rust owner migration. This freeze begins after SVC-001..004, so it
  cannot prevent that prerequisite cleanup or revive old decode-only generations. Raw historical
  evidence and isolated development stores remain under CHG-2026-075's preservation policy;
  `outcomeUnknown` lanes in the accepted baseline retain their outcome and never replay.
- Platform impact: macOS `needsReverification` (already) and must re-verify on the Rust daemon;
  Windows starts W0; Linux remains `planned` with no support claim.
- Rollback/migration: LaunchAgent points back to the post-SVC Swift daemon of the same release; state directory snapshot before
  each cutover; Windows has no installed base to migrate.
- Privacy: no change to POL-PRIVACY-001; secrets never enter argv/env/receipts on either platform;
  Windows credentials go to Credential Manager (DPAPI) with the same redaction rules.

## Maintainer decisions requested

See section L.1 of the design document. The blocking ones for starting work are: (1) approve this
change and the `Core strategy` value change; (2) Rust dependency policy (vetted allowlist vs
zero-dependency); (3) control-plane peer hardening; (4) Golden Journey re-pass rule on runtime
replacement; (9) Windows support tuple (Windows 11 x64 + ARM64); (10) MSIX packaged + self-contained
Windows App SDK; (13) ADR-0009 open ruling before recovery is ported; (17) the same-user trust
boundary statement (r5); (18) the macOS-first order, ruled on 2026-09-09 and recorded in r8,
effective on its merge; (r11) item 19 the parity tiers, item 7 the Swift CLI retirement with M5 and
item 14 the device window cadence, recorded in r11 and effective on its merge, while item 13 waits for
the ruling requested by `evidence/adr-0009-decision-package-20260914.md`.

## Historical revisions 2–5

The following entries preserve review history. Their old protocol publication, compatibility
and generation-preservation targets are superseded by the r6 dependency boundary above.

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

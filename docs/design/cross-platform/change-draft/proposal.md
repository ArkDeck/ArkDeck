---
id: CHG-2026-074-shared-rust-runtime-core
revision: 0
status: proposed
class: platform
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# CHG-2026-074 — Shared Rust runtime core with native SwiftUI and WinUI 3 clients

> **Draft, not a change package.** This file lives under `docs/design/cross-platform/change-draft/`
> and has no governance effect. It becomes a change only when a maintainer moves it to
> `openspec/changes/chg-2026-074-shared-rust-runtime-core/` (with an `evidence/` directory) and
> merges that approval PR. Nothing here approves itself, and no `TASK-XPA-*` may be declared by an
> implementation PR before that merge (`scripts/check_pr_paths.py` refuses head-only tasks).

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
> `docs/design/cross-platform/rust-core-cross-platform-architecture.md` (sections A–L). This
> proposal only carries the governance-facing summary.

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
4. **Why the scope is finite and reversible.** The migration is a strangler: a Rust control-plane
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
  `user_version` or schema bump before the Swift daemon is retired; legacy generations stay
  decode-only. `outcomeUnknown` lanes are carried over unchanged and never replayed
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
Windows App SDK; (13) ADR-0009 open ruling before recovery is ported.

## Compatibility note

`PRODUCT-LOOP.md:99-116` forbids new proposals during the product-loop phase except for the
safety kernel and the four repository approval categories. This draft is filed because
`core-portability.md:30` makes an architecture/platform change the only lawful carrier for a shared
runtime, and because `openspec/platforms/windows/profile.md:15-21` reserves the Windows engineering
decisions for a Windows platform change/ADR. It is delivered as a draft under `docs/design/` so that
no change directory, task or status exists before the maintainer decides.

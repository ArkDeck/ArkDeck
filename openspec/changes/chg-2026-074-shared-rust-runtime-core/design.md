# Design — CHG-2026-074 shared Rust runtime core

## Design input pin

The complete design (sections A–L: executive recommendation, facts and conflicts with
`path:line` citations, decision matrix, target architecture and diagrams, crate/port mapping,
API/IPC/FFI/contracts and data ownership, persistence migration, UX parity contract, performance
SLO and benchmark plan, task DAG, risk register, maintainer decisions) is:

```yaml pins
- path: docs/design/cross-platform/rust-core-cross-platform-architecture.md
  blob: fd93c408f99b8cd5126f5fd7b380a3b4c09d706d
  sha256: 42b1608a2765d88e4512bc86e91660c907e3be53f45ad5bcbf3e98bbe4cd8973
```

Later revisions of the design must re-pin here in the same PR; the pinned blob is what the
maintainer reviews; r6 is a proposed revision and does not approve itself. Revision 2 re-pinned
it for the section I.2 budget finalisation described in
`proposal.md`. Revision 3 re-pins it for the design review repairs described there: sections A
(item 5), F.2, G.2, G.4, G.5, J.2, J.4, J.5 and K changed; sections B–E, H, I and L are unchanged.
Revision 4 re-pinned it for the `TASK-XPA-001` Allowed-paths correction described there: only the
section J.4 path line of that task changed. Revision 5 re-pins it for the second review round:
sections F.2, G.1, G.4, G.5, J.2, J.4, J.5, K and L.1 (item 17) changed.
Revision 6 re-pins the dependency correction: CHG-2026-075's TASK-SVC-001..004 first deliver
one current v1 contract; XPA-001 then publishes its per-method schemas for Rust. The target
contract, storage, ABI, parity, DAG and rollout sections use that post-SVC baseline. Old scan
facts and revision history remain evidence of the earlier design, not implementation targets.
Revision 7 re-pins it for the SPK-2 outcome: the section F.2 identity row, the section J.3 SPK-2
row, risk R3 in section K, one section L open-items row and the notes on items 3 and 6 of section
L.1 changed; nothing else.
Revision 8 re-pins it for the macOS-first sequencing: sections A (item 6), G.1, J.2, J.4 (rows
002, 003, 004, 005, 014, 018, 024), J.5 and L.1 (item 18) changed; nothing else.
Revision 9 changes no design text and keeps the pin above; its Allowed-path reconciliation lives
in `tasks.md`, and the §J.4 rows of XPA-012..025 carry no path lines.

The 2026-09-06 design refresh is re-pinned for review against checkout
`d3d5c32c60cf60c96c64c50f8f1ab52b4d444cfa`. It updates current single-v1 facts,
the schema/corpus handoff and task progress, corrects the performance discussion
to the committed SPK-1 JSON and actual capture/compare/soak implementation, and
adds sections H.5/H.6 (reproducible Windows native development and UI automation)
and I.4 (proposed whole-product resource measurements). Those sections guide the
existing client and packaging tasks; they do not install tooling, add a Runtime
method, change Task status or Allowed paths, approve a new budget, or establish
Windows support. Historical measurements remain historical. This refresh does
not change the proposal's approval status or its existing acceptance criteria.

## Single-v1 prerequisite

[CHG-2026-075](../chg-2026-075-single-v1-contracts/proposal.md) owns removal of the pre-release
protocol/document generations and development compatibility. TASK-XPA-001 depends on
TASK-SVC-001..004 and records their final Swift commit, schemas and corpus. Every current-byte
freeze, strict-decoder oracle and same-release rollback below starts from that single-v1
baseline. No XPA task restores legacy negotiation/readers/authority. SVC-005 remains the
single-v1 release acceptance; XPA tasks add their separate cross-platform/migration evidence.

Current implementation: SVC-001..004 are recorded as done; the registry contains
96 methods at `1.0.0`, with matching per-method schemas and 96 recorded corpus files.
The [SVC-005 baseline](../chg-2026-075-single-v1-contracts/evidence/runs/TASK-SVC-005/single-v1-baseline.md)
provides the complete commit/blob/directory-digest handoff at `371cd9d2`; those
contract assets are unchanged at this refresh's checkout. XPA-001 remains
in-progress pending its headless re-pass and SVC-005 remains ready. The corpus
only covers recorded paths; it is not an exhaustive failure-state specification.
Clients preserve the current `contractIdentity` field and same-connection health
verification, with revalidation after reconnect and no replay of a lost reply.

## Decision

One shared Rust runtime, `arkdeck-agentd`, owns admission, Job/journal/recovery, capability,
artifact, provider lowering and process execution on macOS and Windows. Native clients consume it
over local IPC only: SwiftUI over the launchd Mach service (XPC C API) and the user-private Unix
domain socket; WinUI 3 and the CLI over a user-private named pipe. An optional
`arkdeck-contract-ffi` static library exposes pure computation (canonical JSON/CBOR, digests,
document validation, offline decoding, Viewer indexing) with no authority, I/O or side effects.

```text
Human / external agent / App click
  → arkdeck-control (transport-free handler; UDS 0600 + peer euid, Mach service + peer
    code-signing requirement, named pipe + logon-SID DACL + client SID/elevation check +
    client-side pipe-owner check and, where the server PID is obtainable, daemon-instance
    check; origin line from the façade during migration;
    4 MiB frames; closed method table; per-method typed schema)
  → arkdeck-runtime (published admission order: descriptor → provider registered → fresh
    target facts → full materialisation → lowering coverage → plan digest → capability)
  → arkdeck-durable (journal intent-before-effect with the same fsync discipline, post-SVC SQLite v1,
    capability ledger, recovery epochs; no schema bump and no added field before the Swift
    daemon is retired — the Swift decoders reject unknown keys)
  → provider crates (hdc / workspace / analyzer / arkforge) → arkdeck-platform (posix_spawn with
    inode-bound path or CreateProcessW with handle-bound verification; argv arrays only)
  → hdc / arkforged / git / hvigor / hap-sign-tool → device
```

## Crate graph and dependency rules

`arkdeck-contract` (pure) → `arkdeck-durable` → `arkdeck-runtime` → `arkdeck-control` →
`arkdeck-agentd`; `arkdeck-platform` is the only crate allowed `unsafe`/`extern "C"`/`libc`/
`windows-sys`; provider crates never depend on each other; `arkdeck-client` → `arkdeck-cli`;
`arkdeck-contract-ffi` depends only on `arkdeck-contract`; `arkdeck-conformance` generates and
replays fixtures. Structural tests in Rust mirror `ArchitectureBoundaryContractTests`; the Swift
App may import only `ArkDeckClientKit`, `ArkDeckTraceAdapter`, ArkTrace and system frameworks.

## Invariants preserved (mapping in design §D.4)

UI never executes processes, HDC, shell or device effects; callers submit only published operation
references, typed inputs, target/artifact/capability references and budgets; only the protected
Runtime mints, reserves and consumes `RuntimeCapability`; `connectKey` is addressing only and every
mutation re-checks stable identity and binding revision; intent-before-effect, durable journal and
never-replay-unknown are unchanged; raw artifacts are immutable, local by default and exported
explicitly; execute / plan-only / simulated stay distinct; every durable store has exactly one owner
process at any time; Rust panics abort the daemon (restart recovery) and are caught at the FFI
boundary; shadow/differential compares only pure computation, read-only projections and plan-only
materialisation.

## Migration order (design §G)

1. After SVC-001..004, XPA-001 publishes per-method typed schemas; the Rust contract kernel
   proves byte-for-byte equality with the pinned post-SVC Swift oracle per current asset.
2. Rust control-plane façade owns UDS/Mach service and forwards to the Swift daemon on a private
   socket; peer hardening; the Swift daemon's Mach service speaks the same raw libxpc frames so
   the App and daemon of one release roll back together.
3. Read-only shadow validation, then durable stores move owner one at a time: host-only stores →
   artifact store → admission/job/capability/recovery, with the Swift engine reduced to an executor
   sidecar under per-step typed permits.
4. Providers move family by family (analyzer/workspace → HDC → ArkForge lane); the Rust CLI
   reaches full fixture parity, the App moves to `ArkDeckClientKit` and the performance lanes
   measure the Rust daemon and a Rust soak fixture; only then are the Swift daemon, engine and
   storage targets retired (r3/r5: nothing may still link or build a deleted target).
5. Windows starts from the thinnest real GJ-1 walking skeleton and proceeds to GJ-2..5; the WinUI
   3 client follows the same daemon projections.

Every macOS step is releasable and rolls back by pointing the LaunchAgent at the Swift daemon of
the same release after SVC, which reads Rust-written bytes with the pinned strict decoders; cutover
preflight refuses in-flight jobs and pending intents while parked `waitingForRecovery` jobs and
`outcomeUnknown` lanes are carried across owners unchanged.

## Alternatives rejected (design §C)

- In-process Rust `cdylib` runtime: puts authority into every client process, breaks single-writer
  ownership and turns Rust aborts into UI crashes.
- Cross-compiled Swift daemon: rewrites every Darwin-bound port anyway without a shared core.
- Independent C#/.NET runtime (the current `core-portability.md` decision): two authority
  implementations with only vector-level parity; ArkForge's AFD-0005 already showed that this
  drifts.

## Decisions the maintainer must make before work starts

Design §L.1 items 1–4, 9–11 and 13 (architecture reversal and `Core strategy` value, Rust
dependency policy, control-plane peer hardening, Golden Journey re-pass rule on runtime
replacement, Windows support tuple, packaging, daemon lifecycle, ADR-0009 open ruling) and item
17 (same-user trust boundary, r5). Items 5–8, 12 and 14 may be decided during delivery.

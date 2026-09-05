# Design — CHG-2026-074 shared Rust runtime core

## Design input pin

The complete design (sections A–L: executive recommendation, facts and conflicts with
`path:line` citations, decision matrix, target architecture and diagrams, crate/port mapping,
API/IPC/FFI/contracts and data ownership, persistence migration, UX parity contract, performance
SLO and benchmark plan, task DAG, risk register, maintainer decisions) is:

```yaml pins
- path: docs/design/cross-platform/rust-core-cross-platform-architecture.md
  blob: 6294cfc3def9eabe13fe879779cf6817b167fd98
  sha256: 65d56982fcd47fea1029ff41a4be13bb97dd3a765d60853bf1c13d44cec40b58
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

## Single-v1 prerequisite

[CHG-2026-075](../chg-2026-075-single-v1-contracts/proposal.md) owns removal of the pre-release
protocol/document generations and development compatibility. TASK-XPA-001 depends on
TASK-SVC-001..004 and records their final Swift commit, schemas and corpus. Every current-byte
freeze, strict-decoder oracle and same-release rollback below starts from that single-v1
baseline. No XPA task restores legacy negotiation/readers/authority. SVC-005 remains the
single-v1 release acceptance; XPA tasks add their separate cross-platform/migration evidence.

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

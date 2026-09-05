# Design — CHG-2026-074 shared Rust runtime core

## Design input pin

The complete design (sections A–L: executive recommendation, facts and conflicts with
`path:line` citations, decision matrix, target architecture and diagrams, crate/port mapping,
API/IPC/FFI/versioning and data ownership, persistence migration, UX parity contract, performance
SLO and benchmark plan, task DAG, risk register, maintainer decisions) is:

```yaml pins
- path: docs/design/cross-platform/rust-core-cross-platform-architecture.md
  blob: 27961bc489dfe1079e093779279159d41d86e052
  sha256: 638b919f97043a55eea38934544f7cf1a76578475b81e8caa4dfa793148fda3c
```

Later revisions of the design must re-pin here in the same PR; the pinned blob is what the
maintainer approved. Revision 2 re-pinned it for the section I.2 budget finalisation described in
`proposal.md`. Revision 3 re-pins it for the design review repairs described there: sections A
(item 5), F.2, G.2, G.4, G.5, J.2, J.4, J.5 and K changed; sections B–E, H, I and L are unchanged.

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
    client-side pipe-owner check; origin line from the façade during migration;
    4 MiB frames; closed method table; per-method typed schema)
  → arkdeck-runtime (published admission order: descriptor → provider registered → fresh
    target facts → full materialisation → lowering coverage → plan digest → capability)
  → arkdeck-durable (journal intent-before-effect with the same fsync discipline, SQLite v2,
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

1. Rust contract kernel with byte-for-byte differential tests (Swift stays the oracle for legacy
   bytes until Rust proves equality per asset).
2. Rust control-plane façade owns UDS/Mach service and forwards to the Swift daemon on a private
   socket; peer hardening.
3. Read-only shadow validation, then durable stores move owner one at a time: host-only stores →
   artifact store → admission/job/capability/recovery, with the Swift engine reduced to an executor
   sidecar under per-step typed permits.
4. Providers move family by family (analyzer/workspace → HDC → ArkForge lane); the Rust CLI
   reaches full fixture parity and the App moves to `ArkDeckClientKit`; only then are the Swift
   daemon, engine and storage targets retired (r3: nothing may still link a deleted target).
5. Windows starts from the thinnest real GJ-1 walking skeleton and proceeds to GJ-2..5; the WinUI
   3 client follows the same daemon projections.

Every macOS step is releasable and rolls back by pointing the LaunchAgent at the Swift daemon,
which reads Rust-written bytes with its current strict decoders; cutover preflight refuses active
jobs and pending intents; `outcomeUnknown` lanes are carried across owners unchanged.

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
replacement, Windows support tuple, packaging, daemon lifecycle, ADR-0009 open ruling). Items
5–8, 12 and 14 may be decided during delivery.

# The ArkForge lane's control performer (TASK-XPA-017, F6 S7)

This slice ports Swift's `ArkForgeControlPerformer` to `arkdeck-hoststore`:
the semantic control actions `arkforged` asks for, performed with the HDC
actions ArkDeck kept. It implements S3's `ControlPerformer`, and runs every
action through S6's one Rockchip action host, the dispatcher's
`action_host`.

Nothing composes it yet; the lane host (S4) and the daemon (S8) will.

Developed on S6's branch head `6130177ca`, then rebased onto `0769edba4`:
S6 as merged (#2260), with #2259 and #2253, which change none of this
slice's files. The checks marked "after the rebase" were run again. No
contract input, Catalog or `tasks.md` changes. No device, and nothing here is
device evidence.

## What is ported (`control_performer.rs`)

- **`ControlBinding`**: Swift's `Binding`, the descriptor ingredients (Job,
  Target, revision, connect key, stable identity, USB topology, measured
  `arkforged`).
  - Each action gets a fresh descriptor, materialized by the catalog for
    that action alone, because the host validates each action's own
    identifier and digest.
  - The record step id is `<step>-mc-<first 12 hex of SHA-256(request
    id)>-a<index>`. A repeat of the same control attempt therefore replays
    its records, and a new attempt asks the device again.
- **`enterUpdater`**:
  1. ArkForge's dual-source Loader observation is tried first, with the
     binding's topology. If the board is already there, the observation is
     accepted with the Loader facts, and no action runs.
  2. Otherwise five actions run in the port's order: observe HDC-normal,
     enter Loader, wait for the disconnect, wait for the Loader, rebind.
  3. The observation reports what was seen before a failure. The disconnect
     counts only once its wait succeeded; nothing is accepted without the
     rebind.
  4. The facts come from the rebind.
- **`rebootToNormal`** is the bound reconnect. Its expectation is in the HDC
  alias namespace: the connect key, that key's digest, and the binding's
  topology.
- **The fact reads** are the bound build verification. The expected model
  and build come from the daemon's request, never from this side; a repeated
  key keeps its first value, as Swift's dictionary does.
- **The receipt facts** are selected rather than filtered:
  - `mode`, `stableIdentitySHA256` and `usbTopology` come from the summary;
  - the Loader identity maps onto `stableIdentitySHA256`, and implies
    `mode: Loader`;
  - `model` and `firmware` map onto the device's property names.
- **A failure reason** is Swift's `"\(error)"` of the host's failure: the
  shared `described` for a dispatch failure, or the error's own description
  otherwise.
- **The request types.** `arkdeck-provider-arkforge` re-exports ArkForge's
  `ManagedControlRequest`, `ManagedControlAction` and `KeyValue` from
  `managed_control`. The performer lives with the Rockchip host, and only
  the lane's provider depends on ArkForge (`check-readonly.py`); no manifest
  changes.

### Swift's text, measured

Swift's tests do not pin how `"\(error)"` prints a
`confirmedNotExecutedWithDiagnostic`, and the failure reason carries it to
`arkforged`. It was measured in a Swift window granted by the hub on
2026-09-26:

- **What was compiled.** `RuntimeDispatchFailure`, `RockchipFlashRuntimeDiagnostic`
  and `RockchipFlashExecutionError`, copied verbatim as top-level
  declarations, as `ArkDeckWorkflows` declares them. The repository adds no
  description extension to any of them.
- **How.** `swiftc -module-name ArkDeckWorkflows` (Swift 6.4,
  swiftlang-6.4.0.34.1); no package build.
- **What it printed:**
  - `confirmedNotExecutedWithDiagnostic("…", diagnostic:
    ArkDeckWorkflows.RockchipFlashRuntimeDiagnostic.enterLoaderHDCNoCleanReceipt)`;
  - Swift's string escapes;
  - `admissionRejected("…")` unchanged by `LocalizedError`.
- **Where it is pinned.** The five lines are the test's golden
  (`SWIFT_RENDERED`), and they match S6's rendering exactly.
- **Not run:** the same print on the package's own types, which needs a
  package build.

### Carried from Swift

`rebootToNormal`'s bound-reconnect summary carries only `usbTopology` among
the facts the port requires, so the port refuses its receipt. Swift does the
same, and this port keeps it; it is finding F5 of the F6 port map, for the
maintainer. A test pins it. The path is unreachable today: ArkForge's
DAYU200 provider asks only for `enterUpdater` and `readBuildFacts`.

ArkForge's Rust action enum has no `unspecified` case. An action this build
does not know fails to decode upstream, in the session (S3), and Swift's
`PerformerError.unsupported` has nothing to refuse here.

## Tests

- **8 tests**, over the real durable host with its validation and record
  store, and a recording executor beneath it:
  - **All four of Swift's `ArkForgeControlPerformerContractTests`:**
    - the five actions through the validating host, each under its own
      identifier, digest and step id;
    - the already-Loader fast path runs nothing;
    - a repeated request replays, and a fresh one does not;
    - the accepted observation is a receipt the daemon takes, its evidence
      the canonical facts digest.
  - A failure at each index reports what was observed before it.
  - Every failure reason is Swift's measured text.
  - The reboot's expectation and its refused receipt.
  - A read's expectations come from the request.
- **Mutations.** Nine hand mutations, each killed:
  - one step id for every action;
  - the request id not digested;
  - the disconnect claimed early;
  - accepted without the rebind;
  - a bare failure reason;
  - the fast path skipped;
  - the Loader mode not mapped;
  - the last value of a repeated key;
  - the expectation by the Loader identity.

## Verification

**Local targeted checks.** Main worktree, target
`/private/tmp/arkdeck-m4-rust-target` (`-win` and `-linux` for the cross
checks), `CARGO_BUILD_JOBS=2`. Logs are under the session's scratchpad
`s7-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings`: `arkdeck-provider-arkforge`, `-hoststore`, and their dependents `-agentd`, `-soak` | exit 0 (`clippy.log`) |
| the same for Windows and Linux: `arkdeck-provider-arkforge` | exit 0 each (`clippy-windows.log`, `clippy-linux.log`) |
| `cargo test -p arkdeck-provider-arkforge` | exit 0: 88 passed in 5 test binaries (`test-provider-arkforge.log`) |
| `cargo test -p arkdeck-hoststore` | exit 0: 712 passed, 18 ignored, in 90 test binaries, the 8 new ones among them (`test-hoststore.log`) |
| `cargo test -p arkdeck-agentd` | exit 0: 191 passed in 22 test binaries (`test-agentd.log`) |
| the nine mutations | each caught as above; the restored tree passes (`mutations.log`) |
| `sh scripts/check-sdd.sh` | exit 0 (`check-sdd.log`) |
| after the rebase: fmt; clippy `arkdeck-provider-arkforge`, `-hoststore`, `-agentd`, `-soak`; `-p arkdeck-hoststore --lib control_performer`, `--lib rockchip_`; check-sdd | exit 0 each: 8 and 37 passed (`rebased-*.log`) |

Not run:

- **`check-readonly.py`.** No manifest changed; the re-export keeps the one
  edge to ArkForge where it was.
- **`arkdeck-soak` tests.** Nothing of it changed; its clippy above compiles
  it.
- **Swift tests.** Nothing of Swift changed. The single `swiftc` compile
  above is the only Swift that ran.
- **`generate-contract.py --check`.** No contract input changed.

**CI.** Pending.

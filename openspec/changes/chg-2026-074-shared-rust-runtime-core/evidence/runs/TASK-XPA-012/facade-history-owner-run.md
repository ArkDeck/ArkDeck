# Facade-owned History filter store (first installed-composition step)

2026-09-13. TASK-XPA-012 remains in progress. Base: protected main `a102a4aa`.
This slice moves the first host-only store's installed owner from the Swift
daemon to the paired Rust facade. It changes no durable format, method, schema
or CLI leaf, and activates nothing on this host by itself: the installed pair
changes only through the normal helper rebuild and `runtime service update`.
Every fixture below is disposable host data; nothing here is device evidence.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-012 |
| --- | --- | --- |
| Isolated Rust owners for History, Session, Trace cache, Bootstrap, Target (#1841–#1885); facade pair installed as the LaunchAgent program (XPA-003) | `arkdeck-facade` serves `history.filter.list/save/delete` from the paired authority's state directory and never forwards them; the Swift authority composed behind a facade no longer opens that store | Installed ownership of the Session, Trace cache, Bootstrap and Target stores (each still consumed by the Swift engine); tool selection writes; trace database preparation; GJ-1 headless re-pass |

## Behaviour

- Routing: after the existing structural validation, a frame whose method is in
  `facade_owners::LOCAL_METHODS` is answered by an in-process `Control` over the
  existing Rust `HistoryStore`; everything else takes the unchanged forwarding
  path. The same routing applies to the App's Mach door and the public UDS;
  all three methods are already on the App XPC allowlist without further
  gating (`AgentXPCEndpoint.admission`), so the App path is equivalent.
- State directory: the public socket's directory, which is the paired
  authority's `--state-dir` in development and Swift's installed default
  (`~/Library/Application Support/ArkDeck/Agentd`) in production. The file and
  lock names, JSON shape, generation CAS and atomic publication are those of
  the Rust owner merged in #1841; the frozen document is shared with Swift.
- Concurrency: requests inside the facade queue on one in-process guard, as the
  replaced Swift owner's blocking `flock` did; the Rust owner's lock stays
  non-blocking, so another process holding it gets `resourceConflict` and no
  write. The store is reopened per request, so an unsafe or replaced directory
  fails that request only (`recordUnreadable`, `phase: historyFilterOwner`,
  `newDispatchCount: 0`) and a repaired one needs no restart.
- Swift composition: `AgentFacadeHostOwnership.historyFilterStore` returns no
  store when an inherited facade pairing exists; `main.swift` uses it. The
  handler's existing nil-store branch refuses any stray History filter frame
  without touching the directory. A standalone Swift daemon, including the
  same-release rollback bundle, keeps its owner over the same file.
- Timestamps: the Rust owner writes whole-second UTC (`…:SSZ`); Swift wrote
  milliseconds. Both are inside `ISO8601Timestamps.parse`'s domain (shadow
  corpus, #1841) and the App decoder accepts any string for `updatedAtUtc`.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust unit tests (4 new) | `cargo test -p arkdeck-agentd` | 8 passed: local-only routing and restart, 8×16 concurrent reads all `ok`, foreign lock refused for list/save/delete with bytes unchanged, unsafe then repaired directory |
| Clippy, three targets | `cargo clippy --workspace --all-targets [--target x86_64-pc-windows-msvc \| x86_64-unknown-linux-gnu] -- -D warnings` | clean |
| Facade transport vs fixture authority | `ARKDECK_DAEMON_UNDER_TEST=rust/target/debug/arkdeck-agentd python3 rust/scripts/test-macos-facade.py` | 7 passed, including the new `test_history_filter_is_owned_here_and_never_forwarded` (list/save, restart, stale CAS, delete; the fixture authority records zero frames until the next forwarded `health`) |
| Real pair | `python3 rust/scripts/check-facade-host-owners.py` | PASS, 19 checks; see below |
| Swift contract tests | `run-swiftpm.sh test --filter 'AgentDaemonContractTests/testFacadeComposition\|AgentDaemonContractTests/testCLIHistoryFilter\|RuntimeHistoryFilterStoreContractTests\|AgentFacadeContractTests'` | 10 executed, 0 failures; the new test asserts no store under a pairing, a refusal for all three methods with no `history-filter.json`/`.history-filter.lock` created, and that the methods are on the App XPC allowlist |
| Forwarding regression, real pair | the same runner with `ARKDECK_DAEMON_UNDER_TEST=<new facade>` and `ARKDECK_SWIFT_DAEMON=<this tree's Swift daemon>`, filter `AgentFacadeContractTests\|AgentDaemonContractTests/testExternalDaemonSingleV1Contract` | 5 passed, 0 skipped: a forwarded `job.submit` whose reply is withheld survives facade death and Swift death without replay (one Job, idempotent resubmit), and the single-v1 refusal matrix still holds through the facade |

`test-macos-facade.py` previously pinned contract identity `8a662759…`; the
current identity is `1d7d101e…`, so its frames would have been refused before
reaching the fixture. It now derives the identity from this checkout's
`control-protocol.json` exactly as the other process harnesses do.

### Real pair (`check-facade-host-owners.py`)

The harness builds nothing; it runs `rust/target/debug/arkdeck-agentd` as the
facade over the SwiftPM debug `arkdeck-agentd` of this tree, with
`ARKDECK_CONTROL_FRAME_LOG` set so the Swift daemon's debug recorder logs every
frame its handler dispatches, and `CFFIXED_USER_HOME` inside the disposable
root so Swift composition never opens the installed Application Support tree
(verified: `HOME` alone does not redirect Foundation's Application Support
lookup; `CFFIXED_USER_HOME` does).

1. Pair: Rust CLI list (generation 1); Swift CLI save (2); Rust CLI reads it;
   Swift CLI stale save exits 65 `resourceConflict`; 32 concurrent raw lists
   all `ok`; a foreign `flock` on `.history-filter.lock` refuses a save and the
   document bytes are unchanged; forwarded `health` still answered. The Swift
   frame log holds 6 frames, all forwarded, and no `history.filter.*` frame.
2. Standalone Swift daemon over the same directory: its strict reader returns
   the Rust-written document (generation 2); its save publishes 3. Its frame
   log holds `history.filter.list` and `history.filter.save`: the positive
   control that the recorder sees these frames whenever Swift is the owner.
3. Pair again: the Rust owner reads the Swift-written document (generation 3);
   Rust CLI delete publishes 4; the Swift CLI reads the tombstone. The frame
   log holds 4 forwarded frames and no `history.filter.*` frame. No orphan
   `.part` file remains; the final document is the store schema at generation
   4 without a query.

Summary: `facade-history-owner-macos-20260913.json` in this directory.

## Not run, and why

- Installed activation and the App UI (History filter save from the App over
  XPC): they follow a helper rebuild from protected main and belong to the
  XPA-012 installed switch together with the GJ-1 re-pass. The App path uses
  the same routing as the UDS path and the unchanged Swift XPC allowlist.
  Read-only `runtime service status` (this tree's debug CLI) shows the
  installed program is still the 2026-09-10 facade pair (`arkdeck-facade`
  SHA-256 `f6c3dbf8…`, receipt 2026-09-10T07:17:32Z); its health answers this
  checkout's CLI with `contractMismatch`, so any installed check needs the
  helper rebuild from protected main in any case.
- GJ-1: DAYU200 is not attached to this host now (`ioreg -r -c IOUSBHostDevice`
  lists only a USB hub and a display adapter); host-only work continued.

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`
on commit `039188f7` (base `a102a4aa`), with `ARKDECK_PYTHON` on the SDD venv and the planner started
from a venv holding `PyYAML==6.0.3` and `jsonschema==4.26.0`. Log:
`/private/tmp/xpa012-facade-history-gate-20260913-r1.log`.

- Common checks: SDD (0 errors, 0 warnings), catalog generator, planner and agent-PR workflow tests,
  83 design-system tests.
- Swift full lane: `full-parallel` 2,646 tests exit 0, `full-process-identity-race` 1 test exit 0,
  `full-viewer-scale` 5 tests exit 0. The planner did not select an App build.
- Rust lane: `generate-contract.py --check` (no contract input changed), `cargo fmt --check`,
  warnings-denied Clippy, workspace tests, `check-contracts.py` with every candidate process harness
  passing (read-only, History, Session owner/resources/cleanup/export, Trace, Bundle and tool
  inventory/retirement, HDC registration), `cargo deny` and `cargo vet` (36 fully audited).
- Result: the log ends `gate exit=0`; SHA-256
  `d99eed92136c2746a9bd0b8e414fc22c31a23629c13cfdea18f6169e88a5a8c9`.

Addendum, same day: after that gate only `rust/scripts/check-contracts.py` (one added command) and
`rust/scripts/test-macos-facade.py` (default daemon path) changed, besides this record. The affected
Rust lane steps were re-run: `test_contract_checks.py` 33 tests OK; `test-macos-facade.py` without
`ARKDECK_DAEMON_UNDER_TEST` 7 tests OK; `check-contracts.py` passed both views, and its candidate view
ran `test-macos-facade.py` against the view's own build (7 tests OK). Log:
`/private/tmp/xpa012-facade-history-contracts-20260913-r2.log`, ends `contracts exit=0`, SHA-256
`25b8627ce56c469312c83ea821f6d7cd63a1f11ebb3fa0f883672611b473a57e`. The Swift and design-system lanes
were not repeated because no file they consume changed.

## Residuals

- `check-facade-host-owners.py` needs the SwiftPM daemon and CLI, which the Rust lane does not build,
  so it stays a manual real-pair check. `test-macos-facade.py` was never run by CI either, which is how
  its pinned identity went stale; after the gate above it was wired into `check-contracts.py`'s macOS
  candidate view (it now defaults to the view's own `target/debug/arkdeck-agentd`). See the addendum.
- The other host stores cannot follow this pattern until their Swift engine
  consumers are gone: Session output/storage policy (the engine publishes
  Sessions), Trace cache purge (needs the Job/Artifact census the Swift engine
  owns), Bootstrap (engine tool selection and workspace toolchains), Target
  bindings (engine execution routes). Candidate display names additionally
  need the Runtime observation snapshot the Swift daemon produces.

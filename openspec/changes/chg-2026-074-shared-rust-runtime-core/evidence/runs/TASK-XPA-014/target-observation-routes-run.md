# TASK-XPA-014 — the daemon's device observation and adoption routes (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `438434ef`, which carries #1957 (`9aea0419`)
and #1959 (`d021c926`), whose owner these routes compose. Every request
and answer here is synthetic host data over `/bin/sh` scripts; nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The Target adoption oracle and its control shapes (#1957) and the hoststore Target observation owner (#1959) | The control layer hands a valid `following` and `target.adopt` to the host; agentd composes the owner over the development HDC, a USB relation source and the Target store; `agentd/src/target_observation_control.rs` | A development-only USB relation source and the fixture's real-daemon replay (A2b-2); candidate display names through the owner, once Swift's coordinator is recorded for them; `target.availability`; the HAR path's raise and resume |

## What changes

- **Control** (`arkdeck-control`):
  - `HostServices::observations_following(reference)` answers `device.observations` that follows a
    valid reference. Its default keeps today's answer: `resourceConflict` "the referenced
    observation is not retained by this Runtime", carrying the reference.
  - `HostServices::target_adopt(params)` answers `target.adopt`. Its default keeps the foundation's
    `rejected`.
  - An invalid `following`, or any other key, is still refused before the host.
  - `observation_refusal` is public, so a host refuses as the control layer does.
- **The daemon** (`arkdeck-agentd`, macOS):
  - The host holds a `TargetObservations` owner and a USB relation source. The source is
    `NoUsbRelations`, which reads none, unless a test composes one (`with_usb_relations`).
  - When the host has both the development HDC and the Target store, `device.observations`, with or
    without `following`, and `target.adopt` are the owner's. Otherwise the old paths answer
    unchanged: the provider's observations, and the defaults above.
  - The owner's observation answer is typed as `DeviceObservationsResult` before it is encoded, and
    the control layer admits every answer under the method's published schema.
- **Candidate display names are unchanged.** They stay on the provider snapshot's path. With the
  development HDC they find no current snapshot and answer `resourceConflict`.
  - No Swift oracle yet records `mutateDisplayName` through the coordinator, so the owner path waits
    for one (r11: the oracle first).
  - Swift's order there is the exact-observation check, then generation exhaustion, then the store.
    Its refusals name `phase: candidateDisplayNameOwner`, not `preAdmission`.
  - The legacy path's wording also differs from Swift's current handler. That is unchanged here.

## Tests

`agentd/src/target_observation_control.rs` replays the Target adoption oracle
(`rust/tests/fixtures/target-adoption`) through `Control`, under the fake's lock.
- **The host** is the daemon's own `Host::from_environment()`, composed with:
  - a Target store over the fake's root, rebuilt as `HDCOracleFake.install` leaves it;
  - the development HDC, a `ProcessDispatch` of the fake driver;
  - a USB relation source set for each exchange from the recorded `usbRelations`. For the drift
    exchange it changes to `usbRelationsAfter.relations` after the recorded read count.
- **The exchanges.** Each of the 18 observations and adoptions is sent as a current frame through
  `Control::handle_frame`, in the mode the oracle names. The identities the owner mints read as the
  oracle's labels, and a label in a request is read back as the identity it stands for.
- **The comparison.** The daemon runs on the host's clock, so every UTC time reads as `<time>`.
  Otherwise every result, and every refusal's code, message and details, is compared exactly, as
  are the fake's calls, `targets.json` and `target-display-names.json`. Byte equality on the
  oracle's clock is #1959's `tests/target_adoption.rs`, which still passes.

It passed on its first run after the time reading. The first build failed twice: once because the
source seam was dead code outside tests, and once because the replay compared the host's times.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The control replay | `cargo test -p arkdeck-agentd target_observation_control` | 1 passed: all 18 exchanges; the fake's calls, `targets.json` and the display names |
| Control and daemon | `cargo test -p arkdeck-control -p arkdeck-agentd` | 27 passed, none failed; `read_only` 15 of 15 |
| The owner replay | `cargo test -p arkdeck-hoststore --test target_adoption` | 1 passed: #1959's byte-for-byte replay is unchanged |
| Real processes | `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/<oracle>` for `agent-execution`, `agent-lifecycle`, `observe-device` and `capture-diagnostics` | PASS on all four (29, 25, 28 and 28 exchanges; 57, 58, 57 and 57 checks), the same as #1959's runs: none of them exchanges an observation or adoption, and the harness serves neither method |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS: 124 control responses, 12 CLI envelopes, 115 valid requests. Without the development HDC both methods keep their old answers |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `e91fe292` | Invalid: main itself did not compile. Clippy on the development view failed in `arkdeck-provider-hdc` (E0252, `Reconcile` exported twice at `lib.rs:67` and `:91`): `5e966172` carries #1955's `native_library::Reconcile` and #1961's `readback::Reconcile`, each of which compiled on its own base. Nothing of this slice was reached; it is rerun once main compiles | `/private/tmp/xpa014-target-observation-routes-gate-20260914-r1.log`, SHA-256 `55d3c9cd0b6e6a7ae3ba6f2063172e8c97e3ab56eeb5682bc2e7b6d248a45f0a` |
| r2 | `5265018a` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 794 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-target-observation-routes-gate-20260915-b.log`, SHA-256 `e84b46dd3066154f09c5a68203e2a96d6bb7556628465f8c82882e2b379557b2` |

## Not run, and why

- **The real daemon's adoption.** The daemon composes `NoUsbRelations`, so over its socket every
  observation is `generationScoped` and every adoption is refused before admission. The
  real-daemon replay of this fixture needs a development-only relation source (A2b-2).
- **Candidate display names through the owner**, for the reason above.
- **Availability.** Its answer is the daemon's: presence, the tool leg and the operations.
- **A restart.** The snapshot, the generations and the receipts live in memory, as in Swift, and
  restart semantics stay out until L.1 item 13 is decided.
- No device, no real HDC.

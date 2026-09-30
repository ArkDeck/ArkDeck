# TASK-XPA-018 — Ctrl+C of a waiting leaf, and Windows coverage of the daemon-answered leaves (Windows 11 x64, 2026-09-30)

TASK-XPA-018 remains in progress. Base: protected main `544cc934` (#2351); no stack. Slice K1 of the
Windows phase. Run on the maintainer's Windows 11 x64 reference host (native Windows, Git Bash).
Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001); no HDC, board, elevation or system
change. No control schema, Catalog, corpus, command registry or `openspec/platforms/**` change.

## What changes

- **Ctrl+C / Ctrl+Break of a waiting leaf on Windows** (gate inventory G10, CLI `Interruption`,
  `arkdeck-cli/src/main.rs`). The CLI's interruption now installs the platform stop latch on
  Windows as on Unix: `arkdeck_platform::StopSignal::install(None)`, the existing Windows
  counterpart (`arkdeck-platform/src/windows/stop.rs`) — a `SetConsoleCtrlHandler` handler that only
  sets a manual-reset event for `CTRL_C_EVENT`/`CTRL_BREAK_EVENT` and leaves every other console
  event at its default. Unnamed (no instance scope): no other process can set it. The leaves that
  answer it are exactly the Unix ones: the event-following observation (`job watch`, and `job wait`
  on its event path). It stops waiting at its next look and ends with `clientInterrupted`
  ("client observation interrupted; the Job was not cancelled"), the Job id and resume cursor in its
  details, the stream's terminal line in `jsonl`, exit 130. Nothing is cancelled or sent again.
  `device wait`, `agent run` and the polling `job wait` install no latch on Unix either and keep
  the default (process ends), unchanged.
- **`arkdeck_platform::send_console_break(group)`** (Windows): `GenerateConsoleCtrlEvent
  (CTRL_BREAK_EVENT, group)` for a child started in its own process group; group 0 (every process
  on the console) is refused. The CLI crate forbids `unsafe`, so the test sends its break through
  this.
- **Windows coverage** (`feature_coverage.rs`, regenerated `openspec/contracts/cli-feature-coverage.json`).
  `WINDOWS_MEASURED_LEAVES = ["doctor", "operation.list"]`: Runtime leaves whose every method the
  Windows daemon answers and that are measured end to end on Windows — the CLI authenticates a
  daemon copy signed by a host-trusted development signer over the named pipe and renders its
  answer (CI: `check-readonly.py` `signed_windows_matrix`, #2330; here: the new
  `tests/windows_signed_runtime.rs`). An entry is Windows `implemented` when every leaf it reaches
  either needs no Runtime (as before) or is in that list; the list is validated against the
  registry and against `MACOS_HOST_LEAVES`. Per maintainer ruling 9 only `implemented` counts.
  - **`device.observations` stays `partial`** (decided conservatively). Its coverage entry reaches
    `device wait` and `device list`, not `device candidates`; neither is measured on Windows
    (`device list` reads the target owner, which the Windows daemon does not compose). And the
    Windows answer of `device candidates` is a structured refusal (`operationFailed`, no registered
    HDC tuple), not the live candidates its target contract names; §14 (`arkdeck-cli-product-spec.md`)
    reserves `implemented` for "the platform's complete target contract", so a refusal is the
    `partial` surface, not the implemented one.
  - `health` (`runtime health`) also stays `partial`: its preflight is exchanged on every
    connection, but the leaf's own answer is not in the measured matrix.
- `docs/design/cli-machine-contracts.md`: the Windows rule sentence names the measured leaves.
- `rust/tests/fixtures/maintainer-contracts/oracle.json`: the six pins of
  `contracts/cli-feature-coverage.json` (`c167080b…` → `3a2fe73a…`). Nothing else pins the old digest.

## Windows coverage (`cli-feature-coverage.json`, 256 entries)

| | implemented | partial | notImplemented | unset (macOS-only) |
| --- | ---: | ---: | ---: | ---: |
| Before (main `544cc934`) | 6 | 128 | 6 | 116 |
| After | 8 | 126 | 6 | 116 |

Newly `implemented`: `doctor`, `operation.list`. macOS statuses and every other field unchanged.

## Tests

| Test | What it holds | Runs on Windows |
| --- | --- | --- |
| `tests/windows_signed_runtime.rs` (new, `harness = false`) `daemon_answered_leaves_run_end_to_end_through_the_pipe` | the real `arkdeck-agentd` (beside the CLI), copied and signed with the development signer, on a private pipe with every other `ARKDECK_`/`OHOS_HDC_` input removed: `doctor`, `doctor --deep`, `operation list` answer `ok` (exit 0), `device candidates` answers `operationFailed` (exit 1); a wrong signer pin is refused `runtimeUnavailable` (69) | only with `ARKDECK_DEV_SIGNER_THUMBPRINT`; otherwise skipped with a message |
| same file, `ctrl_break_ends_a_waiting_watch_with_the_interrupted_envelope` | a fake Runtime (the test binary itself, signed) serves `job watch` the recorded event page; once it has answered a read the CLI, started with `CREATE_NEW_PROCESS_GROUP`, is sent `CTRL_BREAK_EVENT`. It must exit 130 (not `STATUS_CONTROL_C_EXIT`) with the two rows and the `clientInterrupted` terminal line (`lastCursor`, `jobId`, `afterCursor`), and the Runtime must have seen only `health` and `job.events`. Synchronised on the fake Runtime's own report of the read it answered, never on a sleep | as above |
| `feature_coverage.rs` `windows_status_follows_what_this_cli_serves_there` | adds `doctor`/`operation.list` `implemented`, `device.observations`/`health` `partial` | yes |
| `machine_contracts.rs`, `argv_fixtures.rs` | the regenerated coverage is the committed file; argv fixtures replay | yes |

There is no Unix CLI-level test of the interrupted envelope (the Unix harness runs the CLI to
completion); the Unix latch itself is held by `arkdeck-platform/tests/stop_signal.rs` (recorded,
not acted on; stays requested). The Windows test mirrors those assertions at the CLI.

## Local run and what was not run

- `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`: pass.
- `cargo test -p arkdeck-cli -p arkdeck-platform`: pass; `windows_signed_runtime` skipped
  (`ARKDECK_DEV_SIGNER_THUMBPRINT` is set in `HKCU\Environment` but not in this session's
  environment).
- With the thumbprint supplied, `windows_signed_runtime` failed at signing: PowerShell refused to
  run `rust/scripts/windows-dev-identity.ps1 sign` (`AuthorizationManager` check failed, i.e. this
  host's script execution policy). Relaxing the policy for the call was not done in this slice, so
  **neither signed test has run on this host**; both are unverified here. In CI only the contracts job creates
  the signer (for `check-readonly.py`'s signed matrix); the workspace job, which runs this crate's
  tests, has none, so the new test is expected to skip there. Whether any lane runs it signed is
  not verified.
- `arkdeck maintainer contracts export --contracts-directory openspec/contracts --fixtures-directory
  Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI`: only `cli-feature-coverage.json`
  changed.
- `refresh-contract-digests.py`, `copy-command-registry.py`, `copy-app-capability-registry.py`,
  `generate-contract.py` `--check` (`PYTHONUTF8=1`): pass. `sh scripts/check-sdd.sh`: pass.
  `git diff --check`: clean.

## CI

To be recorded; not verified.

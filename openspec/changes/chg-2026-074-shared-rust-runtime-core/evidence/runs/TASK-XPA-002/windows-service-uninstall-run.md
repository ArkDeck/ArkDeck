# TASK-XPA-002 — `runtime service uninstall` on Windows: stopping the client-started daemon from the CLI

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2-S. Base: protected `main`
`ff7c26d0` (#2404). Host: the Windows 11 x64 reference host, non-elevated. No device was
contacted, no `hdc` ran, and nothing installed was read or written: every daemon ran over an
isolated development root. Host tests are not Windows acceptance.

## The gap

The Windows CLI's `runtime service` served `status`, `verify` and `restart`. `install`,
`update` and `uninstall` answered `unsupportedOnPlatform` (`runtime_service_windows.rs`). The
only clean stop of the daemon was its named stop event, which `package-rc.ps1` and
`uninstall-rc.ps1` (#2404) signal from PowerShell. The CLI could not stop its own daemon.

## What macOS has, and the name chosen

The macOS CLI tree (`command_registry.json`) has no stop leaf. The `runtime service` leaves are
`install`, `update`, `restart`, `status`, `verify` and `uninstall`, with the retired `agentd`
spellings beside them. On macOS the daemon stops by `runtime service uninstall`, which boots the
LaunchAgent out and removes what it installed (plist, daemon bundle, receipt), keeping the state
and log directories.

The Windows counterpart is therefore `runtime service uninstall`: an existing, published leaf,
with its argv (`--output`, `--json`) unchanged. No new CLI surface or contract is added.

Windows has nothing registered to remove: the service is client-started (decision 11). The
installed image is the xcopy directory's or the package's, and it leaves by deleting the
directory (`uninstall-rc.ps1`) or removing the package, never by the CLI deleting its own image.
So on Windows, uninstall is the stop:

1. With no daemon on the root's pipe, there is nothing to stop. Exit 0, `stoppedPid: null`,
   nothing started, and no verified image needed.
2. Otherwise, the same checks and refusals as `restart`, now one shared routine
   (`stop_serving`):
   - the service must be ready: the installed image verified and the state root owner-only,
     else exit 69 and nothing is stopped;
   - the daemon's identity is proved on its pipe, `health` is read, and its instance document
     must name the pid serving the pipe;
   - its current Jobs are read in one complete `job.list` snapshot. Any active or unclosed Job
     refuses with exit 75, "runtime service uninstall refused while Runtime Jobs are active or
     unclosed: …", before anything is stopped;
   - the daemon is asked to stop through its own stop event, and its single-instance guard is
     awaited for 30 s (restart's default).
3. No successor is started. The state root is kept. The pipe must be gone afterwards, else
   exit 69.

The answer is `arkdeck-windows-daemon-uninstall/v1`: `stoppedPid`, `stopRequest`, `drain`,
`stoppedInstance`, `jobOwner`, `removedRegistration: false`, `removedDaemon: false`,
`preservedStateDirectory`, and `daemonService` (the service as it now is).

Any later command that needs the Runtime starts the daemon again, as it does after any stop.

## Coverage (delegated minor decision, pending the next rulings batch)

Ruling 10 gives macOS-only families their Windows counterpart, "launchd → client-started
daemon". Following it, `runtime service` leaves the macOS-only runtime groups of
`feature_coverage.rs`:
- `status`, `verify`, `restart` and `uninstall` are served on Windows and join
  `WINDOWS_MEASURED_LEAVES`;
- `install` and `update` (the LaunchAgent's own installation) stay refused (`MACOS_HOST_LEAVES`)
  and read `notImplemented`;
- the retired `agentd` spellings stay a macOS-only family.

`openspec/contracts/cli-feature-coverage.json` was regenerated with `arkdeck maintainer contracts
export`, and `maintainer contracts check` is clean.

## Measured

- **`arkdeck-agentd/tests/windows_service_uninstall_process.rs`.** The real `arkdeck` runs
  against a copy of the daemon signed with the host-trusted development signer, over isolated
  development roots, and the CLI starts the daemon itself.
  - `doctor` starts it.
  - `runtime service status` names it.
  - `verify` proves it.
  - `restart` replaces it.
  - `runtime service uninstall` stops the replacement: exit 0, the stopped pid is the instance's,
    the drain is complete, the Job owner is present, nothing is registered or removed, the state
    root is kept, the pipe is gone, and the signed image is untouched.
  - A second uninstall stops nothing and succeeds.
  - The next `doctor` starts a new daemon over the kept state, which uninstall stops again.
  - Over a root holding the Jobs a restart left current (Swift's reconcile oracle,
    `job-reconcile-analyzer/secondRestart`), uninstall is refused. It exits 75 with stdout
    empty, and its stderr names the current Job, as `restart`'s refusal does. The same daemon
    keeps serving.
- **`arkdeck-cli/tests/windows_runtime_service.rs`.**
  - With no daemon and no verified image, uninstall answers `stoppedPid: null`, keeps the
    root, and starts nothing.
  - `update` and `verify --job` stay `unsupportedOnPlatform`.
- **`arkdeck-agentd/tests/windows_client_start_process.rs`.** `restart`, now through the shared
  stop routine, still passes.

## Coordination

`windows/scripts/uninstall-rc.ps1` (#2404, G2) stops a daemon that runs from the directory it
removes by signalling its stop event itself. It could run the installation's own `bin\arkdeck.exe
runtime service uninstall`, which adds the identity proof and the current-Job refusal, but there
is a behavioural difference to weigh. When a daemon of another installation serves the account's
pipe, the script today leaves it alone, while the CLI would refuse on its identity. G2 has been
told; the script is not changed here.

## Local targeted checks

With `CARGO_TARGET_DIR=D:\cargo-target\ci2-stop`, `CARGO_BUILD_JOBS=4` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-cli --no-fail-fast` | 0 (245 passed, 0 failed) |
| `cargo test -p arkdeck-agentd --test windows_service_uninstall_process --test windows_client_start_process -- --nocapture` | 0 (5 tests, none skipped) |
| `windows_service_uninstall_process` and `arkdeck-cli`'s `windows_runtime_service` with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 (7 tests) |
| `arkdeck maintainer contracts check …` | 0, clean |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) |
| `git diff --check` | 0 |

## CI

To be recorded by the follow-up.

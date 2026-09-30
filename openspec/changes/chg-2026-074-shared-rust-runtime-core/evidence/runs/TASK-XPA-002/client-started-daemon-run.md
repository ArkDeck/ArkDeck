# TASK-XPA-002 — WM1 T3: the client-started Windows daemon and its service leaves, 2026-09-30

CHG-2026-074 r12 decision 11: the Windows daemon is started by its client and is
single-instance. This slice gives the Rust client the start path and gives Windows
the `runtime service status`, `verify` and `restart` leaves. Host tests ran on the
reference Windows 11 x64 host. This is not SPK-3, not Windows platform acceptance
and not device acceptance: no board, no `hdc`, and every daemon started here runs
over an isolated development root below the temporary directory. The account's
`%LOCALAPPDATA%\ArkDeck` was not created or read.

Base: `main` at `d05c9ee3` (#2343). Inputs: the Windows phase prompt §2 and the
S5 lifecycle run record (`windows-daemon-lifecycle-run.md`: guard, owner lock,
stop event, drain). From the gate inventory: G16 and §8 open question 1. Also the
macOS leaves in `arkdeck-cli/src/runtime_service.rs`.

## Implementation choices (proposed by the lead, for maintainer review)

The lead proposed these choices. They are recorded here for the maintainer's
review and are not ratified, except for the account-root DACL row, which is
ruling 5. A restart's stop request works only from the same logon session
(ruling 4): the stop event is `Local\`.

| Concern | Choice | Where |
| --- | --- | --- |
| When a client starts | Only when the daemon's pipe is absent (`WaitNamedPipeW`, 1 ms: absent or not, nothing connects). Not for a private `ARKDECK_ENDPOINT` (a daemon someone else runs) or `--socket` (macOS-only anyway). With `ARKDECK_DEVELOPMENT_STATE_ROOT` the client reaches the root's own pipe. | `arkdeck-client/src/start.rs` `StartTarget::resolve`, `ensure_running`; CLI `runtime_endpoint` |
| What is started | The pinned image, `ARKDECK_DAEMON_PATH` or the CLI's sibling. It is checked as a file first: absolute path, no reparse point, and a trusted Authenticode signature by the pinned certificate. A package-family pin is deferred, because only a running process has a package. With no identity configured, nothing is launched. The file and its ancestor directories stay open without write/delete sharing until `CreateProcessW` returns, so the checked file is the one started. | `arkdeck-platform/src/windows/identity.rs` `verify_installed_image`, `windows/daemon_start.rs` `DetachedDaemon::launch` |
| How it is started | `CreateProcessW` with the image alone as its argument array (the quoted path; a Windows path holds no `"`). Flags: `DETACHED_PROCESS \| CREATE_NEW_PROCESS_GROUP \| CREATE_NO_WINDOW`. `bInheritHandles = FALSE` and no standard streams: std's `Command` would pass its inheritable handles on, and a caller capturing the CLI's stdout would then wait for the daemon's exit. The working directory is the image's directory. The environment is the caller's minus `ARKDECK_ENDPOINT`, with `ARKDECK_DEVELOPMENT_STATE_ROOT` as resolved. | same |
| Waiting | At most 20 s (CLI) for the pipe. The client looks every 25 ms by waiting on the child's process handle, which also detects its exit. A child that exits 0 found the root held (`already running`), and the holder's pipe is awaited within the same bound. A non-zero exit is reported with its status. | `ensure_running` |
| Identity after start | The same check as every connection (`LocalConnection::connect`): pipe owner SID, server PID → image path and file identity, and signer pin or package family. A daemon that fails is reported as `identityRefused` with the PID this client started and is never trusted or used. The client leaves it running and does not stop or kill it. `ERROR_PIPE_BUSY` waits for the next instance with `WaitNamedPipeW` (bounded), not with time. | `connect_verified` |
| Concurrent starters | A named mutex `Local\<scope>.Start`, beside and never replacing the daemon's guard (owner-only DACL, owner checked, abandoned is taken), is taken in turn. The pipe is looked at again under it, so N concurrent clients launch one daemon. The daemon's single-instance guard stays the authority over which daemon runs. | `StarterLock` |
| No replay | Starting sends no frame. Nothing restarts a daemon inside a command or on a lost connection, and a lost request is never replayed (README "Try the current host path" now scopes "never starts a daemon" to macOS/Unix). | README |
| `runtime service verify` | The installed image (as above, nothing launched) and the state root. The account root is taken from the Known Folder API (`StateRoot::existing_account`, never created). When it exists it must be owner-only, `ArkDeck` included. A development root's access is reported, not required. When a daemon runs, it must prove its identity and answer `health`. `runtime` is `null` when none runs. | `arkdeck-cli/src/runtime_service_windows.rs` |
| `runtime service restart` | Refuses when not ready or when no daemon runs (69), and on current Jobs (75, the macOS preflight). A daemon that answers `job.list` with the foundation's `rejected` "The Job owner is not configured" composes no Job owner, so it has no Jobs (`restartProof.jobOwner: false`). Any other answer is not read as "no Jobs". Otherwise: `InstanceScope::request_stop(pid)`, then `GuardObject::acquire(wait)` on a thread of its own (bounded by `--maximum-wait-seconds`, default 30). Then the client start path, and proof of a new PID, the same catalog digest and the same closed Jobs. | same |
| Drain deadline | A predecessor whose 20 s drain was cut short exits holding its guard. The restart then reads `WAIT_ABANDONED`, reports `restart.drain: "deadlineElapsed"`, and ends that thread holding the guard while its handle stays open. The guard is therefore abandoned again for the successor, which starts as after a crash (S5's designed crash path). A guard still held at the bound refuses with 69, and nothing is started. | same |
| Account root access | Previously (#2337) the owner SID was checked and the DACL left as found. Now an existing `%LOCALAPPDATA%\ArkDeck` or `…\Agentd` whose DACL grants anyone but the user and SYSTEM anything (or has no DACL) refuses the daemon's start. `verify` reports it too. Both name the directory, the offending SID and access mask, and the fix (`OWNER_ONLY_REMEDY`). Access is never rewritten. This is maintainer ruling 5 of 2026-09-30 (`evidence/windows-maintainer-rulings-20260930.md`, #2343), so this row is ratified. A development root is the developer's directory: reported by `verify` (`accessFindings`), not refused. | `StateRoot::account`, `access_findings` |
| Envelopes | Same exit statuses and codes as the macOS leaves (64 range, 69 not ready/unprovable, 75 Jobs, 1 transport), the same members where the fact is the same (`daemonHealth`, `runtime`, `runtimeVerified`, `restartProof` with `beforeInstance`/`afterInstance`/`catalogDigestBefore`/`After`/`blockingJobCountBefore`/`preservedUnknownJobIds`), `daemonService` where macOS has `launchAgent`. Start failures of other commands stay `runtimeUnavailable` (exit 69) with `details.daemonStart.outcome` (`starterBusy`, `launchRefused`, `daemonExited`, `notReady`, `identityRefused`) and `pid` when one was launched. `install`/`update`/`uninstall`, the `agentd` spellings and `verify --job/--target/--execution-id` are `unsupportedOnPlatform`. | CLI `main.rs` Windows branch |

macOS behaviour is unchanged. `runtime_service*.rs` and their paths are not
touched, and the new code is `cfg(windows)`. The only shared edit is
`serve_runtime_service`'s non-macOS arm: it is now `cfg(windows)` for the new
leaves and `cfg(not(any(macos, windows)))` for the old refusal. Linux keeps its
answer.

## What changed

- `arkdeck-platform` (Windows): `windows/daemon_start.rs` adds `pipe_present`,
  `await_pipe_instance`, `StarterLock`, `DetachedDaemon`, `verify_daemon_image` and
  `ImagePin`. `identity.rs` adds `verify_installed_image`. `state.rs` adds
  `StateRoot::{account_path, existing_account, is_development, access_findings}`,
  `InstanceScope::{account, starter_name}` and the account root's DACL refusal.
- `arkdeck-client`: `start.rs` (Windows) with `StartTarget`, `ensure_running`,
  `connect_verified`, `Started` and `StartFailure`.
- `arkdeck-cli`: `runtime_service_windows.rs` (the three leaves, `ensure_runtime`).
  `main.rs` calls `ensure_runtime` in `runtime_endpoint` and has a Windows arm in
  `serve_runtime_service`.
- `arkdeck-agentd`: Windows dev-dependencies on `arkdeck-client` and `arkdeck-cli`
  for `tests/windows_client_start_process.rs`. There is also a module-doc line in
  `windows_lifecycle.rs`.
- `rust/README.md`: the "Try the current host path" sentence, the Windows
  paragraph's account-root refusal, and a new decision-11 section after it.
- Feature coverage is unchanged, so no oracle was re-pinned.
  `cli-feature-coverage.json` is Swift `FeatureCoverage`'s projection: `runtime
  service` is in `MACOS_ONLY_RUNTIME_GROUPS`, and a Windows status is
  `notImplemented` until the profile is ratified. Maintainer ruling 10 of
  2026-09-30 maps launchd to the client-started daemon, with the concrete
  coverage list reviewed at WM6. That review is where this entry changes; this
  slice does not change it.

## Tests (Windows host)

- `arkdeck-platform` unit tests:
  - `daemon_start` (4): a pipe is present only while served; one starter holds
    the turn at a time; nothing is launched without an identity or with a
    mismatched pin or a relative path; the environment block is sorted and
    double-terminated.
  - `state` (+1): only an owner-only root has no access findings, and a Users
    grant is reported by SID.
- `arkdeck-agentd/tests/windows_client_start_process.rs` (real daemon):
  - A package-family-only identity starts the daemon, which then fails identity:
    `identityRefused` with the launched PID, `instance.json` names it, a verified
    connect is refused, and its own stop request drains it cleanly.
  - No identity configured: `launchRefused`, no PID, no pipe, no
    `instance.json`. `verify` answers not ready (69) and starts nothing.
  - Development signer: a signed copy starts once on demand, then answers
    `alreadyServing`. `verify` and `status` prove it. `restart` ends the test's
    idle connection by the drain (`drain: complete`, `start: launched`, a new
    PID, the same digest, `jobOwner: false`, `instance.json` names the
    successor). The ended connection then fails (`Transport`, then
    `ConnectionUnusable`) and is not replayed. `--maximum-wait-seconds 0` gives
    64. With the daemon stopped, four concurrent starters produce exactly one
    `launched` and one daemon.
  - No sleep synchronises an assertion. Daemons are awaited on their guard.
    Cleanup asks a daemon left by a failed assertion to stop through its stop
    event.
- `arkdeck-cli/tests/windows_runtime_service.rs` (the `arkdeck` process, no
  identity): `doctor` answers `runtimeUnavailable` with
  `daemonStart.outcome: launchRefused` and starts nothing. `verify` answers 69
  with a not-ready document, and `status` answers `socket_absent`. `restart` is
  refused (69) or out of range (64, by the parser). `uninstall` and `verify --job`
  are `unsupportedOnPlatform`.
- End to end with the real CLI binary on this host (a scratch copy of `arkdeck.exe`
  beside a signed copy of `arkdeck-agentd.exe`, `ARKDECK_DAEMON_SIGNER_SHA256` =
  the development signer's pin, a development root):
  - `doctor` started the daemon and answered `ok`; a second `doctor` used the
    same daemon.
  - `runtime service verify` answered `runtimeVerified: true`, the image pin
    `signer`, and a runtime PID equal to the started one.
  - `runtime service restart` answered `drain: complete`, `start: launched`, a
    new PID and the same catalog digest.
  - `status` answered `health ok`. The daemon was then stopped by its stop event,
    and `status` answered `socket_absent`.
  - `doctor` against a private `ARKDECK_ENDPOINT` started nothing
    (`runtimeUnavailable`, no `daemonStart`).
- A first full-suite run under load failed once: the service leaf's connect met
  `ERROR_PIPE_BUSY` right after `status` took the offered instance. The fix is
  `connect_verified`, which waits for a free instance with `WaitNamedPipeW`, and
  the start path now also awaits one before returning. That run left one test
  daemon, which was then stopped through its own stop event (it was this test's).
  The Drop guard now covers that case. After the fix the test passed 10 of 10
  alone and in the full run.

## Local targeted checks (Windows 11 x64 reference host, stable toolchain)

- `cargo fmt --all --check`: clean.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `cargo test -p arkdeck-cli -p arkdeck-client -p arkdeck-agentd -p arkdeck-platform`
  (with `ARKDECK_DEV_SIGNER_THUMBPRINT` set from the user environment): all pass.
- `sh scripts/check-sdd.sh`, `git diff --check`: see the commit message.
- Not run here:
  - macOS and Linux builds: no such target on this host. Every change there is
    a cfg arm (`main.rs` `serve_runtime_service`), re-read by hand; CI decides.
  - `check-readonly.py`: its daemons use a private `ARKDECK_ENDPOINT`, which is
    never started, so its matrix should be unchanged. CI runs it.

## CI

To be recorded in the next slice's run record.

## Not in this slice / follow-ups for the lead

- Profile (governance): record decision 11's start path. That covers the
  starters' mutex name, the detached launch flags, the pre-launch file check and
  the deferred package-family proof. Also record the account root's DACL
  refusal (ruling 5).
- `verify --job` and the fresh `observe.device@1` run on Windows. They need the
  Job store (G01, S3) and the agent-execution owner.
- The WinUI App's start path: ClientKit should call the same
  `arkdeck_client::start` semantics.
- A daemon launched from inside a Job object that kills its processes on close
  (for example a CI step or `cargo test`) ends with that job. No breakaway is
  asked for.
- Feature coverage for `runtime service` on Windows (Swift `FeatureCoverage`'s
  macOS-only group) once the profile is ratified.

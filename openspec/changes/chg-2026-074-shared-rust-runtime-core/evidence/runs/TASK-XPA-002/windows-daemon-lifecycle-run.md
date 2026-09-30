# TASK-XPA-002 — WM1 S5: the Windows daemon lifecycle, 2026-09-30

State root, single instance, and a serving loop that stops and drains, so that
the Windows daemon composes like the non-macOS Unix one and a restart reads
back what its predecessor left (GJ-1's restart hop). Host tests on the
reference Windows 11 x64 host; not SPK-3, not Windows platform acceptance, not
device acceptance: no board, no `hdc`, the daemon is unsigned and uninstalled,
and every daemon the tests start runs over an isolated development root below
the temporary directory. The account's `%LOCALAPPDATA%\ArkDeck` does not exist
on this host and was not created.

Base: `main` at `31c0ac28` (#2328). Inputs: the Windows phase prompt §2.1, the
gate inventory of PR #2331 (G10, §6 proposal), the profile's Port mapping
(`SingleInstanceGuard`: per user/product, handles an abandoned owner), and the
SPK-5 NTFS facts of this host.

## Platform decision (for the lead to carry into the profile)

| Concern | Decision | Why |
| --- | --- | --- |
| State root | `%LOCALAPPDATA%\ArkDeck\Agentd` from `SHGetKnownFolderPath(FOLDERID_LocalAppData)` for the process token; `LOCALAPPDATA` is not read. `ArkDeck` and `Agentd` are created owner-only: owner = user SID, protected DACL `(A;OICI;GA;;;<user>)(A;OICI;GA;;;SY)`. An existing root must be a directory, not a reparse point, owned by the user SID; its existing DACL is not rewritten. Every directory from the drive to the root is held open without delete sharing while the daemon runs. | Design §D.2; the same rule as macOS ignoring `HOME`; pinning the ancestors keeps path-named opens under the root from being redirected by a rename. |
| Durable owner lock | `LockFileEx(EXCLUSIVE \| FAIL_IMMEDIATELY)` on one byte at offset `0x7fff_ffff_0000_0000` of `instance.lock` (name unchanged). | SPK-5: NTFS locks are mandatory, so the range lies beyond any data; released at once when the holder dies. |
| Single-instance guard (Port) | Named mutex `Local\ArkDeck.Agentd.<user SID>`, explicit DACL (owner user SID; user SID and SYSTEM), taken without waiting on the daemon's main thread and held until the drain completes. An existing object whose owner is not the user SID, or that cannot be opened (`ERROR_ACCESS_DENIED`), refuses the start. | See "Why `Local\`" below. |
| Abandoned owner | `WAIT_ABANDONED` is taken, one stdout line names it, and the start goes on as the start after a crash that every start already is; nothing is read as a clean handover and nothing is replayed. An incomplete drain exits holding the guard on purpose, so its successor sees the abandonment. | Inventory §6. |
| Order at start | guard → owner lock → stop event → pipe (`FILE_FLAG_FIRST_PIPE_INSTANCE`) → read predecessor's `instance.json` → publish own `instance.json` → compose and serve. A held guard or lock answers `already running` from `instance.json`, exit 0, having composed nothing. | Inventory §6; macOS production's order and answer. |
| Instance document | `instance.json`, Swift's shape (`pid`, `protocolVersion`, `socketPath` = pipe name, `startedAtUTC`), replaced by temp file + `FlushFileBuffers` + `SetFileInformationByHandle(FileRenameInfoEx, REPLACE_IF_EXISTS \| POSIX_SEMANTICS)` + directory flush through a `GENERIC_WRITE` handle. | SPK-5: the POSIX rename is the working atomic replace. |
| Stop source | A manual-reset event `<guard name>.Stop.<pid>` with the owner-only DACL, set by `InstanceScope::request_stop` (SIGTERM's counterpart, same user only), plus `SetConsoleCtrlHandler` for Ctrl+C / Ctrl+Break (SIGINT's). `accept_until` waits on the stop and the pending `ConnectNamedPipe` together; the stop wins. | G10. Per-instance name: a stale set event of a predecessor can never stop its successor; an existing object with that name refuses the start. |
| Drain | `serve_control`'s drain unchanged and now shared: stop accepting (the waiting pipe instance closes), let the frames being answered finish, end every open connection (a latch the connection threads wait on beside a zero-byte overlapped read, plus a closer that cancels the connection's pipe I/O), one 20 s deadline. After a complete drain: release the owner lock, then the guard, on the main thread; then `arkdeck-agentd stopped`, exit 0. | Mirrors Unix; the pipe server handle is closed, not disconnected, so a reply already written still reaches the peer. |
| Endpoint | Account: `\\.\pipe\arkdeck-agentd-<logon SID>` as before. | Unchanged. |
| Isolated development root | `ARKDECK_DEVELOPMENT_STATE_ROOT` = an existing directory of the user, refused if it is or lies under `%LOCALAPPDATA%\ArkDeck` (decided by walking the root's final path and comparing `FileIdInfo` identities, never by string prefix). Owner lock `.owner.lock`; guard `Local\ArkDeck.Agentd.Dev.<user SID>.<volume serial>-<file id>`; pipe `\\.\pipe\arkdeck-agentd-dev-<logon SID>-<volume serial>-<file id>`; an `ARKDECK_ENDPOINT` beside it must equal that name. Only the lifecycle is composed; every input from which the isolated macOS owner composes an owner refuses the start. | Inventory §6; nothing is silently ignored. |
| Private endpoint | `ARKDECK_ENDPOINT` alone: the read-only foundation over that pipe, no state root, Ctrl+C stop only. | Keeps the black-box read-only check (it terminates its daemon). |

### Why `Local\` and not `Global\`

The premise that a `Global\` object needs `SeCreateGlobalPrivilege` does not hold
for a mutex: measured on this host from a non-elevated (Medium) process,
`CreateMutexW("Global\\…")` succeeded and `CreateFileMappingW("Global\\…")` failed
with error 5 — only file mappings need the privilege. `Local\` is chosen anyway:

- In `Global\` any other account can pre-create `ArkDeck.Agentd.<victim SID>`; the
  owner check turns that into a refused start (fail closed), i.e. a cross-account
  denial of service. In the session namespace only a process in the same logon
  session can do that.
- The exclusion across the logon sessions of one account, which share one
  `%LOCALAPPDATA%`, is already the owner lock's (`LockFileEx`, kernel-released on
  death). A second session's start takes its own session's guard, then finds the
  owner lock held and answers `already running` from `instance.json` — the same
  answer the inventory's `Global\` proposal gives.
- A kernel private namespace bound to the user SID would also stop squatting,
  but its boundary-descriptor lifetime rules add a second abandoned-state case
  for no gain over the owner lock; not taken.

Consequence to accept: a stop request is session-scoped (the stop event is
`Local\`), so another session of the same account cannot stop the daemon; it
can see it (`already running`).

## What changed

- `arkdeck-platform` (Windows only): `StateRoot` (account and development roots,
  scope, endpoint, owner lock, atomic document publish), `InstanceScope`
  (guard and stop-event names, `request_stop`), `GuardObject` /
  `SingleInstanceGuard` / `GuardAcquisition` (open, then take with an optional
  wait for a handed-over successor), `StopSignal`, `Latch`, `ListenerLock`,
  `ConnectionCloser`, `Readiness`, `LocalListener::{accept_until,
  accept_until_latch, stop_listening}`, `LocalConnection::{closer,
  wait_readable}`. `windows-sys` gains `Win32_System_Com`,
  `Win32_System_Console`, `Win32_UI_Shell` (no new crate).
- `arkdeck-agentd`: `serve_control` and `drain` are no longer `cfg(unix)`; the
  `unreachable!("only a stop request ends accepting")` in `lib.rs` and
  `main.rs` are gone. `src/windows_lifecycle.rs` composes the three Windows
  modes; `main.rs` takes them before anything else on Windows and releases
  them after a complete drain. Unix code paths are unchanged in behaviour (the
  accept closure is the same `accept_until(&stop)` on every host now; the
  `cfg(not(target_os = "macos"))` refusal of a development root became
  `cfg(all(unix, not(target_os = "macos")))`).
- `rust/README.md`: the Windows paragraph after the endpoint/environment table.

## GJ-1 observable now working (host)

`crates/arkdeck-agentd/tests/windows_lifecycle_process.rs`, the real daemon
binary over a fresh development root, environment cleared of `ARKDECK_*` and
`OHOS_HDC_*` inputs:

1. start → `arkdeck-agentd listening on \\.\pipe\arkdeck-agentd-dev-…`,
   `instance.json` names it; a `health` frame over the pipe answers `ok: true`;
2. a second start over the same root → stdout exactly `arkdeck-agentd already
   running: pid <first>, socket <pipe>, protocol 1.0.0`, exit 0, `instance.json`
   untouched;
3. `request_stop(pid)` → the idle connection is ended by the drain (the client
   reads its end), `arkdeck-agentd stopped`, exit 0; the pipe name is gone;
4. start again → same pipe, and `arkdeck-agentd previous instance: pid <first>,
   started <its startedAtUTC>` read back before `instance.json` is replaced; no
   abandoned-guard line; `health` answers again; clean stop;
5. a daemon killed while a waiting successor holds the guard object open → the
   successor gets `WAIT_ABANDONED`; the next daemon logs the abandoned-guard
   line and the killed daemon's instance; after its clean stop the next start
   sees no abandonment;
6. an `ARKDECK_ENDPOINT` that is not the root's derived pipe → exit 69 with the
   derived name, nothing written.

Not in this slice: the stores a restart would read back beyond the instance
document (G01 durable host store) and Job recovery over them; the client
starting the daemon (decision 11) and a `runtime service restart`/`verify`
Windows form; the account composition's first real start on a host (only its
Known Folder resolution is tested, to keep `%LOCALAPPDATA%\ArkDeck` untouched).

## Local targeted checks (Windows 11 x64 reference host, stable toolchain)

- `cargo fmt --all --check`: clean.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `cargo test -p arkdeck-agentd -p arkdeck-platform`: all pass, including the
  new `windows::state` unit tests (6), `tests/windows_transport.rs` (13, 4 new),
  `tests/windows_stop.rs` (1), `drain` (3, now on Windows) and
  `tests/windows_lifecycle_process.rs` (3); the lifecycle test passed 3 of 3
  consecutive runs.
- `cargo test --workspace`: no failure.
- The daemon started with no console flag, `DETACHED_PROCESS` and
  `CREATE_NO_WINDOW` from Python, both as the private-endpoint composition and
  over a development root: it served in each case (the stop handler installs
  without a console).
- `sh scripts/check-sdd.sh` and `git diff --check`: see the commit message.
- Not run here: macOS and Linux builds (no such target on this host); the cfg
  pairings were re-read by hand, CI decides. `check-readonly.py` (needs
  `jsonschema`, not installed on this host); CI runs it on Windows.

## Follow-ups for the lead

- Profile (`openspec/platforms/windows/profile.md`, governance): record the
  decision above for `SingleInstanceGuard` (name, `Local\` scope and the
  owner-lock cross-session argument, DACL, abandoned-owner handling) and the
  stop source.
- Decision 11: the client-started daemon, using `GuardObject::acquire(wait)`
  for the handover and `InstanceScope::request_stop` for a Windows
  `runtime service restart`.
- Whether an existing account root whose DACL is not the owner-only one should
  be refused or tightened (today: owner SID checked, DACL left as found).

# TASK-XPA-002/005 — the account daemon's Sessions root and Trace cache on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2-L. Base: #2385's head
`4db744ca` (the Job, Session and runner owners composed on the Windows daemon), then merged with
`origin/main` `c7fa14cb` once #2385 landed; the targeted checks were run again after the merge. Host: the
Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted, no HDC or board was
used, and no operation was submitted. The account's own `%LOCALAPPDATA%\ArkDeck` was neither
read nor written: it did not exist before these tests and does not exist after them. No system
setting was changed. Host tests are not Windows acceptance.

## The two parked decisions

- **H3 (Sessions).** The installed daemon kept `session-state` and `sessions` below `Agentd`
  "until the Windows App names its Sessions location".
- **W1 (Trace cache, ruling 28).** The installed daemon composed no Trace cache "until the
  Windows App cache location is decided".

## Research

- **macOS layout** (`production.rs` `Layout::for_home`):
  - state directory: `~/Library/Application Support/ArkDeck/Agentd`;
  - default Sessions root: its sibling `…/ArkDeck/Sessions`, while the Session settings live in
    the state directory;
  - Trace cache: `~/Library/Containers/<App>/Data/Library/Caches/ArkDeck/Trace/traces`. The
    sandboxed App creates it in its own container, and the daemon only reads it where the App
    created it, never creating it.
- **Windows account root** (`StateRoot::account`, design §D.2): `%LOCALAPPDATA%\ArkDeck\Agentd`
  from the Known Folder API. Product directory and root are owner-only; an existing one that is
  not owner-only refuses the start and is never rewritten (ruling 5). Every ancestor of the root
  is held open without delete sharing while the daemon runs.
- **Ruling 8:** the MSIX turns file-system write virtualization off, so the App, the packaged
  daemon and an xcopy CLI share one physical `%LOCALAPPDATA%`. Windows has no App container
  whose caches only the App may create.
- **Ruling 23:** the account root keeps each store in a private child, because the host store
  cannot open the account root itself, whose DACL also grants SYSTEM.
- **#2380 RC layout** (`windows/README.md`, `package-rc.ps1`): the daemon's state is
  `%LOCALAPPDATA%\ArkDeck`, and uninstalling the xcopy form leaves it. The RC smoke runs over a
  development root and checks that the product root is unchanged.
- **Client side:** neither the WinUI App (`windows/`) nor the CLI spells a Sessions or Trace
  location. Both ask the daemon (`runtime.storage.status`, `trace.cache.status`), so they agree
  by construction as long as the daemon answers one location.

## Decision (delegated minor decision, recorded as ruling 29)

The locations mirror macOS, in the product directory beside the state directory:

| owner | macOS | Windows account |
| --- | --- | --- |
| Session settings | `ArkDeck/Agentd` | `%LOCALAPPDATA%\ArkDeck\Agentd\session-state` (unchanged; ruling 23) |
| default Sessions root | `ArkDeck/Sessions` | `%LOCALAPPDATA%\ArkDeck\Sessions` |
| Trace cache | the App's `Caches/ArkDeck/Trace/traces` | `%LOCALAPPDATA%\ArkDeck\Trace\traces`, beside `Trace\staging` |

Reasons:

1. The same relative names as macOS, one level below the product directory. The Sessions root
   is user data with its own quota and retention, so it does not belong inside the daemon's
   private state directory.
2. `%LOCALAPPDATA%`, not `%APPDATA%`: nothing here should roam, as nothing of the state root
   does.
3. **The daemon creates the Trace cache**, owner-only, where the macOS daemon never does.
   - On macOS that rule exists because the cache lives in the App's container, which is the
     App's to create.
   - On Windows there is no container (ruling 8), the three processes share one physical
     directory, the daemon owns the store, and the development root's daemon already creates
     the same `traces` and `staging` layout.
   - A daemon that only read an App-created cache would compose no Trace cache on Windows at
     all, since the Windows App creates none.
4. Each directory is created owner-only with the store's private descriptor, beside the root in
   the owner-only product directory that the root's handles pin. An existing one is never
   re-permissioned; the owner that opens it refuses one that is not owner-only (ruling 5).

## One-time move of an earlier build's `Agentd\sessions`

The move runs at start, under the single-instance guard and the owner lock, before any owner
opens a Session root (`Authority::move_account_sessions`):

| found | done |
| --- | --- |
| no `Agentd\sessions` | nothing |
| `Agentd\sessions`, no `Sessions` | one rename on the same volume (`FileRenameInfoEx`, never replacing) moves the directory, so every Session, its staging and the retention catalog move together, keeping the directory's identity and its own descriptor; nothing is copied; both directories are flushed |
| both, `Agentd\sessions` empty | the empty directory is removed (deleted by handle, only while empty) |
| both, `Agentd\sessions` holding anything | the start is refused, naming both; neither is changed (Sessions are never merged) |

Then `SessionStore::rebase_default_root` runs under the storage lock. If the settings still
select the default root at its old spelling, it publishes them selecting the new one, one
generation on. Anything else is left: no settings yet, a custom root, or the default root
already at the new place. It runs on every start, so a start that died between the rename and
this publication completes it.

What the move relies on (read from the code):
- the owner compares a default root's `rootPath` with the root it is given;
- a Session publication marker records its root's path, but only a publication that has no
  receipt yet reads it again, and that starts from the current settings;
- staged Sessions are recovered from the current root's `.staging`.

A cleanup or export plan persisted before the move names the old path. It is refused
afterwards (fail closed), not followed.

Platform primitives added to `StateRoot` (Windows):
- `product_child`, a private child of the product directory;
- `has_entry`, which does not follow a link;
- `remove_empty_child`;
- `move_child_to_product`.

`private_child` now shares its body with `product_child`.

The owner census (`Host::owner_census`, the macOS order) needs no change. The account
composition now reads `jobs, capabilities, targets, artifacts, storage, workspaceProjects,
planning, traceCache`, the same list as a development root, with `traceCache` at its macOS
position.

## Measured

`arkdeck-agentd/tests/windows_account_locations_process.rs` runs the real daemon's **account**
composition, with no development root, over a fake account.
- `FOLDERID_LocalAppData` is the Known Folder the Shell expands from the process's
  `USERPROFILE`. I measured this on this host: `SHGetKnownFolderPath` in a child whose
  `USERPROFILE` names a fresh directory answers `<it>\AppData\Local`. A child with only
  `LOCALAPPDATA` changed answers the account's own.
- So a daemon started with `USERPROFILE` naming a fresh directory below the temporary directory
  owns `<it>\AppData\Local\ArkDeck` and nothing of the account's.
- Its guard and pipe are still the account's, so the test skips, saying so, while an account
  daemon serves. None did.

Each scenario ran with the fake profile spelled as the file system spells it, and again with
its 8.3 short name (`…\Temp\AD-FAK~1`, as a hosted runner's `TEMP`
`C:\Users\RUNNER~1\…` spells it). Results:

- **An earlier layout moves once and reads back.** The earlier layout was built by the Session
  owner itself: its settings select the default root at `Agentd\sessions` after one policy
  update (generation 2), and that root holds a retained Session.
  - The start reports the move and the rebase, and the census ends with `traceCache`.
  - `Agentd\sessions` is gone. `ArkDeck\Sessions` holds the same Session tree, byte for byte;
    only the retention catalog is reconciled to the new settings generation, as on any read.
    `ArkDeck\Trace\{traces,staging}` exist.
  - The settings select `…\ArkDeck\Sessions` (canonical long spelling in both runs) at
    generation 3, with the earlier policy kept.
  - Over the pipe, `runtime.storage.status` names that root; `session.list` lists the retained
    Session; `trace.cache.status` answers the empty inventory.
  - A restart moves nothing and answers the same.
- **An earlier root beside `Sessions`.** An empty one is removed and the start serves
  `Sessions`. One holding a Session refuses the start: stderr names both and says Sessions are
  never merged, nothing listens, and neither tree changes.
- **Real CLI.** A copy of the daemon signed with the host-trusted development signer
  (`ARKDECK_DEV_SIGNER_THUMBPRINT` exported explicitly; the test ran, not SKIPPED), with the CLI
  verifying its image and signer:
  - `arkdeck runtime storage status` prints the Session domain the pipe answers, root
    `…\ArkDeck\Sessions`;
  - `arkdeck trace cache status` prints the same empty inventory.

## Local targeted checks

With `CARGO_TARGET_DIR=D:\cargo-target\ci2-locations`, `CARGO_BUILD_JOBS=4` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-agentd --test windows_account_locations_process -- --nocapture` | 0 (4 tests, none skipped) |
| `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd --no-fail-fast` | 0 (454 tests in 172 binaries, 0 failed) |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) |
| `git diff --check` | 0 |

## CI

To be recorded by the follow-up (PR number, run id).

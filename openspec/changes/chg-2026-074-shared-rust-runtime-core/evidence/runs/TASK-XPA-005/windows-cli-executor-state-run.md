# TASK-XPA-005 — a paused domain leaf's state on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. A product bug found while driving GJ-1's CLI
leaves through #2479's signed test daemon (recorded in
`windows-gj1-oracle-replays-run.md`, #2503). It is shipped on its own, as the lead asked.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## The bug

A domain leaf (`target observe`, `diagnostics capture`, `input tap`, …) runs through the CLI's
client-side executor. When the run pauses for a person (a reconnect, a target or candidate
selection, a trust prompt), the executor keeps a pending record so that
`agent resume --resume-token` can continue it later. Swift keeps that record in `agent-runtime`
beside the Runtime's socket (`AgentRuntimeExecutor`), and the Rust port did the same
(`domain_leaves::state_directory`).

On Windows the endpoint is a named pipe, `\\.\pipe\arkdeck-agentd-<SID>`. "Beside it" is
`\\.\pipe\agent-runtime`, a name in the pipe namespace, where no directory can be created. Every
pause on Windows failed with `arkdeck target: persistence("…(os error 1314)")`
(`ERROR_PRIVILEGE_NOT_HELD`): the run was not kept, and nothing could resume it.

## What

- **The directory.** On Windows `state_directory` is
  `%LOCALAPPDATA%\ArkDeck\agent-runtime\<pipe name>`:
  - The account's local application data comes from the Known Folder API
    (`arkdeck_application_support_root`, never the `LOCALAPPDATA` variable).
  - There is one directory per Runtime pipe, as macOS has one per socket.
  - The pipe name is kept to ASCII letters, digits, `-`, `_` and `.`; any other character becomes
    `_`.
  - A name of dots only, or no Known Folder, gives no directory. Persistence then refuses ("the
    paused run's state directory is unavailable"), and a resume reads the token as unknown.

  macOS and Linux are unchanged: `agent-runtime` beside the socket.
- **Owner-only.** On Windows `persist` creates every missing level with the private directory
  descriptor (`create_private_directories`). The directory must then open as an owner-only one
  (`HostDirectory::open`), as the Runtime's private roots do, so a directory another account can
  reach is refused and never written. The record is still written to a temporary name and renamed
  into place.

## Tests (`arkdeck-cli/tests/domain_executor.rs`)

- `a_paused_run_is_kept_and_resumed_from_its_state_directory` (every host): the recorded
  `reconnectResumesAndCompletes` scenario.
  - Its run pauses, and the pending record is kept under the token.
  - On Windows the directory opens as an owner-only one.
  - A resume from the same directory completes, and the record is removed.
- `a_windows_pipe_keeps_its_paused_runs_below_the_accounts_local_application_data` (Windows):
  - the pipe-to-directory mapping, sanitising, and the refused names and missing folder;
  - `state_directory` of a real endpoint lands below this account's Known Folder.
- The recorded executor scenarios (`each_scenario_replays_as_swifts_executor_ran_it`) now root
  their state directory at the temporary directory's canonical spelling, which an owner-only
  directory is bound to (an 8.3 `TEMP` spells it otherwise). The scenarios are unchanged.

## Left out

- **The CLI leaves end to end** through the signed test daemon (`target observe`,
  `diagnostics capture`) and their coverage come with the GJ-1 CLI-leaves layer, beside the
  daemon's USB-relation stand-in.
- **Delegated minor decision, pending the next rulings batch.** The location
  `%LOCALAPPDATA%\ArkDeck\agent-runtime\<pipe name>`, owner-only, beside the account daemon's
  `Agentd` root; the pipe name's sanitising.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.

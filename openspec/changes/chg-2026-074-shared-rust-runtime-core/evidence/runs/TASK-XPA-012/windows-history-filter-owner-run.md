# TASK-XPA-012 on Windows — the History filter owner on the Windows daemon (2026-09-30)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched. Every daemon ran over a fresh development root below the temporary directory.
- **Base:** protected `main` `2c593b28` (#2430).

## What changed

- `arkdeck-hoststore`: `HistoryStore` (`history_owner.rs`, the owner #1888 made the facade's and
  #1841 wrote) builds on Windows. The code is unchanged; it runs over the host store's NTFS
  `HostDirectory` (`lock_document`, `read`, `publish_document`, `validate_path`, the lock's
  `validate_link`). Its unit tests now run on both hosts through `test_private` (owner-only
  directories and files; a symbolic link on macOS, a second hard link on Windows).
- `arkdeck-agentd`: the Windows daemon composes it (`Authority::history_store`) over the root's
  private `history-filter`, and `history.filter.list|save|delete` route to it. The census names
  it at its macOS position: `jobs, capabilities, mutationAuthority, targets, artifacts, imports,
  storage, history, workspaceProjects, planning, agentExecutions, humanActions, traceCache`. A
  development root's selected Sessions root must stay outside `history-filter` too.
- `arkdeck-cli`: `history filter list|save|delete` join `WINDOWS_MEASURED_LEAVES`;
  `cli-feature-coverage.json` was regenerated with `arkdeck maintainer contracts export`
  (Windows `implemented` 68 → 71). The six coverage-digest pins in
  `rust/tests/fixtures/maintainer-contracts/oracle.json` were substituted
  (`4ea3ae91…` → `6f383be7…`), as #2378 and #2409 did.

## T0 and the Swift oracles

- The durable document is `history-filter.json` under `.history-filter.lock`, the store's frozen
  encoding (`decode_history`, whose re-encoding the local shadow corpus proved equal to Swift's
  owner, #1841). No other durable format is touched.
- `history_owner::tests::the_recorded_history_filter_frames_replay_as_recorded` (macOS and
  Windows): the committed control-frame corpus (`ControlFrames/history.filter.*.jsonl`, 14
  frames) is replayed over one store at the recorded time. Every result equals the recorded one
  exactly. Every refusal (`recordUnreadable`, `resourceConflict` for a held lock and for a stale
  generation, `resourceNotFound`) equals its code and details. The two documents the owner wrote
  are pinned byte for byte. A document in Swift's encoding (milliseconds in its time) lists as
  Swift answered it. The three `internalError` "History filter store is not configured" frames
  are Swift's answer without a store, which a composed owner never gives.
- `arkdeck-agentd/tests/windows_history_filter_process.rs`, over the real daemon:
  - the same corpus over the pipe across three restarts, compared without the times the daemon's
    clock writes; the document after each write is the frozen encoding with that time;
  - another holder of the lock refuses a save, and nothing is written;
  - Swift's document lists exactly as recorded; a corrupt document refuses that request and the
    save, keeps its bytes, and the daemon goes on answering;
  - a `history-filter` directory that is not owner-only refuses the start (exit 69);
  - with `ARKDECK_DEV_SIGNER_THUMBPRINT`: the real CLI against a development-signed copy lists
    Swift's filter, saves, is refused a stale delete, reads back after a restart, deletes, and
    reads the tombstone after another; the three leaves are `implemented` in the manifest the
    CLI renders.

## Delegated minor decision (pending the next rulings batch)

1. **Where the document lives on Windows.** Both macOS compositions keep `history-filter.json`
   and its lock in the state directory itself. The host store cannot open a Windows state root
   itself: a development root is any directory of this user, and the account's root grants SYSTEM
   (ruling 23). So the Windows daemon keeps the same document and lock one level down, in the
   root's private `history-filter`, as it keeps the Job store in `jobs-state`. The bytes are
   unchanged; only the directory differs between hosts.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`,
  `CARGO_TARGET_DIR=D:/cargo-target/a1-history`.
- See the commit message for the local results and the macOS cross-check.

# TASK-XPA-005 — `job archive preview|apply` end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Third layer of P2's stack, on
`agent/xpa-012-windows-tool-register-20261005`. It measures `job archive preview` and
`job archive apply` (#2468) through the real signed CLI and the signed test daemon
(`agentd/tests/spawning/job_archive_cli.rs`).

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## Reference

No Swift oracle records the archive, because Swift was retired before #2468. The reference is
the macOS Rust Runtime's recorded answers: `ControlFrames/job.archive.jsonl` and
`job.archive.preview.jsonl`, recorded by `arkdeck-hoststore`'s `job_archive` tests over one Job.

The test seeds that Job below the development root's Job state before the daemon starts:

- the record is `job-reconcile-analyzer`'s `job-082b8363…`;
- its journal is written as the owner's tests write it: created, running, one confirmed
  host-only step, `waitingForRecovery`.

Every answer equals the macOS answer except two host-local digests:

- `reviewSha256` digests this host's durable record and journal bytes.
- `manifestSha256` digests this host's Session manifest bytes.

They differ between hosts in the owner's own tests too: the same tests recorded on this host give
other digests than the committed macOS frames. So each digest is checked by how it is used instead.

## What

- **Preview.** It answers the macOS archivable preview (`mode` `archive`, last confirmed step
  `extract-crash-signature`).
- **Stale review.** An apply with the review the macOS frames record as stale is refused with
  macOS's code and words (`rejected`, "archive review is stale or blocked; refresh the Runtime
  preview"). The preview is unchanged afterwards.
- **Archive.** An apply with the current review archives the Job and publishes its Session
  (`state` `interrupted`, `catalogPublished`), as macOS answers. The one published `manifest.json`
  is the one `manifestSha256` names. Its `sessionDisposition` is `archived`, its user confirmation
  is the request's, and it offers no automatic recovery.
- **Finish publication.** A preview afterwards answers the macOS `finishPublication` preview with
  the confirmation. Finishing the publication again answers the same result and publishes no
  second manifest.
- **Unknown Job.** A preview of an unknown Job is refused as macOS refuses it (`notFound`).

## Found and fixed

`Host::job_archive` gave the archive owner `arkdeck_hoststore::runtime_now`. Every other Host
owner reads the Host's clock (`clock_now`). In production the two are the same function. In a
Windows test build, the Host's clock is the replay's fixed clock (`TEST_CLOCK`), so the archive
alone ignored it. It now reads `clock_now`, and macOS is unchanged.

## Coverage

`job.archive.preview` and `job.archive.apply` join `WINDOWS_MEASURED_LEAVES`. The coverage was
regenerated with `arkdeck maintainer contracts export` (two entries `partial` → `implemented` on
Windows), and `oracle.json` is not re-pinned.

## Left out: `workspace continuation submit|run` (needs a ruling)

The Rust control layer answers `health` with `providers: []` on every host (`arkdeck-control`'s
`health` arm). Swift's daemon listed its providers, and the `workspace-continuation` oracle's
health names `hdc` and `workspace`. The continuation draft requires the source Job's provider in
that list (`CLIWorkspaceContinuationDraft.prepare`).

This was run through the real CLI against the signed test daemon. The source Job was a completed
`target observe` (`observe.device@1`, provider `hdc`). Each of `workspace continuation inspect`,
`submit` and `run` was refused before anything was submitted (`operationUnavailable`, "the source
Job provider is not published by the current Runtime").

Publishing the registered providers in `health` would change the macOS daemon's `health` answer
and its recorded frame too. So this leaf stops here for a ruling, and the census row says so.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.

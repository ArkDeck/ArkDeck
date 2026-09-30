# TASK-XPA-005 — the Windows Job, Session and runner owners, consolidated

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase. This record indexes one branch,
`agent/xpa-005-windows-job-session-runtime-20260930`, that replaces six stacked PRs which kept
conflicting with main and with each other. It adds no behavior of its own beyond the resolutions
below. Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted, no
HDC or board was used, nothing installed was read or written, and no system setting was changed.
Host tests are not Windows acceptance.

## Source PRs and their run records

All paths are relative to this directory.

| PR | Slice | Head merged | Run record |
| --- | --- | --- | --- |
| #2361 | Job store owner, composed on the daemon | `c7d46031` (squash-merged to main as `ed5340a8`) | `windows-job-store-run.md` |
| #2373 | Session owner, publication and snapshot pages; `job.list`/`job.timeline` | via #2381 | `windows-session-pager-run.md` |
| #2376 | Job planner and admitter (`observe.device@1`) | via #2381 | `windows-job-admission-run.md` |
| #2381 | Job runner, cancel, result, evidence and start recovery | `6887bfd5` (the branch's start) | `windows-job-runner-run.md` |
| #2377 | Session removal, cleanup and export; `runtime.storage.*` | `0b5fea41` | `windows-session-cleanup-run.md` |
| #2379 | `artifact.quota` and the workspace mutation census | `23f1a306` | `windows-quota-workspace-census-run.md` |

The branch starts at #2381's head, which already held #2361 (up to `cc863b11`), #2373 and #2376.
It then merges #2361's last head, #2377, #2379 and `origin/main` in that order. There is no
rebase.

## Owner census

The Windows daemon's census, and the order `Authority::compose` composes in, is the macOS
`owner_census` restricted to what Windows composes. `Host::owner_census` (cfg windows) is the one
place that spells it:

`jobs, capabilities, targets, artifacts, storage, workspaceProjects, planning, traceCache`

That is followed by the HDC entries (`usbRegistryRelations`, `readOnlyHdcProvider`) when composed.
`traceCache` is composed only over a development root. Every Windows process test expects this
line: Artifact owner, Job admission, Job store, Session owner, Target owners, Trace export and
workspace projects.

## Resolution decisions

- **Compose order.** The Job store and its capability store (`jobs-state\capabilities`) come
  first, then the Target owners, the Artifact read owner, the Session owner and Artifact usage
  (storage), the workspace project owner, the planner, and the Trace cache. Nothing in `compose`
  depends on a later owner.
- **Session owner, from #2377.**
  - It is composed on the account root too, as `session-state` and `sessions` below `Agentd`.
  - A development root's owner is `isolated()` by the canonical spelling of its private children,
    so short-TEMP (`RUNNER~1`) and verbatim spellings compare equal.
  - `runtime.storage.*` is served, and the Artifact usage owner sits over the Artifact read
    owner's directory.
  - #2381's development-only `session_store` (with no account-root Session owner) is replaced.
- **Runner, cancel, result, evidence and start recovery** come from #2381 unchanged.
- **Workspace census, from #2379.** Workspace project and preset mutations on Windows now ask the
  Job owner's workspace census. It replaces the stack's `cfg(windows)` refusal.
- **`artifact.quota`** answers on Windows as on macOS, from the storage owner's `ArtifactUsage`.
  - `ArtifactUsage::quota` builds on both OSes.
  - The host has one `artifact_quota`.
  - #2379's Windows-only `ArtifactReadStore::quota` is removed.
  - `tests/windows_artifact_quota.rs` (the 27 oracle roots) and the Artifact process test read
    the same walk through `ArtifactUsage`.
- **`require_artifact_job`** is one macOS/Windows definition, from #2361: the Job store proves an
  Artifact's Job.
- **`trace.cache.purge`** keeps #2367's `purge_unavailable` refusal on Windows: preAdmission, zero
  dispatch.
- **Re-exports and notes are unions.** The platform crate re-exports both `PreparedSessionRemoval`
  and `PreparedTraceRemoval`. The hoststore Job owner note names both the snapshot pager and the
  workspace census as built on Windows.
- **Squash leftovers removed.**
  - `rust/README.md` kept the older Job store paragraph (the one-page `job.list` stand-in and
    "Nothing admits a Job on Windows yet") beside #2373's rewrite; it is dropped.
  - The Job store, runner and "still macOS-only" text now matches what the branch composes.
  - The auto-merge of main would have re-added #2361's stale lines; they are not taken.
  - No `[[test]]` entry or README heading is duplicated.
- **#2379's workspace process test and #2381's start recovery.** The test admitted Swift's
  workspace Job directly as `running`, with no record or Journal. The recovering daemon then
  stopped its start ("initial record does not match its transactional identity"). The test now
  admits the Job in `preflight`, persists it `running`, and writes the recorded Journal up to that
  transition. The restarted daemon still finds it running and refuses the mutations.
- **main.** `ed5340a8` is #2361's squash, and its tree is exactly `c7d46031`, already merged here.
  Its conflicts keep this branch's side. `40ab5a7d` (#2380, the Windows release candidate) then
  merged cleanly; it touches no Rust code.

## Local targeted checks

The environment set `CARGO_TARGET_DIR=D:/cargo-target/m1-stack` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` (the host-trusted development signer).

| Command | Exit |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli -p arkdeck-provider-workspace -- --nocapture` | 0 |
| The same tests with `TEMP`/`TMP` set to an 8.3 short path (`…\Temp\M1STAC~1`, which `GetTempPath2W` returns as is), as the CI runner's `RUNNER~1` | 0 |
| `python rust/scripts/generate-contract.py --check` | 0 |
| `python windows/scripts/generate-clientkit.py --check` | 0 |
| `sh scripts/check-sdd.sh` | 0 |
| `git diff --check` | 0 |

No test printed `SKIPPED` in either run. The ten dev-signed CLI tests all ran:
- GJ1 hops for Target, Job record, plan and submit, run/cancel/result, Artifact and Session;
- the workspace project hops;
- the Trace commands;
- the signed-daemon start and binding.

## CI

This is recorded by the follow-up once the PR's run completes.

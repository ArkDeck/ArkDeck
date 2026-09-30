# TASK-XPA-005 — WM1: the mutation authority and the start-up retention sweep on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, GJ-1. This slice closes two
fail-closed gaps the earlier Windows slices left:

- the Runtime's mutation-state proof;
- the start-up Artifact retention sweep.

Branch `agent/xpa-005-windows-mutation-retention-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written: the account's `%LOCALAPPDATA%\ArkDeck` is named, never
  opened.
- No system setting was changed.
- Host tests are not Windows acceptance.

## Scope (lead, 2026-09-30)

1. **Mutation authority.** Build the Job store's check that its mutation state is consistent with
   the Session root, so the Windows `MutationAuthority` proof no longer fails closed. Then enable
   what it unblocks: the capability-store and cleanup lock-order paths, and the mutation execution
   that runs use.
2. **Start-up Artifact retention sweep.** Run the sweep on Windows. The daemon tests that read
   recorded Artifacts seed non-expired fixtures instead of keeping the sweep off.

Measured with the Swift oracles, a real daemon across a restart, the dev-signed CLI and a
short-name `TEMP`.

## What

`arkdeck-hoststore`, now built on Windows:

| Item | Notes |
| --- | --- |
| `mutation_state_continuity` (`JobStore::require_mutation_state`, `require_retained_sessions`, `failed_publication_accounts_for`), `JobStore::session_verdicts` | The macOS code, unchanged. On NTFS a directory junction is refused as a symbolic link is (`symlink_metadata`, then `HostDirectory`'s reparse-point refusal). `require_retained_sessions_without_owner` (the cutover preflight's) stays macOS. |
| `MutationAuthority::prove` | One implementation; the Windows stand-in that always refused is removed. |
| `JobAdmitter::preauthorize`, `denial_code`, the outcome-gap repair before materialization | The macOS code: the Runtime-issued standing capability (`capability_policy::issue`), `validate_new_execution`, and the lineage repair (`job_lineage_repair::repair_outcome_gaps`). The workspace subject (`preauthorize_workspace`, XPA-011) and the Flash admission (AF-W1) stay macOS. |
| Tests | The continuity census's 12 tests run on Windows: owner-only directories through `test_private`; a junction in place of a symbolic link, made with `cmd /c mklink /J`, which needs no privilege. The Session cleanup's 3 lock-order tests (`session_cleanup_owner.rs`) now run on Windows. |

`arkdeck-agentd` (Windows):

- `windows_lifecycle::Authority::mutation_root` names the root the proof is anchored at. The daemon
  composes it beside the capability store (`Host::with_mutation_root`).
  - **The account's daemon:** its Job store's own `jobs-state`, spelled as the root resolves it, as
    the macOS production composition names Swift's state directory.
  - **A development root:** the account's `jobs-state`, which its own Job store never is, as the
    macOS standalone and unacknowledged isolated owner name the installed root. The proof refuses
    on that path comparison, before anything of the account's root is read. No development
    authority is composed: it needs a managed HDC, and `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY`
    still refuses the start.
- `capability.list` and `capability.inspect` answer from the capability store (before this they
  were macOS-only).
- The census adds `mutationAuthority` in its macOS position:
  `jobs, capabilities, mutationAuthority, targets, artifacts, storage, workspaceProjects,
  planning, traceCache`.
- The runner's mutation execution (`job.run`) already took `self.authority()`. With a root named,
  it now proves the state instead of refusing it.
- `main.rs`: the start's `collect_expired_artifacts` runs on Windows after the Job recovery and
  before serving, as on macOS.
- Daemon tests that lay down recorded Artifacts now use `unexpired`: each retention deadline is
  laid down a century later, since every answer they compare is read from their own root. The
  affected tests are `windows_artifact_owner_process`, `windows_job_runner_process` and
  `windows_trace_export_process`.

## Oracle and corpus measurements

1. **Continuity census** (the macOS unit tests, on NTFS; 12 passed, 1 ignored measurement):
   - an override root and retired `AuthorizationUsage` are refused without changing the source;
   - strict-JSON Job directories without a checkpoint;
   - an index-only mutation history;
   - retained Sessions (the pointer-input Swift oracle's Journals: a read-only probe passes; a
     gesture, an unknown outcome and a torn tail refuse);
   - configured Session roots and invalid Manifests;
   - nested production Sessions and case aliases (NTFS is case-insensitive, so the aliased branch
     runs);
   - junctioned `AuthorizationUsage` and `Sessions`;
   - an entry gone since the listing;
   - the verdict cache: every identity part, a file not yet settled, and appends between scans.
2. **Lock order** (`session_cleanup_owner::lock_order_tests`, 3/3): a cleanup holding the storage
   lock, with an admission and with a publication, both finish. A cleanup waiting for the storage
   lock holds no activity guard. Admission now proves the state under a real `MutationAuthority`.
3. **Retention census** (`tests/windows_artifact_retention.rs`, 2/2): the macOS cases, over
   `observe.device@1` Jobs admitted in process (their dispatcher fails the test if called) and
   cancelled.
   - Kept, as the census cannot prove them settled: the active, owing, torn-journal and
     unexplained Jobs, which keep their lapsed rows.
   - Reclaimed: the settled Job's and the unowned legacy directory's rows.
   - Once the active Job settles and the cleanup settles, theirs go too.
   - An unreadable cleanup ledger reclaims nothing.
   - Beside them, the recorded Swift observe-device store:
     - The two terminal Jobs whose Sessions were published lose their four lapsed Artifacts.
     - The failed Job whose Session publication failed (`sourceIntegrityFailed`, never finalized)
       keeps its Artifact.
     - The Job its unknown outcome parked keeps the row planted beside it.
4. **Mutation root** (`host_tests.rs`, Windows):
   - No root named: no authority.
   - Another root named: `recordUnreadable`.
   - The Job store's own root named: proved.
   - `AuthorizationUsage` beside it: refused.
   - A junctioned `Sessions`: refused.
   - With both removed: proved again.

## Process and CLI evidence

`arkdeck-agentd/tests/windows_mutation_retention_process.rs` runs the real daemon over a
development root holding the recorded observe-device store and its Artifacts as recorded, with
retention lapsed on 2026-09-21. The test reads:

- **The first start:**
  - `arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, storage,
    workspaceProjects, planning, traceCache`;
  - `recovered 1 active job(s); unknown outcomes parked`;
  - `reclaimed 4 expired artifact(s)`.
- **The swept Jobs:** index rows and payloads are gone. `job.result` of a swept Job answers with
  no Artifact.
- **The kept Artifact:** the unpublished Job keeps it; `artifact.list` lists it, and
  `artifact.quota` counts exactly its bytes.
- **The capability store:** `capability.list` answers from it, and `capability.inspect` of an
  unknown capability is refused.
- **Restart:** a second daemon sweeps nothing more (no `reclaimed` line, no sweep failure), and the
  whole Artifact tree is byte-identical.
- **Dev-signed CLI** (`ARKDECK_DEV_SIGNER_THUMBPRINT`) — **ran**:
  - `arkdeck artifact list --job <swept>` returns no items;
  - `arkdeck artifact list --job <unpublished>` returns one;
  - `arkdeck artifact quota` and `arkdeck capability list` answer.

Every other Windows daemon test passes with the sweep on and `mutationAuthority` in its census.

**Short-name `TEMP`:** with `TEMP`/`TMP` set to `C:\Users\fuhan\AppData\Local\Temp\LONGTE~1` (an
8.3 alias, as the hosted runner's `RUNNER~1`), `cargo test -p arkdeck-hoststore -p arkdeck-agentd
-p arkdeck-platform -p arkdeck-cli` passes: 241 test binaries, no `SKIPPED` line. That run
includes:

- the 12 continuity and 3 lock-order tests;
- `windows_artifact_retention`;
- the mutation-root host test;
- every Windows daemon process test.

Every test root is the resolved spelling of the temporary directory.

## Not reached, and why

No device mutation reaches admission on Windows yet. Planning one needs the HDC provider, and the
Windows HDC tuple is not registered. The proof, the preauthorization and the consumption are
measured in process and through the lock-order tests. Through the daemon, the measurements are the
composed authority (census), the capability store, and the proof's refusal of a development root.

## Follow-ups (not in this slice)

- **The HDC tuple gate:** a device mutation over the wire on Windows, then the account daemon's
  proof end to end.
- The workspace subject's preauthorization (XPA-011) and the Flash admission (AF-W1).
- The cutover preflight (`require_retained_sessions_without_owner`) stays macOS.

## Local checks

Run on Windows 11 x64 with `CARGO_TARGET_DIR=D:\cargo-target\s1-mutation` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-control -p arkdeck-contract -p arkdeck-cli` | 0 | all pass; no `SKIPPED` line |
| `cargo test --workspace` | 0 | all pass |
| `python rust/scripts/check-readonly.py --bin-dir <target>/debug` | 0 | PASS, including the signed matrix |
| the same four crates with a short-name `TEMP` | 0 | 241 test binaries pass; no `SKIPPED` line |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and Ubuntu cannot be built here, so I reread the cfg pairings by hand. CI decides.

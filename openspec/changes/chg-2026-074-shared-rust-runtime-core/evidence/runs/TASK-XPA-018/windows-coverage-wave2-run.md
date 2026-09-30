# TASK-XPA-018 — Windows CLI coverage, wave 2 (2026-09-30)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched. Each daemon ran over a fresh development root below the temporary directory, holding
  recorded Swift state.
- **Base:** protected `main` `86d2f2b8` (#2398).

## What was measured

The leaves below are now in `WINDOWS_MEASURED_LEAVES`. Each ran through the real CLI against a
copy of the daemon signed with the host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`
set; no test reported `SKIPPED`), and each answered its complete contract. Each test asserts that
what it measured is Windows `implemented` in the coverage manifest the CLI renders.

| Leaves | Test | What it proves |
| --- | --- | --- |
| `runtime health`, `operation describe`, `example`, `validate` | `arkdeck-cli/tests/windows_signed_runtime.rs` | health names the contract identity, Catalog digest and published methods; `observe.device@1` is described, gives a submittable example, and its empty typed inputs validate with no findings |
| `job list`, `show`, `status`, `events`, `timeline` | `arkdeck-agentd/tests/windows_job_store_process.rs` (existing CLI hops) | the store's answers for the recorded `observe.device@1` Jobs, after a restart; list and timeline cursors read on across it |
| `job result`, `evidence`, `wait`, `cancel` | `windows_job_runner_process.rs` | all 7 recorded successful `job.result`/`job.evidence` answers equal Swift's; `job wait` on the finished Job answers `succeeded` at once; `job cancel` closes the queued Job |
| `job reconcile`, `agent status`, `agent list`, `human-action show`, `human-action list` | `windows_reconcile_agent_process.rs` | Swift's physical-assistance records; the lists equal the pages the pipe answers |
| `artifact list`, `inspect`, `read`, `export`, `quota` | `windows_artifact_owner_process.rs` (existing CLI hops) | the in-process owner's answers for a recorded Job's Artifacts; export writes the recorded bytes |
| `capability list` | `windows_mutation_retention_process.rs` | equals the pipe's answer (nothing issued) |
| `runtime storage status`, `policy`; `session list`, `show`, `pin`, `unpin`, `export preview`, `export apply`, `cleanup preview`, `cleanup apply` | `windows_session_owner_process.rs` | Swift's `observe.device@1` Sessions: export writes the Manifest; a policy the Sessions exceed makes the cleanup reclaim the unpinned one and keep the pinned one; unpin releases it |

Before this wave, only `job reconcile`, `agent status` and `human-action show` were run through
the CLI in some of these tests. The rest are new CLI hops in this PR.

## Results

- **Coverage** (`maintainer contracts export`): Windows `implemented` 18 → 52, `partial`
  116 → 82, `notImplemented` 6, unset 116.
- **Oracle.** The six pins of the coverage digest in
  `rust/tests/fixtures/maintainer-contracts/oracle.json` now name the regenerated file, by the
  same substitution as #2353 and #2378.
- **Method census** (`rust/scripts/windows-method-census.py`, debug daemon of this tree): 63/105
  answered by a composed owner (11 results, 52 owner refusals), 0 non-conforming (exit 0), and 42
  with no owner.
- The dashboard `evidence/windows-remaining.md` is refreshed with these numbers.

## Left `partial`, and why

- `job plan`, `job submit` and `job run`: a new device Job is refused without a registered HDC.
  The deduplicated retry answers, but a leaf counts only for its whole contract.
- `agent run|resume|abandon`, `human-action resume`, `target adopt|availability`: each reaches
  a Target through the HDC.
- `capability inspect`: nothing can be issued on Windows without a device Job, so only its
  refusal was seen.
- `runtime storage root`: no Windows run has moved the Sessions root yet.
- `workspace preset register`: a symbol preset registers, but other kinds need the DevEco owner.
  It was kept `partial` as in #2378.

## Delegated minor decisions (pending the next rulings batch)

1. The owner tests that already hold recorded Swift state carry the new CLI hops and the coverage
   check (a small `assert_measured` helper per file, as each file already carries its own `cli`
   and `pwsh` helpers). This avoids copying their fixtures into the CLI crate.
2. The feature `health` counts as measured by `runtime health`, its target command.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`,
  `CARGO_TARGET_DIR=D:/cargo-target/w1-coverage`.
- `cargo fmt --all --check`: clean.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `cargo test -p arkdeck-agentd -p arkdeck-cli`: 109 result lines ok, 0 failed, no `SKIPPED`.
- The same run with `TEMP`/`TMP` set to an 8.3 short path on C: (`…\SCRATC~1\SHORTP~1`): 109 ok,
  0 failed.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings; `git diff --check`: clean.

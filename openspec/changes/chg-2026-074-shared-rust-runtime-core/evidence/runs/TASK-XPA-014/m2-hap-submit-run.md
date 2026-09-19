# Rust HAP admission: `job.submit` admits `debug.hap@1` (M2, GJ-2 path)

Status: the isolated Rust daemon admits `debug.hap@1` under the Runtime capability
Swift issues for it. The HAP runner is not part of this slice: an admitted HAP Job
waits in `preflight`, `job.run` refuses it before its run starts, and nothing is
dispatched or consumed. Every answer and file compared here comes from the Swift
debug-hap oracle over the shared fake HDC; none of it is device, signing or GJ-2
acceptance evidence.

Base: protected `main` `81957589`, through the Import lifecycle PR #1987
(`92e2d667`) and the HAP plan PR #1993 (`6c03ceba`), neither merged yet. This slice
is stacked on both and needs both: HAP admission materializes the HAP plan of #1993,
which resolves the Import leases and holds of #1987. Merging this slice brings their
content; if it merges first, #1993 and #1987 should be closed rather than merged.

| Already on `main` | This slice | Still remaining (`debug.hap@1`, M2) |
|---|---|---|
| The capability store's writes (#1963); pointer plans (#1964); pointer admission under automatic Runtime capabilities with the cross-capability lineage scan and the device hold (#1968); pointer execution with consumption before the first mutation's intent (#1984); the published `admissionDenied` shape of `job.submit` (#1965); the HAP Provider (#1951); the native debug-hap oracle | `job.submit` admits `debug.hap@1`: the automatic capability named by the exact inputs and the entry package's owner-validated facts (both of Swift's envelopes reproduced), the lineage block before issuance, a named capability used as named, refusals as `admissionDenied` with the zero-dispatch proof. `job.run` and `agent.run` keep HAP from running. The HAP replays share one harness | The HAP runner (consume before the first mutation's intent, the success and awaiting-readback lanes, failure compensations and `validateContinuation`), the cleanup-debt ledger and `cleanupDebt.*`, HAP `job.result`/`job.evidence`, recovery (L.1 item 13), GJ-2 on the isolated daemon and on hardware |

## Production change

- `job_plan.rs`: `debug.hap@1` joins the operations the Rust planner materializes,
  which `JobPlanner::descriptor` also admits; the plan-only exception is gone.
  Nothing else in admission changed. The existing Swift `preauthorize` port now
  serves HAP as Swift serves it:
  1. `validateMutationState`, then `admitAgainstDeviceHold`: HAP is not
     session-scoped, so it takes no hold; another client's live hold still refuses it.
  2. The policy `standingCapability`; the HDC provider has no execution blocker.
  3. The query: `debug.hap@1`, `deviceMutation`, the materialized identity, binding
     revision and plan digest, every input, and the primary facts `artifactId`,
     `artifactSha256`, `artifactByteCount` from #1993's owner-validated
     materialization.
  4. A capability the caller names is used as named. Otherwise automatic issuance:
     the lineage scan across every capability first, then the generation walk, then
     an install of `CAP-RT-POLICY-<fp40>-G<n>`. The envelope is 10000 uses and
     30 days, with exact inputs, a constraint per scalar input, issuer
     `catalog:<digest>:debug.hap@1` and the exact binding revision, and no pinned
     plan or Artifact facts.
  5. `validateNewExecution`. A refusal is `admissionDenied`, with Swift's message
     and `{"phase": "preAdmission", "newDispatchCount": 0}`.
  6. The Job runs the request naming the capability and keeps the caller's as its
     original submission. It has no admission evidence, and its journal holds
     `jobCreated` and `queued -> preflight`.
- `job_run.rs`: `executes(operation)` names what the runner executes (the analyzer,
  and the device operations of `device_run`). HAP is not among them, so `job.run`
  answers `rejected`, "job <id> runs debug.hap@1, which the Rust Runtime does not
  execute yet", with the zero-dispatch proof. No use is consumed.
  `operation_unavailability` keeps reporting HAP `operation_not_supported`.
- `job_admission.rs` `submit_for_agent` and `agent_execution.rs`: an agent execution
  starts the Job it comes to own at once. Admitting a HAP there would strand the
  execution in `jobOwned` behind a Job that cannot run. So `agent.run` is refused
  before admission, as it was before this slice, with the code `admissionDenied`
  and "debug.hap@1 is not executed by the Rust Runtime yet". The gate lifts itself
  once the runner executes HAP. This fail-closed choice is not a Swift behavior
  (Swift runs the HAP) and is for the maintainer to confirm.

Not ported, as in the pointer admission:
- `repairProvablyTerminalCapabilityOutcomeGaps` is recovery (L.1 item 13).
- Superseding recovery epochs are not read by the lineage scan, so Rust blocks at
  least everything Swift blocks.
- The host-wide HDC lifecycle interlock does not apply: the Rust daemon serves
  `runtime.hdc.status` only.

## Checks

Commands in `rust/` of this worktree (`/private/tmp/arkdeck-hap-submit-20260919`), with its own
`rust/target`, on 2026-09-19 CST.

| Check | Command | Exit | Result |
|---|---|---|---|
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| Targeted | `cargo test --locked -p arkdeck-hoststore --test debug_hap_submit --test debug_hap_plan --test pointer_input_submit --test pointer_input_run --test job_admission --test job_plan` | 0 | debug_hap_submit 5, debug_hap_plan 2, job_admission 1, job_plan 3, pointer_input_run 9, pointer_input_submit 4 passed |
| Workspace | `cargo test --workspace --locked --no-fail-fast` | 101 | 857 passed, 1 failed, 16 ignored in 114 suites. The one failure, in both workspace runs, is `arkdeck-platform` `verified_process::output_overflow_kills_and_reaps_the_child`. Its assertion is a two-second wall-clock bound (2.14 s and 2.02 s here). That crate is unchanged against `origin/main`. Alone, it passed at 14:44 (6/6 in 0.59 s, load 8.6). It failed again alone at 14:54 (2.37 s) at load 119, while other sessions ran Swift builds: a load flake outside this diff. The gate below runs the workspace again |
| Clippy, macOS | `cargo clippy --workspace --all-targets --locked -- -D warnings` | 0 | Clean; the HAP tests and `job_run` are macOS-only and are linted here only |
| Clippy, Linux | `cargo clippy --workspace --all-targets --locked --target x86_64-unknown-linux-gnu -- -D warnings` | 0 | Clean |
| Clippy, Windows | `cargo clippy --workspace --all-targets --locked --target x86_64-pc-windows-msvc -- -D warnings` | 0 | Clean |

`tests/debug_hap_submit.rs` runs with the Runtime's own `MutationAuthority` at the
oracle's fixed root (`/private/tmp/arkdeck-hdc-oracle`, under its lock). Its
dispatcher fails the test on any call.
1. It replays all 15 plans and 8 submissions: every answer is Swift's, exactly.
   - The capabilities installed are Swift's two envelopes (`…4841B6E9…-G1`,
     `…828AE370…-G1`), in install order. Each keeps its whole budget, and no ledger
     is written.
   - For each of the 8 Jobs, these members equal Swift's persisted record:
     `jobID`, `request` (naming the capability), `originalSubmissionRequest`,
     `operationReference`, `catalogDigest`, `providerID`, `createdAtUTC`,
     `actualEffect` and the three materialized members. The state is `preflight`,
     with no admission evidence.
   - The journal is byte for byte Swift's first two events.
   - The index's admission rows (Job, key, request hash, sequence, creation) and its
     schema match Swift's.
   - `job.run` refuses all 8 with the zero-dispatch proof.
   - `agent.run` of the installed case is refused before admission.
   - Neither writes a Job or capability file, and the fake records no call.
2. It replays the submissions again, and in place of each run it writes the use that
   run took through the store's own `consume` and `recordOutcome`, with Swift's
   recorded values and the run's query. Each admission leaves the use count
   unchanged, and `packageSet.submit`'s install folds the installed run's use into
   the checkpoint.
   - `runtime-capabilities.json` and `.ledger` are then Swift's byte for byte, with
     Swift's entries and modes.
   - After the last use's `outcomeUnknown`, a new HAP is refused on this binding
     whatever its inputs: both the entry package alone and the package set (another
     capability) get `admissionDenied` with "automatic Runtime target lineage is
     blocked: lineageBlocked(\"target binding has unresolved capability
     CAP-RT-POLICY-4841B6E9B1C282313D918AC38272E247638E6480-G1 use 7 outcome
     outcomeUnknown\")". Nothing is written.
3. A HAP naming the issued capability is admitted under it without another install.
   A HAP naming an unknown one is refused with "capability denied
   [denial:capabilityNotFound]: capabilityNotFound(\"…\")".
4. A HAP whose entry and feature packages are Imports is admitted. The admitted Job
   then references both, so each Import inspects as `referenced` by that Job, and
   its release is `resourceConflict`.
5. An admitted HAP cancelled at `preflight` closes as `cancelled`. The capability
   files are unchanged, and no use is spent.

`tests/debug_hap_plan.rs` keeps its 15-plan replay and its Import hold scenarios.
Its submission refusal moved to `debug_hap_submit.rs`. Both files share
`tests/support/debug_hap.rs`: the root, the lock, the non-dispatcher and the Import
helper. Mutation checks, reverted before the commit:
- Dropping the facts from the admission query fails replays 1 and 2.
- Calling the unguarded `submit` from the agent path fails replay 1.

Logs (`$S` is `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs`):
`$S/hap-submit-targeted.log`, `$S/hap-submit-workspace.log` (first run, before the cancellation
test), `$S/hap-submit-workspace2.log` (final code), `$S/hap-submit-platform-rerun.log`,
`$S/hap-submit-clippy-{macos,linux,windows}.log`.

## Unified gate

Command, from the worktree root:
`ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`

Run 1 was on `c56ada0e`, merge base `81957589`, 2026-09-19 14:55:54–15:23:18 CST. The
stack changes 50 files, which select the swift, rust and design-system lanes. It
exited **1**, on a load flake outside this diff. At the coordinator's request it is
not rerun on this overloaded host; a serialized rerun on a quiet host is pending.

These passed before the failure:
- `scripts/ci/test_plan.py` (37) and `scripts/test_agent_pr_workflow.py` (12);
- `check-sdd`: 0 errors, 0 warnings, 121 acceptance IDs, and
  `check_union_merge: ok`;
- the catalog generator's tests (49) and its `--check`;
- the design system, 83/83, and `test_run_swiftpm.py` (13);
- the full SwiftPM lane, 2687 tests with exit 0, and the serialized
  process-identity race (1) and viewer-scale (5) lanes;
- `generate-contract.py --check`, `cargo fmt --all --check`, and
  `cargo clippy --workspace --all-targets -- -D warnings`.

`workspace-tests.py` stopped at its first failing test binary, after 87 suites:
702 passed, 1 failed, 16 ignored. `debug_hap_plan` passed 2/2 and `debug_hap_submit`
passed 5/5.
- The failure: `arkdeck-platform` `tests/verified_process.rs`
  `output_overflow_kills_and_reaps_the_child`, `assertion failed: started.elapsed() <
  Duration::from_secs(2)`; the binary took 3.74 s.
- The platform crate is unchanged against `origin/main`.
- Five unified gates were running at once: load about 40 on 8 cores, 119 earlier.
  The same test failed both standalone workspace runs above.

The stop also left these unreached:
- the rest of the workspace test binaries, which the standalone workspace run above
  covers (857 passed apart from this test);
- `rust/scripts/test_contract_checks.py`, `rust/scripts/check-contracts.py`,
  `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions`.

Log: `$S/hap-submit-gate.log`, SHA-256
`0f9ca0b52881fe0bb93508d3634f66ba24db36fb40591283c1a9ec81a35c620f`. The amended commit
that records this section changes only this file and the commit message; the gated
tree is otherwise identical.

## Not run

- HAP execution, consumption, compensations, `cleanupDebt.*` and HAP result readers:
  the next slices. No `job.run` of a HAP dispatches here.
- Recovery (L.1 item 13): gap repair, recovery epochs, settling `outcomeUnknown`.
- Any device, HDC server, signing or the installed Runtime; GJ-2 acceptance.
- The rest of the unified gate after the load flake (see above), pending the
  coordinator's serialized rerun.
- `scripts/check-corpus-replay.py` over the debug-hap fixture: the Rust daemon
  cannot run HAP Jobs yet, so its run exchanges would be refused.

## Re-stacked on the rehung HAP plan (2026-09-19)

After #1987 merged, the HAP plan branch (#1993) was re-hung onto protected main `2a4a3441`
(merge `c967a77b`, head `3128de59`). This slice was moved with `git rebase --onto 3128de59
6c03ceba` without conflict. Targeted rerun on the moved head: `cargo test --locked -p
arkdeck-hoststore --test debug_hap_submit --test debug_hap_plan --test job_plan --test
job_admission --test pointer_input_submit --test agent_execution` — 5, 2, 3, 1, 4 and 1 passed.
The gate recorded above (exit 1 on the host-load timing test only) is superseded by the
serialized rerun below.

Serialized rerun on `9d74a9c4` (over the HAP plan head `3128de59`, merge base `2a4a3441`),
2026-09-19 15:42:23–15:50:18 CST: **exit 0**. SwiftPM 2691 tests without failure; cargo 905
passed, 0 failed, 16 ignored; design-system 83/83; contract checks, `check-sdd`, `cargo deny` and
`cargo vet` passed. Log `…/scratchpad/logs/hap-submit-gate-r2.log`, SHA-256
`f28c01d1ad397b44ff097a52271b790d5d233775e81d352f249946189783f8a2`.

## Rehang after #1993 merged (2026-09-19)

The HAP plan merged as #1993 (`521c8fad`). This slice was moved with `git rebase --onto origin/main
3128de59` without conflict (its commit does not touch the plan's run record, the only difference
between `3128de59` and the merged plan). Base: protected main `521c8fad`. The gate is rerun on this
head (below).

Gate on the rehung head `6ec4c620` (merge base `521c8fad`), 16:10:28–16:15:07 CST: exit 0 (log
`…/scratchpad/logs/hap-submit-gate-r3.log`, SHA-256
`ef7fc0c79583cb1155d9e9fe4d2ddffe691e57dfc7957dce298f44353c3ed6c6`).

## Rebase onto protected main `5ff8d9b5` (after #1998 merged)

Port rules (#1998) also extended `job_plan.rs`'s `MATERIALIZED`; the rebase conflicted only there
and now lists all nine operations (this slice's doc comment, main's two `port-forward.*` entries and
`debug.hap@1`). Targeted rerun on the union: `debug_hap_submit` 5, `debug_hap_plan` 2,
`port_forward` 4, `pointer_input_run` 9, `pointer_input_submit` 4, `job_plan` 3, `job_admission` 1,
`agent_execution` 1 — all passed. The gate is rerun on this head (below).

Gate on `073aa419` (merge base `5ff8d9b5`), serialized, 2026-09-19 16:36:39–16:40:44 CST: **exit 0**.
Lanes: rust (the Swift oracle test is on main since #1993). Cargo 922 passed, 0 failed, 16 ignored;
published and candidate contract checks, `check-sdd`, `cargo deny` and `cargo vet` passed. Linux and
Windows target clippy with `-D warnings`: exit 0. Log
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/hap-submit-gate-r4.log`,
SHA-256 `792ce5f87ca35417d30ab70eb867467f222329f31a14bd827eebe410c9b30925`. A trial merge with protected
main `0fe9bb57` is conflict-free.

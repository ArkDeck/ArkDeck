# TASK-XPA-014 — the Rust owner runs `deploy.native-library.app-owned@1` as Swift does: the library verified on the host, the send believed through its staging readback, a failure rolled back and cleaned up under the use the Job consumed, a failed cleanup owed in the debt ledger (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `3828f2ed` (#2023). The slice was written
stacked on the native plans and admission (#2011) and moved onto main after #2011 merged (`git rebase
--onto origin/main 9bd9341b`), then onto #2012–#2017 without conflict. The screen-sequence run (#2020)
adds its operation to the same lists and step lanes and gives `HdcComposition` a `receive_root`, so
while #2020 was open this slice was stacked on it (resolution below); after #2020 merged it was moved
onto main with `git rebase --onto origin/main` over its copy of #2020, and onto #2022–#2024, without
conflict. It is the second slice of
`deploy.native-library.app-owned@1` (M2, GJ-3): its runs. The success lane, the failure lane and the
cleanup debt ship together: a failure the Runtime could not roll back would leave the new library
published, and a cleanup that failed silently would leave the staging behind. Every answer and file
compared here is replayed from Swift's native-library oracle, recorded over the shared fake HDC in a
fixed-root host fixture. None of it is device evidence, installed-Runtime activation or GJ-3
acceptance (POL-VERIFY-001, POL-MODE-001).

The 2026-09-15 branch `agent/xpa-014-native-library-run-20260915` (`93bf76b8`) did this slice on the
superseded debug-HAP stack and conflicts with main in seven files. It is not rebased: this slice
re-lands it on the HAP runner of #2005 (its consumption rule, run lane, failure lane and
`cleanup_debt.rs`), taking `device_native.rs` and the run lane's native parts as the reference.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (`deploy.native-library.app-owned@1`, GJ-3) |
| --- | --- | --- |
| The native-library oracle; the provider's native actions and verdicts (#1955); the durable mutation runner, its account-fixed root and settled outcomes (#1984, #1998); the HAP runner with its failure lane and cleanup debt ledger (#2005); the native plans and admission (#2011); the screen-sequence run (#2020), whose lists and lanes this slice shares | `deploy.native-library.app-owned@1` runs: the host verification steps, the library resolved and read again for each device step against the materialized Target, the send believed through its staging readback, the two reports, the rollback and compensation cleanup on failure, the plain cleanup debt of a failed optional cleanup, `job.result`/`job.evidence` of native Jobs, operation availability with the helper. The debug HAP and native replays share one harness | The daemon's helper composition (a bundled, verified arm64 helper); recovery, now ruled (#2016: port the decision package's carriers), and after it `cleanupDebt.list`/`continue` with its recovered row; GJ-3 on the isolated daemon (the isolated root has no mutation authority) and on hardware |

## Why

GJ-3 replaces an application's native library through `deploy.native-library.app-owned@1`. The
Rust owner planned and admitted it but ran no such Job. A deployment rewrites the application's own
library directory; it may believe the device only through readbacks, and a failure after the publish
must put the previous library back. So the runs need the failure lane and the debt ledger as much
as the success lane.

## What changes

- **The run lane** (`device_run.rs`, `device_steps.rs`):
  - `deploy.native-library.app-owned@1` joins `DEVICE_OPERATIONS`, so `job.run` runs it and
    `agent.run` admits the deployment it starts.
  - **The host steps** (`device_native.rs`, Swift `verifyHostInputArtifact`): `verify-elf-locally`
    and `hash-library` resolve the library's lease again (an Import through its owner) and bind it
    to the Target; its bytes must be the expected ABI's code-signed ELF, still the digest and size
    the lease records. The timeline names what was verified (`<step> abi=… buildId=… sha256=…`).
    The refusals are Swift's (`native host verification cannot read the leased ELF: …`, `… rejected
    the leased ELF: …`, `native Artifact bytes drifted from the leased hash/size`); what the lease
    itself refuses Swift throws past the Job's lanes, which here is the run's internal failure.
  - **The library.** Each provider step is given the library (`step_inputs`): its lease is resolved
    again before the step's Target facts, as Swift's step loop does, and the library read for the
    provider, which names the step's action from it and verifies it again.
    (`resolve_inputs` now returns through `leased_inputs`, which also serves the HAP.)
  - **The Target.** Each device step runs only against facts that still name the identity and
    binding revision its plan was materialized for (Swift `validateMaterializedTargetFacts`); the
    port rules' compensation now shares that one check (`materialized_facts`).
  - **The awaiting-readback lane.** The send succeeds as a dispatch (`dispatched send-to-staging;
    awaiting readback`), and the required staging readback after it is what may believe it: the
    readback pairs are now Swift's `readbackPairs` in full.
  - **The products.** `publish-report.json` (the publish) and `verification-report.json` (the loader
    readback) are facts products.
  - **The use.** The Job consumes its one capability use before the send's intent; every later
    mutation continues under it (#2005's rule), and it is settled with the Job.
- **The failure lane** (`device_native.rs`, Swift `compensateNativeLibrary`), inside the step loop,
  after a required step's confirmed failure (a refused authority included, as Swift catches both):
  - the Target's facts are proven again;
  - once the publish was attempted (it completed, or the failed step is it or follows it),
    `rollback-native-library` restores the previous library from its backup (`native deployment
    failure restored previous library`); a rollback that fails is the Job's failure (`native
    rollback failed closed: …`), and nothing more is removed;
  - `cleanup-native-library-compensation` then removes what the deployment staged (`native
    compensation cleanup complete`); one that fails is owed (`native compensation cleanup debt:
    …`), and parks the Job only when its outcome is unknown;
  - otherwise the Job fails with its original failure (`native deployment failed: …`).
  - Both are ordinary steps of the Job (step intents, not the debug HAP's declared compensations),
    under the use it consumed, consuming nothing; each still requires the dispatcher to prove the
    executable it retained, as every mutation this Runtime dispatches does.
- **The debts** (`cleanup_debt.rs`): Swift's `recordCleanupDebt` is now `cleanup_debt::append`, a
  plain append; the HAP's compensation bookkeeping (`record_compensation_debt`) keeps its
  once-per-Job-and-step guard over it. A failed optional cleanup of an operation other than the HAP
  (here the native `cleanup-staging-and-backup`) is skipped, owed with the exact action that failed,
  and the Job's residue is counted again from the ledger (`refreshResidueCount`), each a best effort
  as in Swift; the Job succeeds. A failed compensation cleanup is owed the same way.
- **The readers** (`job_result.rs`): `job.result` and `job.evidence` read native Jobs (their step
  kinds those the record kept, as Swift reads every operation but the HAP and flash).
- **Availability** (`operation_availability.rs`, `arkdeck-agentd` `host.rs`): native joins the
  mutations that need the mutation owner, the daemon's tool-identity probe covers it, and without the
  verified helper it is `provider_tool_unavailable`, "bundled arm64 OpenHarmony code-sign helper
  cannot be verified" (Swift `runtimeAvailability`). The daemon composes no helper, so the isolated
  daemon lists it unavailable, as its planner refuses it.
- **The harness** (`tests/support/hdc_oracle.rs`, new): the owners a daemon composes over the
  shared fake HDC's fixed root (moved from `tests/debug_hap_run.rs`, now with the helper where the
  oracle composed one), and the replay of every exchange before an oracle's debt continuations with
  its assertions, which `tests/debug_hap_run.rs` and `tests/native_library_run.rs` share. Before
  each moded run it clears the fake's application state (`device-installed`, `device-running`,
  `device-published`), as both Swift oracles do. The plan and submission tests of the previous slice
  use the same owners; their `job.run` refusals give way to `agent.run` admitting the deployment.

## Checks

Commands in `rust/` of this worktree (`/private/tmp/arkdeck-native-library-run-20260919`), with its
own `rust/target`, on 2026-09-19 CST.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| The native runs | `cargo test --locked -p arkdeck-hoststore --test native_library_run` | 0 | 4 passed. See below |
| The debug HAP runs, on the shared harness | `cargo test --locked -p arkdeck-hoststore --test debug_hap_run` | 0 | 7 passed; the replay still answers all 59 exchanges and matches the fake's first 103 calls and every file |
| Plans and submissions | `cargo test --locked -p arkdeck-hoststore --test native_library_plan --test native_library_submit --test debug_hap_plan --test debug_hap_submit --test job_plan` | 0 | 2, 3, 2, 6 and 3 passed |
| The three crates | `cargo test --locked --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak` | 0 | 394 passed, 0 failed, 12 ignored in 53 suites (after `cargo build -p arkdeck-cli`, which `import_publication_process` spawns) |
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| Clippy, macOS / Linux / Windows | `cargo clippy --locked --workspace --all-targets [--target x86_64-unknown-linux-gnu \| x86_64-pc-windows-msvc] -- -D warnings` | 0 | Clean |

`tests/native_library_run.rs`, at the oracle's fixed root under its lock, with the Runtime's
`MutationAuthority` over the account-fixed Job root:
1. The replay: every exchange before `cleanupDebt.*` (37: nine plans, five submissions, five runs and
   a refused rerun, each Job's result, evidence and Artifact list, and the two capability reads) is
   answered as Swift answered it, message included. The fake received Swift's first 210 calls in
   order (211–225 are the continuation's). Each Job consumed its one use before its send. Everything
   the replay leaves below the root is Swift's byte for byte: the index, every Job file, Artifact,
   Session file and the capability store; the four Jobs the continuation leaves alone at their
   persist counts (deployed and unattested 13, loaderFailure 15, targetAbsent 10); `cleanupFailure`
   as it stood before the continuation (version 14: the recovery load's `recovered: journal clean`
   and the settled residue removed, its journal unchanged); the ledger without its settlement
   members.
2. Three faulted runs of the oracle's `loaderFailure` Job:
   - a rollback whose move never happens: the Job fails with `nativeRollbackVerificationFailed: …`,
     the timeline names `native rollback failed closed: failed(…)`, no compensation cleanup is sent
     and nothing is owed; the use is settled `confirmed`/`failed`;
   - a compensation cleanup that leaves the staging: the rollback restores the library, the cleanup
     fails with `cleanupDebt: …` and is owed (its staging path, reason and `hdc.cleanupNativeLibrary`
     action), the residue is counted 1, and the Job fails with the loader failure;
   - a compensation cleanup whose outcome is lost: owed with `outcomeUnknown(…)`, and the Job parks
     in `waitingForRecovery` with the cleanup's intent outstanding; the use is settled
     `outcomeUnknown`.

Mutation checks, each reverted before the commit, each failing the replay: without the failure
lane's compensation; without the debt of a failed optional cleanup; without the send's readback pair;
without the host verification.

## Local targeted checks

Since #2015 (merged during this slice) the unified gate is the PR's GitHub CI; locally only targeted
checks run, without the gate lock, in this worktree with its own `rust/target` and
`CARGO_BUILD_JOBS=2`.

On the final head (over main `3828f2ed`), 2026-09-19 ~21:45 CST (logs in
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-native-library-plan-admit-run-ddd5a8/0a1d0f2a-9a16-4e9a-9a87-e55bd44a6bc7/scratchpad/logs/`,
`native-run-final-targeted.log`):

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Formatting | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | Clean |
| Clippy | `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak -p arkdeck-cli --all-targets -- -D warnings` | 0 | Clean |
| The changed crates | `cargo test --locked --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak` (after `cargo build -p arkdeck-cli`) | 0 | 421 passed, 0 failed, 12 ignored in 55 suites; `native_library_run` 4/4, `native_library_plan` 2/2, `native_library_submit` 3/3, `debug_hap_run` 7/7 and `screen_sequence_run` 2/2 among them |
| Records | `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings, 121 acceptance IDs; `check_union_merge: ok` |

Stacked on the open #2020, the slice conflicted in eight files, each resolved by keeping both operations:
`MATERIALIZED`, `DEVICE_OPERATIONS`, `READABLE`, `MUTATIONS` and the daemon's tool-identity list hold
both (their lengths raised), both products join `products`, both module notes and `mod` lines stay,
and `job_plan.rs` keeps both submodules. In the tests, #2020's `receive_root: None` on the two owners
this slice moves into `tests/support/hdc_oracle.rs` is carried there instead.

The same checks passed on that stacked head (main `f2bf0047`, #2020, this slice: 418 passed, 0 failed;
`native-run-union-main-tests.log`), and earlier on the head over `74c3b2b1` (#2016) without #2020
(`native-run-targeted.log`).
Before #2015, two full local gates ran, serialized behind the shared gate lock:
- on `101a25bb` (merge base `111fc8a2`), 19:58:17–20:03:04 CST: **exit 0**, rust lane only;
  `workspace-tests.py` 927 passed, 0 failed, 16 ignored in 128 suites (`native_library_run` 4/4,
  `debug_hap_run` 7/7, `native_library_plan` 2/2, `native_library_submit` 3/3); contract checks,
  `check-sdd`, `cargo deny` and `cargo vet` passed. Log `…/scratchpad/logs/native-run-gate-r1.log`,
  SHA-256 `896322ceec0af063385a40c80c3442a87a28cb2792c35ee8616374415b16eaf4`;
- on `4a1e6ad5` after the rebase onto #2012 (merge base `9c58e484`), 20:31:48–20:35:46 CST: exit 1 in
  `arkdeck-platform` `tests/verified_process.rs` `output_overflow_kills_and_reaps_the_child`
  (`started.elapsed() < 2 s` at 2.04 s; the load at start was 15/35/39). By the four invalid-run
  criteria: the crate is untouched by this diff, the test is a known load-sensitive wall-clock
  family, it passed alone at once (6/6 in 1.82 s), and nothing in the diff reaches it. Log
  `…/scratchpad/logs/native-run-gate-r2.log`, SHA-256
  `4dc7fa8e2da3e09631126be1e2c974c4dcbec53b239ce36115eb8ffdbafcc18a`. Its serialized rerun was
  withdrawn under #2015.

## CI

PR #2027, head `a1f05ac7`, all green. It merged on 2026-09-19 as `33847c4e`.

| Check | Run | Conclusion |
| --- | --- | --- |
| SDD Guard `guard` | 35445019354 | success |
| Swift CI `plan` | 35445019465 | success |
| Rust host-independent checks | 35445019465 | success |
| Rust workspace, `ubuntu-latest` | 35445019465 | success |
| Rust workspace, `macos-26` | 35445019465 | success |
| Rust workspace, `windows-latest` | 35445019465 | success |
| `swift` aggregate | 35445019465 | success |

`swift-tests`, `app-build` and `ds-interactions` were not selected for this diff and were skipped.
These rows were added by the `cleanupDebt.list` slice, since the PR merged as soon as it was
green.

## Not run

- `cleanupDebt.list` and `cleanupDebt.continue`: the continuation borrows the recovery load. The
  maintainer ruled L.1 item 13 during this slice (#2016: port the carriers the ADR-0009 decision
  package names); recovery comes first, and the recovered row of `cleanupDebt.continue` follows it.
- The daemon's helper composition: no Rust composition verifies a bundled helper, so the isolated
  daemon lists the operation unavailable and plans none.
- Recovery (ADR-0009 decisions 2 and 4, now ruled): parked native Jobs, unknown outcomes,
  `job.reconcile`, epochs.
- Any device, real HDC server or the installed Runtime; GJ-3 acceptance. The isolated root has no
  mutation authority, so the runs are proven only in the fixed-root host fixture, and the dashboard's
  executable-operation count does not change with this slice.

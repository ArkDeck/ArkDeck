# TASK-XPA-014 — the Rust owner plans and admits `deploy.native-library.app-owned@1` as Swift does: the leased library bound to the Target and verified as a code-signed ELF, every step and the rollback in the plan digest, the library's facts in the capability query (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `2b88705f` (#2008). The slice was written
stacked on the HAP runner (#2005, whose failure lane, debt ledger and `device_steps.rs`/`device_run.rs`
the native run of the next slice shares), and after #2005 merged it was moved onto main with `git rebase
--onto origin/main 9c772698` without conflict, then onto #2008 without conflict. It is the first slice of `deploy.native-library.app-owned@1` (M2, GJ-3):
its plans and its submissions. Planning and admission ship together, because a plan admitted without
its library's facts would be issued a capability Swift never issues. Every answer compared here is
replayed from Swift's native-library oracle, recorded over the shared fake HDC. None of it is device
evidence, installed-Runtime activation or GJ-3 acceptance (POL-VERIFY-001, POL-MODE-001).

The 2026-09-15 branch `agent/xpa-014-native-library-admission-20260915` (`3f051570`) did this slice
on the superseded debug-HAP stack and conflicts with main in six files. It is not rebased: this slice
re-lands it on main's planner (the HAP plan of #1993, the admission of #2000) and main's test
harness, taking its planner, step and journal code as the reference.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (`deploy.native-library.app-owned@1`, GJ-3) |
| --- | --- | --- |
| The native-library oracle (`rust/tests/fixtures/deploy-native-library`, 43 files); the provider's native actions, ELF and code-sign validator (#1955, TASK-XPA-016); the native-library Import (#1983, #1987); HAP plans, admission and runs under Runtime-issued capabilities (#1993, #2000, #2005) | `deploy.native-library.app-owned@1` planned: the code-sign helper in the HDC composition, the library's lease (a Job Artifact or an Import) resolved and bound to the Target, its bytes verified by the provider, every step's typed action (`StepAction::Native`) with Swift's journal arguments and exact process sequence, and the rollback a failure past the publish applies. Admitted: the library's facts in the capability query. `job.run` and `agent.run` still refuse it | The runs (next slice): the host verification steps, the staging send believed through its readback, the rollback and the compensation cleanup on failure, the cleanup debt, the products and `job.result`/`job.evidence`. The daemon's helper composition. `cleanupDebt.list`/`continue` after the maintainer's L.1 item 13 ruling. GJ-3 on the isolated daemon (no mutation authority on an isolated root) and on hardware |

## Why

GJ-3 replaces an application's native library through `deploy.native-library.app-owned@1`, and the
Rust planner refused it as not materialized. Swift authorizes a deployment by its exact inputs and
its library (`MaterializedAdmission.artifactFacts`: the library's identity, digest and
`String(byteCount)`), so the capability it issues, and its ID, depend on the library. A plan digests
every argv of the deployment, the host paths of the library and of the helper included, so it can
only match Swift's with the helper composed as Swift composes it.

## What changes

- **The helper** (`device_facts.rs`): `HdcComposition::code_sign_helper` is the verified code-sign
  helper a deployment stages beside the library (Swift `HDCObservationProviderAdapter`'s
  `nativeCodeSignHelper`). Without one the operation is runtime unavailable (Swift
  `runtimeAvailability`), refused right after the provider check, before the Artifact store check
  and any fact, as Swift orders them. The daemon (`arkdeck-agentd` `host.rs`) composes none yet, so
  it refuses native plans that way; every other composition passes `None`.
- **Planning** (`job_plan.rs`, new `native_library_plan.rs`):
  - `deploy.native-library.app-owned@1` joins `MATERIALIZED` (ten operations).
  - Once the Target's facts hold, the `libraryArtifactLease` is resolved — a Job Artifact through the
    Artifact owner, an Import through the Import owner, under the plan's Import hold — and bound to
    the request's target, binding revision and the facts' identity (Swift `validateArtifactBinding`;
    the check is now one method, `resolve_bound_lease`, shared with the HAP planner). The refusal is
    Swift's: `native library Artifact lease is not resolvable: …`.
  - After the debug-permit check, the library is read (at most one byte past the validator's 64 MiB
    bound) and each step's action is named from it (below). The provider verifies it as the expected
    ABI's code-signed ELF (`typed plan preflight failed before authorization: native library ABI …
    does not match expected …`), and it must still be the byte count its lease records (`leased
    native Artifact bytes drifted during materialization`, Swift's check against
    `resolved.byteCount`).
  - Each provider step is a `processSequence` row (argv, timeout, continue-after-non-zero) with
    Swift's journal arguments; `verify-elf-locally`, `hash-library` and `finalize-session` are the
    engine's rows. The plan then holds `rollback-native-library` after every selected step, as
    Swift's `materializeTypedPlanBeforeAuthorization` appends it.
  - The admission query carries the library's facts (`artifactId`, `artifactSha256`,
    `artifactByteCount`), taken as the HAP planner takes them (`primary_facts`, now shared).
- **The steps** (`device_steps.rs`):
  - `StepAction::Native` holds the provider's `NativeAction`. `action_in` claims it by the operation
    before any step kind, since a send, a readback, a restart and a cleanup are other providers'
    kinds too (Swift gates `nativeLibraryAction` on the operation).
  - `StepContext` (Swift `ProviderExecutionContext`) also carries the library as read for the step
    (`LeasedLibrary`: its bytes and the byte count its lease records) and the helper, and
    `StepAction::plan` lowers within the context, as Swift's `lower(action:context:)` does. The
    runner's and the HAP failure lane's contexts carry neither.
  - The journal arguments are Swift `journalStep(for:)`'s, by step kind: the send's Artifact, digest
    and staging path; the staging readback's expectation; the backup's, publish's and rollback's
    paths, digest and build ID under `runtime-capability-admission`; the restart's bundle and
    `EntryAbility`; the loader probe; the cleanup's staging path and ownership evidence.
  - Native is not in `DEVICE_OPERATIONS`: the run is the next slice.
- **Admission**: nothing new. The plan carries the library's facts into the capability query, and
  the step set has no compensation lines for this operation (Swift `stepSetDigest`).
- **Not running it yet**: `job.run` answers `rejected`, "job <id> runs
  deploy.native-library.app-owned@1, which the Rust Runtime does not execute yet", with the
  zero-dispatch proof; `agent.run` is refused before admission;
  `operation_unavailability` keeps reporting it `operation_not_supported`.
- **The planner's unmaterialized example** (`tests/job_plan.rs`) is now `flash.full-restore@1`.
- **The harness**: `tests/support/native_library.rs` holds the owners over the shared fake HDC's
  fixed root (rebuilt by `support/debug_hap.rs`), the helper composed from `cases.json`'s
  `codeSignHelper` at the fixed path `<root>/host/arkdeck-code-sign-enable` (its bytes are not in the
  fixture; the fake never reads them), and an Import of the oracle's library. Every other
  `HdcComposition` in the tests and in `arkdeck-soak` passes `code_sign_helper: None`.

## Checks

Commands in `rust/` of this worktree (`/private/tmp/arkdeck-native-library-plan-20260919`), with its
own `rust/target`, on 2026-09-19 CST.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| The native-library plans | `cargo test --locked -p arkdeck-hoststore --test native_library_plan` | 0 | 2 passed. All 9 `job.plan` exchanges are answered as Swift answered them, digest and message included: the five plans (digest `600694d5…`, every step and the rollback) and the four refusals (a stale binding, an unknown lease, another ABI, a logical name outside the pattern). Nothing is admitted or dispatched. Without a helper, a plan and a submission are refused as runtime unavailable with the zero-dispatch proof |
| The native-library submissions | `cargo test --locked -p arkdeck-hoststore --test native_library_submit` | 0 | 2 passed. See below |
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| Clippy, macOS / Linux / Windows | `cargo clippy --locked --workspace --all-targets [--target x86_64-unknown-linux-gnu \| x86_64-pc-windows-msvc] -- -D warnings` | 0 | Clean |

`tests/native_library_submit.rs`, at the oracle's fixed root under its lock, with a dispatcher that
fails the test on any call:
1. It replays all 9 plans and 5 submissions: every answer is Swift's, exactly.
   - The capability installed is Swift's one envelope (`CAP-RT-POLICY-EAE3E799…-G1`), with its whole
     budget and no ledger. Swift's runs appended their uses to its ledger and never rewrote the
     checkpoint its install wrote, so `runtime-capabilities.json` is compared byte for byte.
   - For each of the 5 Jobs, `jobID`, `request` (naming the capability), `originalSubmissionRequest`,
     `operationReference`, `catalogDigest`, `providerID`, `createdAtUTC`, `actualEffect` and the three
     materialized members equal Swift's persisted record; the state is `preflight` with no admission
     evidence; the journal is byte for byte Swift's first two events; the index's admission rows and
     schema are Swift's.
   - `job.run` refuses all 5 with the zero-dispatch proof, even with the mutation owner present, and
     `agent.run` of `deployed` is refused before admission; neither writes a Job or capability file.
2. A library imported for the Target (the oracle's bytes through `artifact.import.begin/append/commit`,
   kind `native-library`) is planned and admitted from the Import's lease, under a capability issued
   for these exact inputs, and the admitted Job keeps the Import referenced (its release is
   `resourceConflict`). An Import bound to another identity is refused before admission as Swift
   refuses an unbound lease.

## Unified gate

Command, from the worktree root, serialized behind the shared gate lock and after no other
`scripts/ci/plan.py` was running:
`ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`

Run 1 on `812d8568` (stacked on the HAP runner `9c772698`, merge base `05861555`), 2026-09-19
18:33:25–18:37:30 CST: **exit 0**, rust lane only, workspace 907 passed, 0 failed, 16 ignored in 124
suites. Log `…/scratchpad/logs/native-plan-gate-r1.log`, SHA-256
`ff1ddf28f0663a5d16849348500eb02e618d163b032a320f1f9d7384236a990b`.

Then #2004, #2005 (the HAP runner), #2006 and #2007 merged, and the slice was moved onto main with
`git rebase --onto origin/main 9c772698` without conflict. Run 2, on `2b29b402` (merge base
`e862d2bf`), 2026-09-19 18:52:58–18:59:04 CST: **exit 0**. The diff selects the rust lane only.
`scripts/ci/test_plan.py` (37) and `scripts/test_agent_pr_workflow.py` (12) passed; `check-sdd` 0
errors, 0 warnings, 121 acceptance IDs, `check_union_merge: ok`; the catalog generator's tests (49) and
`--check`; `generate-contract.py --check`; `cargo fmt --all --check`; `cargo clippy --workspace
--all-targets -- -D warnings`; `workspace-tests.py` 920 passed, 0 failed, 16 ignored in 126 suites
(`native_library_plan` 2/2, `native_library_submit` 2/2); published and candidate contract checks;
`cargo deny --locked check`; `cargo vet --locked --no-registry-suggestions`. Log
`…/scratchpad/logs/native-plan-gate-r2.log`, SHA-256
`ee7f5e030b872e226e04da69ffd8f8e2ed8a3735d3a041cf97980ef078b7fec6`.

#2008 then merged (it also changes `arkdeck-agentd` `host.rs` and `rust/README.md`), and the slice was
rebased onto it without conflict. Run 3, on `3de69210` (merge base `2b88705f`), 2026-09-19
19:13:13–19:18:58 CST, serialized: **exit 0**, the same checks as run 2, `workspace-tests.py` 922
passed, 0 failed, 16 ignored in 127 suites. Log
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-native-library-plan-admit-run-ddd5a8/0a1d0f2a-9a16-4e9a-9a87-e55bd44a6bc7/scratchpad/logs/native-plan-gate-r3.log`,
SHA-256 `d1b063b4c85360e2a7f194362a39e1f503506945a96af7f22613dd5d19774b44`. The amended commit that
records this section changes only this file and the commit message; the gated tree is otherwise
identical.

Before the gate, in this worktree: `cargo test --locked --no-fail-fast -p arkdeck-hoststore -p
arkdeck-agentd -p arkdeck-soak` on the HAP runner's first head `ac8a29a4` failed only in
`operation_availability_control::live_discovery…` (its `debug.hap@1` tool-identity row, fixed in the
HAP runner's amended head `9c772698`, on which this slice was rebased without conflict) and in
`import_publication_process` (a focused run does not build the `arkdeck` binary it spawns; the
workspace run above builds it). Two mutation checks, reverted before the commit: without the
rollback row the plan replay fails; without the library's facts the submission replay fails.
Before the rebase, trial merges with the then-open #2004, #2006, #2007 and #2008 were
conflict-free, and none of them constructs an `HdcComposition`.

## CI

PR #2011, head `9bd9341b`, all green. It merged on 2026-09-19 as `111fc8a2`.

| Check | Run | Conclusion |
| --- | --- | --- |
| SDD Guard `guard` | 35439839460 | success |
| Swift CI `plan` | 35439839577 | success |
| Rust host-independent checks | 35439839577 | success |
| Rust workspace, `ubuntu-latest` | 35439839577 | success |
| Rust workspace, `macos-26` | 35439839577 | success |
| Rust workspace, `windows-latest` | 35439839577 | success |
| `swift` aggregate | 35439839577 | success |

`swift-tests`, `app-build` and `ds-interactions` were not selected for this diff and were skipped.
These rows were added by the `cleanupDebt.list` slice, since the PR merged as soon as it was
green.

## Not run

- The runs of a deployment, its failure lane, debt and readers: the next slice
  (`agent/xpa-014-native-library-run-20260919`).
- The daemon's helper composition: no Rust composition verifies a bundled helper yet, so the
  isolated daemon refuses native plans as runtime unavailable.
- Recovery (ADR-0009 decisions 2 and 4, L.1 item 13).
- Any device, real HDC server or the installed Runtime; GJ-3 acceptance. The isolated root has no
  mutation authority, so the dashboard's executable-operation count does not change with this slice.

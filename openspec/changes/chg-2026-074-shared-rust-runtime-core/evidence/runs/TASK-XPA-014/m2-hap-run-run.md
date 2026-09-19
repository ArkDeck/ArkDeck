# TASK-XPA-014 — the Rust owner runs `debug.hap@1` as Swift does: the success lanes, the failure lane with its compensations under the one consumed use, and the cleanup debt ledger (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `05861555` (#2003). The slice was written on
`c49e9e93` (#2000) and rebased onto `05861555` without conflict; #2002 and #2003 change no HAP
path. It is the run of `debug.hap@1` (M2, GJ-2) on the durable Rust runner of #1984 and #1998.
Every answer and every file compared here is replayed from Swift's debug-hap oracle, recorded over
the shared fake HDC in a fixed-root host fixture. None of it is device evidence, installed-Runtime
activation or GJ-2 acceptance (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (`debug.hap@1`, GJ-2) |
| --- | --- | --- |
| The HAP Provider (#1951); the debug-hap oracle; the durable mutation runner, its account-fixed root, Session continuity and settled outcomes (#1984, #1998); HAP plans (#1993) and admission under Runtime-issued capabilities (#2000), with `job.run` and `agent.run` refusing HAP | `job.run` runs an admitted HAP: the success lanes, the awaiting-readback lane, the per-step lease re-resolution, the declared compensations, the failure lane (`performDebugHAPFailureFinalization`, `validateContinuation`), the cleanup debt ledger on the run path, `job.result`/`job.evidence` of HAP Jobs; later mutations of a run continue under the one use it consumed; `job.run` and `agent.run` no longer refuse HAP | `cleanupDebt.list`/`continue` (its recovery load needs the maintainer's §L.1 item 13 ruling); recovery itself (parked and `finalizing` Jobs, unknown outcomes, epochs, `job.reconcile`); GJ-2 on the isolated daemon with the account-fixed owner and on hardware |

## Why

GJ-2 debugs a HAP through `debug.hap@1`. The Rust owner planned and admitted one but refused to run
it. A HAP run cannot ship without its failure lane: a debug HAP that failed after its send would
otherwise close with its package still staged or installed and nothing recording it. So the
success lanes, the compensations and the debt ledger ship together, and the refusals of `job.run`
and `agent.run` lift only with all three.

## What changes

- **The multi-step consumption rule** (`mutation_execution.rs`). Main's
  `consume_mutation_authority` refused a Job that already carried admission evidence, while a HAP
  has six mutation steps (send, install, start, stop, uninstall, cleanup) and its compensations.
  Swift `consumeCapabilityBeforeMutation` consumes one use before a Job's first mutation; a later
  mutation of the same Job takes its "persisted evidence" arm: the evidence must be the Job's
  `runtimeCapability` evidence for the capability its request names, the mutation state is proven
  again, the whole typed plan is materialized again against fresh Target facts and must bind what
  it bound, and no second use is consumed. A debug HAP's compensation, run while the Job is
  `finalizing`, also calls `validateContinuation` and compares its receipt with the evidence
  (fingerprint, ordinal, reservation, step-set digest). The Rust port:
  - keeps the first consumption exactly as it was, and records the evidence it made durable on the
    run (`Run::consumed`);
  - continues only that evidence: evidence found on a record this run did not write is refused as
    before (`persisted mutation evidence cannot be replayed`), because continuing it is recovery;
  - repeats every fresh check of the first path (owner, tool identity, mutation state twice, request,
    Target facts, fresh plan and binding) before continuing; a request to cancel stops a later
    mutation as it stops the first, except in the failure lane, which Swift enters after dropping it;
  - runs `validateContinuation` (new in `capability_store.rs`: the exact unsettled use of this
    reservation and Job, for this query, still authorized with that use added back) and the
    correlation check for a HAP compensation in `finalizing`; `reconciling`, Swift's other arm, is
    recovery;
  - settles only the use the run consumed (`settle_mutation`), whatever evidence its record carries;
  - treats a refused authority as the step's own failure, handled where a failed dispatch is, as
    Swift catches both in one place: a required step's fails the Job (a HAP's through its lane), an
    optional step's is skipped, and an optional HAP cleanup refused before its intent has no durable
    failed outcome to owe, so the run stops with its internal failure (Swift `cleanup failure lacks
    its declared durable outcome`) and the Job stays `running`.
- **The run lane** (`device_run.rs`, `device_steps.rs`):
  - `verify-hap-artifact` is an engine host step (Swift `verifyHostInputArtifact` verifies flash
    images and native libraries only).
  - Before each step given them, the packages are resolved from their leases again (Swift
    `resolvedInputArtifact`, `resolvedAdditionalInputArtifacts`): every package for the send, the
    entry package for the install and each approved remote read, an Import through its owner. Each
    must still name the request's target and binding revision and the identity the plan bound
    (`validateArtifactBinding`); the refusals are Swift's.
  - The action is lowered before any use is consumed, as in Swift. Every step dispatches its whole
    plan through the provider's `run`, a process sequence included; a HAP step is judged over the
    whole receipt, the package readback against the entry package's digest.
  - The awaiting-readback lane (`readbackPairs`): an install and a start that their provider cannot
    believe on their own succeed as dispatches (`dispatched <step>; awaiting readback`); the required
    readback after each is what may believe them.
  - The send, install and start intents declare the compensation that undoes each
    (`compensation-cleanup-remote-staging`, `compensation-cleanup-uninstall` under the `uninstall`
    policy, `compensation-stop-ability`), named from the provider's action in the source's own
    context, with the digest of their arguments.
  - Products: `install-readback.json` and `process-readback.json` are facts products,
    `debug-hilog.txt` the HiLog capture's raw stdout.
- **The failure lane** (`device_hap_failure.rs`, Swift `performDebugHAPFailureFinalization`): the
  failure is durable before `finalizing`; the compensations the succeeded source steps declared run
  latest first; a cleanup already attempted, as a step or as its compensation, is never sent again
  and owes a debt if it failed; before its intent each compensation proves the Target against the
  plan and its source's intent, resolves the packages again, is checked against its declaration
  (`validateCompensationAction`) and continues under the Job's use; it is journaled as a
  `compensationIntent`/`compensationOutcome` under its declared identity; the Job then fails with
  `original failure retained; declared compensations have confirmed outcomes`. A lane that cannot
  conclude parks the Job (`parkDebugHAPCompensation`); what Swift throws past the lane (a capability
  or lease refusal) is this run's internal failure and leaves the Job `finalizing`, its use pending.
- **The debts** (`cleanup_debt.rs`): a HAP cleanup keeps its exact action after a confirmed failure;
  an optional one owes its debt and is skipped on the normal path
  (`resumeConfirmedOptionalDebugHAPCleanupDebt`), a required one owes it in the failure lane
  (`persistDebugHAPCompensationDebt`); each is written once per Job and step to the Artifact root's
  `cleanup-debt.json` in Swift's decoded-and-re-encoded Foundation spelling (sorted keys, `\/`), and
  the Job counts its outstanding residue; a stop that leaves the ability running is named on the
  timeline only.
- **Around the run**: a succeeded Job whose Session names a failed step is refused as Swift refuses
  it (`invalidManifest("succeeded status contains failed Step")`); `job.result` and `job.evidence`
  read HAP Jobs, their step kinds those the journal proves (`durableActualStepKinds`); operation
  availability holds `debug.hap@1` to the mutation owner, as it holds the gestures and port rules,
  and the daemon probes its tool identity as it probes theirs (`arkdeck-agentd` `host.rs`), so the
  isolated development daemon, which has no account-fixed mutation owner, lists it unavailable
  (`runtime.mutationOwnerUnavailable`) and dispatches no HAP; `job.run` classifies a `finalizing` HAP as Swift's `runOwned` does and refuses it as a
  resumption.

## Checks

Commands in `rust/` of `/private/tmp/arkdeck-hap-run-20260919`, with its own `rust/target`,
2026-09-19 CST. Logs are in `$S` =
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs`.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| Targeted | `cargo test --locked -p arkdeck-hoststore --test debug_hap_run --test debug_hap_submit --test debug_hap_plan --test pointer_input_run --test port_forward --test job_run` | 0 | `debug_hap_run` 7, `debug_hap_submit` 6, `debug_hap_plan` 2, `pointer_input_run` 9, `port_forward` 4, `job_run` 1 passed (`$S/hap-run-targeted2.log`, SHA-256 `23803e8cec164496eda56bd3feee0350978287ec1d93b18a6eb5e133019c0fdf`) |
| Workspace | `cargo test --workspace --locked --no-fail-fast` | 0 | 903 passed, 0 failed, 16 ignored in 122 suites (`$S/hap-run-workspace4.log`, SHA-256 `38026874d3abf5f984b10acd8bc4740513d76158bea61f7efb49ed54079be511`). An earlier run on the rebased head (`$S/hap-run-workspace2.log`) failed one test, `arkdeck-agentd` `live_discovery_and_describe_follow_actual_executors_and_executable_drift_without_dispatch`: the daemon probed the tool identity of a fixed list of HDC executors that lacked `debug.hap@1`, so the HAP read `tool_identity_drift` beside `runtime.mutationOwnerUnavailable`; the list now names it |
| Clippy, macOS | `cargo clippy --workspace --all-targets --locked -- -D warnings` | 0 | Clean (`$S/hap-run-clippy-macos.log`) |
| Clippy, Linux | `cargo clippy --workspace --all-targets --locked --target x86_64-unknown-linux-gnu -- -D warnings` | 0 | Clean (`$S/hap-run-clippy-linux.log`) |
| Clippy, Windows | `cargo clippy --workspace --all-targets --locked --target x86_64-pc-windows-msvc -- -D warnings` | 0 | Clean (`$S/hap-run-clippy-windows.log`) |
| Union-merged records | `python3 scripts/check_union_merge.py` | 0 | `check_union_merge: ok` |

`tests/debug_hap_run.rs`, over the fixed root with the Runtime's own `MutationAuthority` (the
account-fixed `store` root, the Session owner) and the fake HDC spawned through `ProcessDispatch`:

1. `rust_runs_every_swift_debug_hap_as_swift_does` replays all 59 exchanges before the four
   `cleanupDebt.*` ones — 15 plans, 8 submissions, 8 runs and the rerun refusal, 24 reads
   (`job.result`, `job.evidence`, `artifact.list` of each Job) and the three capability reads — each
   answered as Swift answered it, message included. The fake receives Swift's first 103 calls in
   order. Each Job consumed exactly one use. Then everything the replay leaves is Swift's byte for
   byte: the index (schema, rows, versions, record digests), the tree's kinds and modes, every Job
   record, journal and Session proposal, the capability checkpoint and ledger (eight uses, one per
   run, each settled `confirmed` but the parked one's `outcomeUnknown`), all six Sessions and the retention catalog,
   every product and index of the Artifact root. For the two Jobs whose debts the continuations
   later settle, the comparison is against the record as it stood before them — Swift's
   `recover(records:)` load appends `recovered: journal clean` and its residue refresh writes `0`
   (`continueCleanupDebt`), two persists — and against the ledger without its two settlement
   members.
2. `evidence_a_run_did_not_consume_is_never_continued`: Swift's evidence of the installed run,
   written onto the admitted record, is refused at the send; nothing past the read-only preflight is
   dispatched, nothing is consumed or settled, and the Job fails through its lane with nothing to
   compensate.
3. `a_compensation_through_an_unproven_tool_is_never_dispatched`: once the tool cannot be proved
   after the failing readback, the uninstall compensation is refused before its intent; `job.run`
   answers its internal failure, the Job stays `finalizing` with its use pending, and a second
   `job.run` is refused as a resumption with zero dispatch.
4. `an_optional_cleanup_refused_its_authority_stops_the_run`: once the tool cannot be proved after
   the stop, the optional uninstall is refused before its intent; the run answers its internal
   failure, the uninstall is never sent, and the journal ends with the stop's outcome.
5. `no_hap_is_sent_without_the_mutation_authority`: an owner whose account-fixed root is elsewhere
   admits nothing and issues nothing; a runner without the mutation owner fails the Job at its send
   with nothing sent or consumed.
6. `a_compensation_that_fails_is_owed_under_its_own_identity` (no oracle records it): an ineffective
   uninstall compensation is owed as `compensation-cleanup-uninstall` with its exact action, the
   staging compensation still runs, and the Job fails with one residue and its use settled.
7. `an_unobserved_compensation_parks_its_job` (no oracle records it): the lane parks with Swift's
   reason, sends nothing after it, keeps the original failure and leaves the use `outcomeUnknown`.

`tests/debug_hap_submit.rs` keeps its admission replays; its `job.run`/`agent.run` refusals are
replaced by `an_agent_run_admits_the_hap_it_will_run` (the execution owns a `preflight` HAP under
the issued capability, nothing dispatched or consumed). Unit tests cover the compensation plan's
order, `validateCompensationAction` and the ledger's record decoding. Mutation checks, reverted
before the commit: planning the compensations in source order, and taking a fresh consumption for
every mutation, each fail the replay; ending the step loop at a refused authority before the
optional-step handling fails test 4.

## Unified gate

Command, from the worktree root, through the serialized queue (`gate-queue.sh`):
`ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`

- Run 1 on `4ed7c0e5` (merge base `05861555`), 2026-09-19 17:56:39–18:00:00 CST: **exit 0**. Lanes:
  rust (29 changed files). Workspace tests 902 passed, 0 failed, 16 ignored in 122 suites; the
  published and candidate contract checks, `check-sdd` (0 errors, 0 warnings, 121 acceptance IDs,
  `check_union_merge: ok`), `cargo deny` and `cargo vet` passed. Log `$S/hap-run-gate.log`, SHA-256
  `7dcd7d553b993db02a6f85fd08ea3dbe3a016b59e57bb8ca16b73fac24d31b92`. The routing of a refused
  authority through the optional-step handling, and its test, came after this run.
- Run 2 on `51d268d3` (merge base `05861555`), 2026-09-19 18:08:50–18:13:19 CST: **exit 0**. Lanes:
  rust (29 changed files). Workspace tests 903 passed, 0 failed, 16 ignored in 122 suites; the
  published and candidate contract checks passed; `check-sdd` 0 errors, 0 warnings, 121 acceptance
  IDs, `check_union_merge: ok`; `cargo deny` (advisories, bans, licenses, sources ok) and
  `cargo vet` (36 fully audited) passed. Log
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/hap-run-gate2.log`,
  SHA-256 `51f55cfbc6e89c4f2a6c91c23c5bade75166e3bc770f9d5504da79a8f9d50402`. The amended commit
  that records this run changes only this file; the gated tree is otherwise identical.

## Not run, and why

- **`cleanupDebt.list` and `cleanupDebt.continue`**: `continue` loads its Job through Swift's
  recovery (`recovered: journal clean`), which needs the maintainer's §L.1 item 13 ruling. The run
  test compares the two continued Jobs and the ledger as they stood before the continuations.
- **Recovery** (ADR-0009 decisions 2 and 4, L.1 item 13): no parked or `finalizing` Job is
  continued, no unknown outcome is settled, the `reconciling` arm of `validateContinuation`,
  outcome-gap repair and recovery epochs are not ported. Swift's step-start
  `resumeConfirmedOptionalDebugHAPCleanupDebt` only acts on a resumed Job, so it is not called at the
  start of each step.
- **`scripts/check-corpus-replay.py`** over the debug-hap fixture: its `cleanupDebt.*` exchanges are
  not served.
- **The daemon's agent path**: `agent.run` now admits a HAP; its run through the agentd composition
  is not exercised here.
- No device, HDC server, signing, installed Runtime or GJ-2 acceptance; no Swift source or fixture
  changed.

## Questions for the maintainer

1. A run continues only the use it consumed itself and settles only that one. Swift also continues
   the persisted evidence of a recovered Job; is refusing that evidence right until L.1 item 13?
2. The continuation keeps #1984's tool-identity proof at every mutation, which Swift does not
   require. Keep it?
3. The first consumption's refusals keep main's wording (for example `authorizationRequired:
   lineageBlocked(…)`), where Swift says `authorizationRequired: capability denied before mutation:
   …`; the new continuation uses Swift's. Align the first path in a follow-up?
4. The two continued Jobs are compared as the fixture minus the continuation's effects, read from
   Swift's `continueCleanupDebt` and `recover(records:)`. Is that acceptable, or should the oracle
   record a snapshot before its continuations?
5. `rust/README.md`: besides the Job run section, one stale sentence of the Job admission section
   (it said `job.run` refuses a HAP) was corrected in place. Acceptable?

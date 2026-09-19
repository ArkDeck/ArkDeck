# Rust physical-assistance continuation — 2026-09-19

Base: `e251b0374927b10a54ab1c9f5b9345577b76c5e4` (PR #1975,
not yet a protected-main delivery). This slice reuses its guarded adoption owner.

`agent.resume` and physical `human-action.resume` locate the exact persisted
action/reference under the execution owner's serialization gate. Selection is
only an opaque choice from that action. The original intent, Catalog, budget,
deadline, resolved Target and deterministic Job submission remain Runtime owned.
Connect actions start a fresh observation chain; trust/selection follow their
exact observation, and restart/attachment/generation drift raises fresh choices
instead of selecting an unproved replacement. Adoption and budget checks must
succeed before resolving the action or submitting a Job. Both control routes use
the same owner and Host start/result projection as `agent.run`.

The source is Swift `Workflows/AgentExecutionCoordinator.swift` `resumeOwned`,
not the older client-local pending file executor. In particular, after a crash
between resolved-action persistence and Job creation, repeating resume reads
status only; repeating `agent.run` with the same original intent continues that
pre-Job execution. No active/unknown Job replay or recovery authority is added.

Targeted validation so far:

- Rust HAR/adoption integration tests: 8 passed, 1 ignored subprocess helper
  explicitly launched by its parent. The new matrix covers connect continuation,
  trust and selection restart invalidation, opaque-choice idempotency conflict,
  invalid parameters, original-deadline expiry, clock rollback, and four concurrent
  resumptions returning exactly one Job/start. Fresh-observation and Job owners
  are production implementations; transport/USB relations are host fixtures.
- Actual subprocess exit after resolved action/Target commit and before Job
  creation: reopened owners return unchanged status on resume, then one Job on
  the original run intent. Expired original budget yields zero Job/new probe.
- `cargo check` and all-target Clippy with `-D warnings` for hoststore/control/agentd
  passed. The complete integrated verification is recorded below.

Contract compatibility: the sampled method schemas omitted existing Swift
resume errors and required a zero-dispatch proof even where the agent handler
actually returns empty details. Native Swift producer test
`RuntimeAgentExecutionContractTests/testResumeControlFramesPreserveBudgetClockAndIdentityRefusals`
passed twice on the independent sampling tree at
`b710252d1d7844f1fcd361e58c66429a06173493` plus only that test. The final run recorded
12 actual resume failure frames: for both routes, clock rollback, initial budget
expiry, budget expiry during identity readback, absent physical proof, conflicting
Job idempotency, and an unreadable test-owned execution document. The latter
proves the actual agent empty-details / combined-HAR pre-admission-proof distinction.
No hardware facts, capability records or hardware evidence were changed.

The recorded frames were merged with the existing two-method corpus and passed
through `generate-control-contract.py --derive-method-schemas` and
`rust/scripts/generate-contract.py --write`. The generator also preserves the
existing `resumeOwned`/`drive` failure vocabulary for Catalog drift, reviewed-plan
mismatch and fixed-Target drift. This adds no operation or authorization, does
not weaken accepted safety requirements and needs maintainer review in this
CHG-2026-074 slice. Method registry/contract identity and generated Swift/Rust
bindings stay unchanged; schema/corpus hashes in the baseline are regenerated.
Swift's unchanged schema validator consumes those generated schemas.

Native logs: `/private/tmp/arkdeck-resume-swift-record-20260919.log` and
`/private/tmp/arkdeck-resume-swift-record-unreadable-20260919.log` (both exit 0).
Final native frames: `/private/tmp/arkdeck-resume-swift-frames-unreadable-20260919/`.
Targeted Rust `corpus_parity`: 10 passed; `control/read_only`: 16 passed.
No producer frame was hand-authored; no failure was mapped away to generic success
or unavailable. The final integrated repository unified validation passed; see the final result below.

These are local macOS fixture tests and process-exit simulations, not hardware
acceptance. Production USB source activation, installed switching,
unknown-outcome recovery and GJ-1–5 remain outside this slice. PR review/merge,
CI and maintainer review/merge remain outstanding.

Integration for final validation: this branch explicitly merges original PR #1976
commit `b710252d1d7844f1fcd361e58c66429a06173493` after the resume implementation
commit. Its ClientKit extraction and SDK compatibility remain that PR's reviewed
scope; they were not copied or rewritten into this feature. Both #1975 and #1976 have since merged into protected main. Final unified verification runs this actual
stacked branch, not a detached source view with unrecorded SDK modifications.


CLI continuation: `agent resume` and physical `human-action resume` now send the
same exact references once, then reuse the existing execution validator and
read-only `agent.status` settling loop. `--resume-token` is an alias of the exact
Runtime reference. Selection and a strict JSON string selection file (64 KiB
maximum) are exclusive; timeout bounds only the client wait. New budget, Target,
inputs or capability options are rejected. Impact-approval/challenge responses
remain `humanActionRequired`: this physical slice does not implement the separate
interactive control-action approval flow or respond to a challenge automatically.

All CLI tests passed, including the new binary/private-socket test for both
resume leaves: the Runtime observes one request, dropped responses produce
`outcomeUnknown` with `controlRequestRetryable: false`, and no replay or second
connection occurs. Parameter tests cover forbidden intent fields, alias/source
exclusivity and bounded selection documents; all-target CLI Clippy also passed.
Log: `/private/tmp/arkdeck-resume-cli-tests-20260919.log`.

Main integration: merged `origin/main` `98cb3b96` after the first stacked-branch
unified run. CLI conflict resolution preserves both main's HAR reads and the two
resume leaves; owner conflict resolution preserves resume's exact selection and
all adoption/crash tests. Main's live availability and soak composition are included.

The initial full gate on `c41dd835` exited 1. Swift (2,685 tests), App
build-for-testing, Rust workspace tests and Clippy passed. Contract source views
identified two test-integration omissions: the published schema correctly rejects
newly sampled error vocabulary as `internalError`, while the new route test had
expected candidate errors; the read-only executable check still classified both
resume methods as unimplemented. The test now proves both published fail-closed
and candidate preserved errors, and the daemon check expects the actual missing
execution-owner refusal. No production safety mapping was relaxed. Initial log:
`/private/tmp/arkdeck-resume-unified-20260919.log`. This is not the final integrated
gate; the complete unified entry point must pass on the actual merged branch.

The first integrated gate stopped at the main HAR CLI test's historical assertion
that `human-action resume` is an unknown command. The new closed leaf correctly
rejects its missing required references as `invalidOption`; that assertion is
updated without accepting missing arguments. Integrated attempt log:
`/private/tmp/arkdeck-resume-integrated-unified-20260919.log` (exit 1).

The next integrated attempt passed checkout checks, then found main's HAR CLI
`include_str!` fixtures absent from both isolated contract input views. The two
native argv fixtures now use the existing `rust/tests/fixtures/current-cli-argv`
source-view mechanism; `verify_current_cli_argv` verifies byte identity against
the Swift originals. No fixture expectation changes. Failed attempt log:
`/private/tmp/arkdeck-resume-integrated-final-20260919.log`.

Unified verification on `55470353` passed (exit 0): Swift full/timing, App
build-for-testing, Rust workspace, actual published/candidate views, deny and vet.
Log: `/private/tmp/arkdeck-resume-unified-pass-20260919.log`. Separate actual
source-view verification also passed at
`/private/tmp/arkdeck-resume-source-views-final-20260919.log`.

Subsequently integrated protected main `187321ea` containing #1968. The three
new resume fixture JobAdmitter constructions explicitly set `authority: None`;
production Host retains main's Runtime-owned MutationAuthority policy composition.
The preceding pass is retained as evidence of the pre-capability combination;
the final integrated result below validates this new combination. No hardware or capability evidence was fabricated.

Final integrated verification: the complete repository entry point on
`190d6c35` (including protected main `187321ea` / #1968) exited 0. Swift full and
isolated timing tests, App build-for-testing, Rust workspace tests and Clippy,
actual published/candidate contract source views, cargo deny and cargo vet all
passed. No filter, skipped lane, changed timeout or weakened assertion was used.

```
CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=2 \
ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python \
/private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

Final log: `/private/tmp/arkdeck-resume-capability-integrated-20260919.log`.
Contract-view receipts:
`rust/target/readonly-check/62469e9e331940ee8f38caf8fa5a87b6`.
Only this evidence report changes after the verified implementation commit.

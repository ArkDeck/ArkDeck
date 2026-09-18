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
  passed. Final unified check has not run; it remains queued by the parent.

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
or unavailable. Final repository unified validation remains pending.

These are local macOS fixture tests and process-exit simulations, not hardware
acceptance. CLI resume, production USB source activation, installed switching,
unknown-outcome recovery and GJ-1–5 remain outside this slice. PR review/merge,
full local gate and CI remain outstanding.

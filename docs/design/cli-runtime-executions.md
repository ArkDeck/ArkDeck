# Runtime-owned CLI executions

This implementation closes the pre-Job ownership gap in GJ-1 and provides the
same typed execution owner for the other Golden Journeys. It implements part
of the target CLI specification; it is not a declaration that the complete CLI
or real-device acceptance has passed.

## Published entry points

The target protocol (`2.0.0`) adds `agent.run`, `agent.status`, `agent.list`,
`agent.abandon`, `agent.resume`, and `human-action.list/show/resume`. Their
production owner is `RuntimeAgentExecutionCoordinator`, composed by
`arkdeck-agentd`, rather than a CLI-local pending file.

```text
arkdeck agent run --require-protocol 2 --operation observe.device@1 \
  --execution-id observation-20260831 --maximum-wait 5m --timeout 30s --output json
arkdeck agent status --execution-id observation-20260831 --output json
arkdeck agent list --page-size 100 --output json
arkdeck human-action list --owner-kind agentExecution --owner observation-20260831 --output json
arkdeck human-action show --human-action <returned-action-id> --output json
arkdeck agent resume --resume-reference <returned-reference> --output json
arkdeck human-action resume --human-action <returned-action-id> \
  --resume-reference <returned-reference> --selection <returned-choice> --output json
arkdeck agent abandon --execution-id observation-20260831 \
  --expected-generation <current-generation> --output json
```

`agent run` accepts either the existing typed operation request document or
flag-form operation/target/binding/inputs/capability/request identities. Input
and selection files also accept `-` for bounded strict JSON on stdin. New
orchestration options and the new resource leaves select protocol 2; negotiation
never downgrades a resource mutation. An unchanged legacy `agent run` or
`agent resume --resume-token` invocation retains its 1.x behavior. With explicit
protocol 2, `--resume-token` passes its exact value as `resumeReference`.
The final default-v2 and domain-convenience migration remains a later slice.

## Ownership and replay

The daemon durably stores the original intent before discovery. Its JCS
fingerprint never incorporates a discovered target, observation or Job. The
optional reviewed-plan digest is a separate immutable precondition: changing
its value or presence conflicts, and the Job engine compares it with the fresh
materialized plan before admission.

Execution records and prepared submission bytes are private, bounded and
atomically published. A prepared request must match the original intent and
resolved target. Admission receipt loss is reconciled against the existing
Job ledger using that exact request, including after the orchestration deadline.
This is a lookup of an already accepted Job, not a new admission. The Job engine
coalesces concurrent drivers for the same Job; existing recovery rules still
park unknown outcomes and prohibit replay.

`maximum-wait` defaults to five minutes and is capped at 24 hours. Its absolute
deadline includes physical-assistance pauses, client disconnects and Runtime
restarts. Durable UTC high-water checks and an in-process continuous deadline
both restrict further orchestration. Clock rollback and expiry stop new
admission. The independent CLI timeout stops only that client's waiting.

Abandon and Job creation serialize under the execution owner. Abandon requires
the current generation, expires the exact waiting action and cannot cancel an
accepted Job. Terminal abandonment is a successful query/transition; replay
through `agent run` returns its bounded result with `executionOutcome: abandoned`
and exit 1.

## Physical assistance and discovery

This slice publishes only AgentExecution-owned connection, trust-prompt and
device-selection actions. These are physical assistance, never impact approval
or capability authority. Actions and opaque resume references survive restart.
Resume probes the original relation again. A lost observation lifecycle or a
reused connection key requires fresh selection; even a single replacement is
not automatically selected. A selection is accepted only from that action's
exact opaque choice set. Job- and control-action-owned HAR remain separate
unfinished product work and are not fabricated by these methods.

Execution and action lists use `arkdeck.cli.page/1` immutable snapshot pages,
with total orders `createdAtDescExecutionIdAsc` and `createdAtDescActionIdAsc`.
Cursors bind method, filters, page size and snapshot revision, and survive
restart. The private snapshot cache retains the latest 32 snapshots within
64 MiB; reclaimed, forged and cross-query cursors return `invalidCursor` without
restarting a query. Execution lists omit inputs, capability references and
selection documents; action detail is read by exact action identity.

Terminal Agent responses include the existing Job's outcome and verified
Artifact evidence. They do not disclose original input/probe detail or sensitive
bytes. Required Artifact verification failures preserve the result projection
and exit 2. A failed/cancelled/interrupted Job preserves the result and exits 1;
unknown outcomes require readback/reconciliation and exit 75.

## Verification

Contract and CLI-process fixtures cover paused-owner restart, immutable reviewed
preconditions, exact HAR identity/selection, generation conflict, clock rollback,
deadline expiry during adoption/materialization, lost admission publication,
snapshot continuation across restart, client timeout and concurrent Job drivers.
Fixtures use synthetic providers and never count as hardware evidence.

Real-device validation is pending the reviewed protected-main Runtime containing
this slice. No helper installation, raw HDC command, device mutation or new
`REAL_DEVICE_PASS` is performed by these host tests.

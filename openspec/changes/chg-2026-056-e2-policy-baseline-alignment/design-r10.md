# r10 Design — Runtime-mediated candidate debugging without per-attempt PRs

## Problem statement

r5 removed the per-run human authority and correctly kept the destructive executor in the
protected-main Runtime. It did not, however, carry the repair loop across that boundary. The old
Evolution path could build several isolated candidates, but its candidate grammar only changed
starting modes and timing. A failure in Runtime, Provider, binding, journal or postflight logic was
therefore surfaced to an operator with the instruction to merge a fix and continue. r5 then
retired the active campaign entry points while retaining that same restriction.

The result is a split product:

- GJ-5 can patch, build, test, deploy, observe and repeat in an isolated workspace before its final
  promotion PR;
- GJ-4 can retry an unchanged request after a durable `safeToReflash`, but cannot evaluate a repair
  candidate in the real loop. A host-side defect consequently turns every experiment into a PR.

The latter contradicts PRODUCT-LOOP's no-governance-in-the-runtime-path rule. A PR is the final
promotion boundary, not an experiment transport.

## Selected boundary

r10 keeps the device executor and all trusted facts in protected main. It adds a distinct,
untrusted candidate-decision plane:

```text
isolated repair workspace
  -> build and host-test candidate decision adapter
  -> candidate emits a closed CandidateDecision (no capability, facts, argv or plan)
  -> protected-main Runtime freshly materializes the published operation
  -> Runtime re-reads target/binding/tool/Artifact facts
  -> Runtime validates the decision against its own materialization and closed repair envelope
  -> Runtime mints/reserves its own exact RuntimeCapability
  -> protected-main typed Provider dispatch
  -> durable outcome + structured repair observation
  -> success, safe next candidate, or non-overridable blocker
```

The candidate is never a broker or Provider plugin. It does not receive a Runtime socket, device
transport, raw serial/topology, capability store, reservation store, journal writer or mutable
trusted-fact handle. Its output is an untrusted suggestion that may be ignored.

## Closed CandidateDecision grammar

The candidate may return exactly one of:

- `usePublishedDefaults`;
- `selectPublishedAlternative`, naming one alternative already declared by the exact published
  operation/provider repair envelope;
- `boundedTiming`, selecting values inside the published minimum/maximum range;
- `requestPublishedObservation`, naming an existing bounded read-only observation from the repair
  envelope;
- `stop`, with a redacted diagnostic reason.

It cannot return an operation/profile, target/binding, partition, Artifact/archive, Step, effect,
executable, argv, environment, filesystem path, capability, reservation, outcome, coverage proof
or journal event. Unknown keys, out-of-range values and a decision whose canonical digest is not
covered by the Runtime-materialized repair envelope are rejected with zero external dispatch.

The repair envelope is published and reviewed with the existing operation/provider contract. r10
does not let a candidate create or widen that envelope. Adding an alternative that can alter an
external effect remains a normal operation/provider or destructive-policy change and therefore
still requires review before use.

## Autonomous invocation

The protected-main Runtime owns one `RuntimeDebugInvocation` for an exact operation, target,
binding, inputs, plan, Artifact and provider/tool tuple. It has the existing hard limits: at most
sixteen serial destructive epochs, four hours and concurrency one.

Within that invocation:

1. The repairer works only in a task-owned isolated checkout and may patch the candidate decision
   adapter plus its host tests.
2. Each candidate must build and pass the declared host gate before Runtime evaluates it.
3. Runtime persists the candidate source/build digest and decision digest as non-authoritative
   provenance before admission.
4. Runtime derives every trusted fact and the executable plan independently. Candidate output is
   used only if it selects an already-published alternative and the recomputed envelope matches.
5. A new destructive epoch is possible only after the predecessor is durably terminal and is
   classified `safeToReflash`, or through the already-approved distinct complete-overwrite
   recovery proof. Unknown intent is never replayed.
6. The structured terminal result is returned to the repair loop. The repairer may prepare the
   next isolated candidate without a Git task, change, PR, merge or chat confirmation.
7. Success exports a normal promotion candidate. The source change enters protected main only via
   the ordinary final PR.

A pre-dispatch refusal consumes no destructive epoch. A post-write read-only/postflight failure
does not automatically reflash: Runtime first runs the published read-only observations and uses
existing recovery/supersession rules. It dispatches a new destructive epoch only when those rules
prove it eligible.

## What this does and does not fix

This design makes every behavior intentionally represented in the reviewed repair envelope
debuggable before promotion. The first DAYU200 envelope must cover the current mode transition,
bounded deadlines, unique post-flash HDC-personality selection and read-only postflight checks,
because those are the defects that caused the #1210–#1215 merge-before-observe chain.

Arbitrary unmerged Runtime or Provider code still cannot replace the protected executor. If a
candidate needs a new Step, command, partition, target rule, trusted fact or external-effect
alternative, Runtime returns `repairSurfaceInsufficient` with zero new dispatch. That is a real
architecture/contract change, not an ordinary debug iteration, and still requires review.

## Removal of false gates

The r7 autonomous recovery proposal and implementation were merged by #1193/#1194. The r9
singleton proposal and implementation were merged by #1206/#1207. Their stale `awaits review/merge`
task and verification text is not an admission fact and must not block GJ-4 hardware execution.

The `CORE-4.0.0` baseline may remain `candidate` until a separate ratification decision. Baseline
ratification status is not a per-Job authority and cannot be read by Runtime admission.

## Rejected alternatives

- **Run an unmerged daemon/provider against the device:** rejected; it would move transport,
  capability and trusted-fact ownership out of protected main.
- **Treat a candidate digest or green tests as authority:** rejected; neither proves target,
  Artifact, plan or outcome.
- **Restore the historical campaign confirmation:** rejected; r5 deliberately removed that human
  authority carrier and r10 needs no replacement authorization.
- **Merge after each safe failure:** rejected as the product defect being fixed. It makes review a
  runtime synchronization primitive and gives maintainers no coherent final change to review.
- **Retry the same candidate until the budget is gone:** rejected; the next dispatch requires a
  materially distinct decision or a Runtime-classified transient observation, and all existing
  unknown/cancellation/budget stops remain binding.

## Rollout

1. Review and merge the r10 decision before enabling candidate-backed destructive evaluation.
2. Implement the closed decision schema, isolated candidate adapter, Runtime validator,
   invocation ledger and fake-provider negative matrix without device access.
3. Run all host gates. Confirm that deleting any Runtime-side validation produces dispatch zero.
4. In one explicit GJ-4 device window, let the loop reach either real success or one truthful
   non-overridable blocker without an intermediate PR.
5. Promote the successful candidate through one ordinary final PR. No per-attempt branch or PR is
   created.

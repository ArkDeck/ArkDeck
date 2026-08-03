# Flashing Specification Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment`
> Target: `openspec/specs/flashing/spec.md`
> Baseline: `CORE-3.0.0`
> Proposed baseline: `CORE-4.0.0`

## MODIFIED Requirements

### Requirement: REQ-FLASH-015 Agent and ordinary CI destructive boundary

自主 Agent MAY dispatch a real Flash workflow containing `destructive` Step only when the
trusted host has validated an exact E2 authority. The authority SHALL be either a
maintainer-merged standing authorization matching the pending plan and target, or an unconsumed
bounded evolution campaign confirmation made in the same supervised interactive Agent session.
Standing authorization SHALL pin target identity/binding revision, firmware, transport, HDC,
Provider, plan/Step set, recovery path, validity and use limit. Campaign confirmation SHALL also
pin the protected-main base, candidate allowed paths/diff budget, build target/toolchain, exact
plan/target/data impact, validity and `maxAttempts`; the product SHALL accept at most 16 serial
attempts in four hours with concurrency one.

Before each real destructive Step, the protected-main broker SHALL re-materialize the published
typed plan; verify all authority and candidate/review pins; obtain fresh target/binding readback;
and durably reserve the ordinal. Any missing, expired, consumed, drifted or out-of-budget input,
non-PASS review, absent fresh reservation, non-terminal predecessor, uncertain identity/topology,
`outcomeUnknown`, unresolved intent or unsafe partial write SHALL fail closed: destructive
dispatch is 0 and the Job records the exact blocker/terminal disposition. Candidate, repairer and
reviewer SHALL not access device transport or authority and SHALL not expand argv, operation,
partition, plan, archive, step set or target. Only the broker may dispatch; it MAY continue the
same invocation only after the previous attempt is durable terminal and classified
`safeToReflash` from complete outcome/readback. No uncertain or unsafe outcome may be replayed.

Ordinary CI, daemon/scheduler and an Agent without one of these exact E2 authorities SHALL stay
on contract, fake, simulated or plan-only branches. Legacy one-shot `chatConfirmation` is
decode/export-only and cannot reserve, admit or dispatch. Evidence SHALL record the real executor,
authority kind/reference, fresh target confirmation, attempt ordinal and recovery/terminal
disposition; a campaign confirmation SHALL never be recorded as standing authorization. Evidence
or an after-the-fact chat message cannot retroactively authorize dispatch.

#### Scenario: AC-FLASH-015-01 Missing E2 authority blocks real Flash

- GIVEN an Agent or CI has a real device binding and an execute plan containing `flashPartition`,
  but has neither a valid exact standing authorization nor an unconsumed matching campaign
  confirmation from the same supervised interaction
- WHEN the trusted host evaluates the execution gate
- THEN destructive dispatch is 0 and the Job is `policyBlocked` with the missing authority
  reason
- AND the run cannot publish realHardware evidence

#### Scenario: AC-FLASH-015-02 E2 drift or unsafe predecessor blocks the next attempt

- GIVEN a pending Agent Flash has an authority, but any pinned target/binding, firmware,
  transport, HDC, Provider, plan/Step set, base/scope/toolchain/budget, candidate/review pin,
  reservation, freshness, predecessor terminal state or readback is missing, changed, expired,
  consumed, unsafe or unknown
- WHEN the broker validates the attempt immediately before its first real device Step
- THEN destructive dispatch is 0 and the Job records the specific blocker or terminal stop
- AND a later run record, hardware evidence or chat message cannot retroactively authorize it

#### Scenario: AC-FLASH-015-03 Exact E2 authority permits bounded Agent dispatch

- GIVEN an Agent has either a matching maintainer-merged standing authorization or an unconsumed
  same-session campaign confirmation, and the broker has re-materialized the published plan,
  passed independent review where applicable, obtained fresh target/binding readback and reserved
  the current ordinal within the 16-attempt/four-hour/single-concurrency budget
- WHEN the broker dispatches the execute plan
- THEN only the declared typed destructive Steps execute with durable intent and outcome records
- AND realHardware evidence records `executor.kind=agent`, the actual authority kind/reference,
  fresh target confirmation, attempt ordinal and terminal/recovery disposition
- AND success or any unsafe/unknown/drift/expiry/budget terminal condition permanently closes the
  campaign

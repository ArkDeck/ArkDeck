# Spec Impact

> Change：CHG-2026-003-dayu200-image-characterization@r1
> Core baseline identity：CORE-1.0.0
> Core/governance authority state：conflicting; Ready blocker
> Exact affected scope：`scope.yaml`

This implementation-only research change does not add, modify, remove or rename
any Core/capability Requirement, Acceptance Scenario or contract. Its outputs
are scanner implementation, offline evidence and recommendations. A later
Integration change must carry any catalog/fixture, and Route-B CLI capability
work needs its own behavior change.

The current repository simultaneously contains accepted/open ratification
records and protected candidate/closed current-state declarations. This Change
does not choose one side or edit the accepted protected set. A separately
scoped and approved governance/Core Change must publish and externally verify a
new `CORE-x.y.z` successor baseline that resolves the conflict without rewriting
`CORE-1.0.0` in place before this Task can become Ready.

If the work discovers that any Requirement, AC or contract must change, this
Change stops and a separate behavior/governance proposal is required.

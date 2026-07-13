# Ready Gate

> Status：blocked
> Reason：Pre-approval structural/pinning review has not passed.

- [ ] Change/Task approval subject IDs and exact hash targets are prepared; this review does not claim those approvals already exist
- [ ] Every Task packet validates against `task-packet.schema.json`
- [ ] Baseline, integration/platform profiles, conformance suite and base revision are exact pins
- [ ] Requirement/AC, path scope, dependencies, resources, verification and stop conditions are complete
- [ ] Every ready Task is `ready/unclaimed`; claim is created only after selection
- [ ] Supersession link/barrier inputs are structurally complete; approved lineage-head status is derived only after external approval
- [ ] Apply remains blocked when any protected input or hash drifts

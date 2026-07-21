# Spec Impact

> Change：CHG-2026-005-hdc-parser-golden-registration@r2
> Core baseline：CORE-2.0.0
> Exact affected scope：`scope.yaml`

This integration change does not add, modify, remove or rename a Core/capability Requirement,
Acceptance Scenario, policy or locked contract. `scope.yaml` is the single exact Requirement/AC/
Policy/Integration-profile set affected by this change.

The implementation task may version-bump and modify only the accepted OpenHarmony integration
profile, `INTEGRATION-PROFILES.lock.yaml`, `core-conformance.yaml` shared fixture inputs, the
versioned Golden resource pack, its SwiftPM test-resource declaration and its resource/hash test.
Those edits register evidence inputs and mappings; they do not by themselves satisfy
`AC-HDC-005-01` or any other HDC Scenario.

If fixture work discovers that a Core Scenario, evidence class, locked contract or parser behavior
must change, this change stops and a separately reviewed behavior/contract change is required.

# Discovery snapshot identity

Task: TASK-AIN-021

This GJ-1 discovery slice issues an opaque observation ID per candidate and a
daemon-session snapshot generation. The mainline discovery array did not expose
either value, so callers could not identify the exact observation they inspected.

## Compatibility and usage

`arkdeck device candidates --snapshot --output json` opts into the new additive
`device.observations` method. Its result contains `snapshotGeneration`,
`observedAtUtc`, `health`, `observationContinuity`,
`observationContinuityReason`, and `observations`. Each row reports
`observationId`, `candidateKey`, `authorizationState`, `adoptedTargetId`, and
`adoptedBindingRevision`. An adopted-target link is descriptive, not fresh proof
of physical identity or authorization to mutate a device.

Without `--snapshot`, the CLI retains the existing `device.candidates` method
and array shape in every output mode, including `--json`. App and Agent callers
are unchanged. `--use-warm-snapshot` remains available with either projection.
An older daemon may reject the new method; the CLI does not silently substitute
an array for a requested snapshot.

## Limits

IDs are generation-scoped: every committed enumeration issues fresh IDs, even
when a connect key is unchanged. A warm read preserves the cached generation,
IDs and observation time; it can schedule a subsequent background refresh.
Discovery alone cannot prove physical continuity across connect-key reuse.

These IDs are observation metadata, not durable target identity or capability.
This change does not implement observation-bound adoption, display-name writes,
device waiting or full target-contract conformance. Current control callers use
TargetObservationCoordinator and the single-v1 contract; this display-cache
registry cannot issue adoption authority.
No real-device acceptance is claimed by the host-side contract tests.

# What a readiness window would hit before it reached the device (2026-08-07)

Gate B closed by measurement, so the next step for this task is a D1 readiness window. Before
spending one, this checks whether the task's own prerequisites still describe the product. Two do
not. One is clerical and is fixed here; the other is not fixable from a readiness window at all.

Host-only. HDC command dispatch: 0. Device command dispatch: 0.

## 1. The evidence schema version — clerical, corrected here

The task requires "Agent-executed, current **V3** schema-valid `realHardwareE0ReadOnly`
evidence", and its `Notes / handoff` makes a **V3 evidence instance** one of the items readiness
must pin, under the rule *"缺任一项即保持 blocked"*.

The product can no longer emit one. `HardwareEvidenceProjector` writes `schemaVersion` from a
single literal, `"4.0.0"`, and its version enumeration lists `3.0.0` as **`legacyV3`** beside
`legacyV2` — historical decode labels, not producible shapes. The published contract is
`arkdeck://contracts/hardware-evidence/4.0.0`. `CHG-2026-056` raised it and `TASK-AIN-019` r19
synced the projector.

So a readiness that followed the task literally would be required to pin something unproducible,
and its own all-or-nothing rule would then keep the task blocked for a clerical reason discovered
inside a scarce device window. The six stale references in this task are corrected to name the
current contract rather than a frozen version number; the intent of each — the contract bytes are
forbidden, the instance must be current and schema-valid — is unchanged.

## 2. The reachability chain names a plane that was deleted — not fixable here

The task's `Production reachability` is:

```
Agent request/task authority → ArkDeckE0ProbeRegistrar → TrustedDeviceOperationHost(E0) →
durable binding + production HDC candidate/server/device facts → closed typed read-only plan → …
```

and its `Storage/host seam gate` says the registrar can be composed from "existing
`TrustedDeviceOperationHost`, `HostStorageCoordinator`, `SessionLayout` and
`SessionArtifactStore`".

Measured today: **`TrustedDeviceOperationHost` does not exist in `Sources/` at all** — zero files.
It was removed by #966, `refactor(TASK-DHA-001): delete the dead v1 device-operation plane and
zero-reference legacy code`. `AgentDeviceOperations/` now contains only `NativeDeployment`.

The storage half of that seam survives: `HostStorageCoordinator`, `SessionLayout` and
`SessionArtifactStore` are all still present. It is the host/admission half — the v1
device-operation plane the E0 registrar was to sit on — that is gone.

This is not a version mismatch and not something a readiness window can pin around. The task's
delivery path runs through a plane the repository declared dead and deleted, and deciding what
replaces it for E0 probe capture — the runtime job engine lane being the obvious candidate, but
that is a design decision and this document does not make it — is a scope revision, the same
class of decision r1 already asked for.

## Consequence for sequencing

Readiness is still not the next step, but the reason has changed. It is no longer "the device
tuple is unpinned"; that one gate was always going to close inside a window. It is that the
task's reachability chain does not describe the current product, and a window opened against it
would establish pins for a composition that cannot be built.

Order that avoids wasting a window:

1. a scope revision re-basing E0 registration onto the current execution plane (maintainer, D1);
2. then D1 readiness, which pins exact argv, budgets, storage layout, the **current** evidence
   instance, the human boundary, the privacy allowlist — and the device/build tuple via a
   registered `list targets -v`, the one item that genuinely requires the window.

Nothing here changes the task's status, its risk grade or its hardware requirement, and nothing
here decides the replacement plane.

# CLI doctor report

`arkdeck doctor` is the read-only entry check for the headless product loop. It negotiates control protocol 2 and requests the Runtime-owned `doctor` method. The command does not create a Job, Artifact, evidence, capability, control action, or device dispatch.

The Runtime returns `arkdeck.doctor-report/1` with these invariant fields:

- `overall`: `healthy`, `degraded`, or `blocked`;
- `ready`: `false` exactly when at least one blocker is present;
- `findings`: ordered structured findings with `code`, `severity`, `scope`, and `summary`;
- `findingCounts`: the exact info, warning, and blocker counts;
- `checks`: Runtime, Catalog, provider, HDC, storage, target, and recovery projections.

Standard mode uses bounded configuration and Catalog checks. `--deep` additionally observes the selected HDC process identity, accounts the Runtime Artifact quota, and reads outstanding cleanup debt. A failed deep subcheck is retained as a blocker finding so the rest of the report remains available.

Storage remains split into `runtimeArtifacts` and `sessionOutput`. The Runtime can account its Artifact store. Until Session output has a single Runtime owner, that domain reports `unavailable` with `storage.sessionOutputOwnerNotPublished`; the doctor never reads App preferences or combines the two roots.

Without `--require-healthy`, a completed report exits zero even when it describes unavailable components. With `--require-healthy`, `ready: false` becomes `healthRequirementFailed` and exit 69; the full report is retained in error details. The CLI does not classify finding prose or keep a second blocker list.

Control protocol 1 keeps the historical flat doctor projection for compatibility. The CLI target command always negotiates protocol 2.

# CHG-2026-022 r2 review remediation record

> Date: 2026-07-21
> Evidence class: source/design review only; no implementation or hardware evidence

## Findings

1. `OBS-FANOUT-001` had no production data source. The macOS profile permits
   `selectedDeviceAuthorizationBinding` only for the exact registered
   `list targets -v` capture matched to an existing durable binding and states
   that arbitrary-device support requires a separate integration change.
   App production composition contained no arbitrary-device enumeration and
   lifecycle participant inventory remained honestly `.complete([])`.
2. `OBS-COUNTER-001` had no satisfiable unforgeable production origin. The
   Supervisor intentionally has no automatic executor; a caller-supplied enum
   can misclassify manual dispatch, while direct monitor mutation is not a real
   dispatch point. The accepted replacement is an opaque-permit classification
   at the unique successful identity-bound spawn hook.
3. The three-item ownership basis could overwrite an existing
   `.arkDeckManaged` state with `.external`. The replacement matrix includes
   managed-launch provenance and prohibits direct managed-to-external
   transition before explicit reconcile/retire.
4. r1 readiness wrote abbreviated file SHA-256 values as “blob” pins. Exact
   historical commit, Git blob OID and file SHA-256 values are recorded in
   `tasks.md`; future readiness must pin its actual base with complete values.

## Disposition

- TASK-OBS-001 returns to `blocked` when this r2 governance PR is reviewed and
  merged by the maintainer.
- TASK-OBS-002 remains blocked.
- Draft prototype PR #265 and its invalidated run are diagnostic inputs only;
  they are not implementation completion or acceptance evidence.
- Resumption requires the five unblock prerequisites in `tasks.md` and a
  separate readiness PR. This record does not authorize implementation.

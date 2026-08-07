# Verification Plan

> Change:CHG-2026-056-e2-policy-baseline-alignment@r7
> Status:planned
> Baseline:`CORE-3.0.0` -> proposed `CORE-4.0.0`
> Proposal phase executes zero real device, Runtime capability, recovery or history mutation.

## Environment

- Proposal review: latest protected `main`; no HDC/RockUSB/device/Runtime-store access.
- Host implementation: macOS, pinned toolchain, fake/scripted Providers, immutable journal fixtures
  and temporary stores only.
- Real validation after approval and implementation: production signed ArkDeck App,
  protected-main Runtime, exactly one bound DAYU200 and the supplied OpenHarmony 7.0.0.35 archive.
- The standalone UI driver is explicit manual real-device tooling and remains absent from default
  Swift/Xcode/UI test discovery.

## Acceptance matrix

| Acceptance | Method | Expected result | Evidence |
| --- | --- | --- | --- |
| `POL-RECOVERY-001`, `POL-AGENT-002`, `E2R-CATALOG-001` | Cross-file policy/Catalog/Provider audit | Flash remains typed and destructive; no E2/UI/chat authority returns; only reviewed exact operation/profile pairs may declare complete-overwrite recovery | document + contract |
| `AC-FLASH-015-03`, `E2R-RUNTIME-001` | Fake initial Agent Flash through production Runtime composition | Runtime mints/reserves its exact capability and dispatches published fake Steps with no authority or user-message input | contract |
| `AC-FLASH-015-02`, `AC-JOB-001-03`, `AC-JOB-001-05`, `AC-JOB-006-01`, `E2R-RECOVERY-001` | Seed durable outcomeUnknown, known identity and a fully covering Provider plan; run launch and live recovery | Original Step dispatch stays 0; a distinct capability/reservation/intent executes complete overwrite automatically; only all confirmed effects + reboot/rebind/postflight create recovered target epoch | contract/fault |
| `AC-FLASH-015-01`, `E2R-RECOVERY-NEGATIVE-001`, `E2R-NEGATIVE-001` | Pairwise faults over identity, binding/topology, effect closure, omitted/protected partition, coverage declaration, Artifact/tool/plan drift, caller proof, cancellation, expiry and budget | Original replay and recovery dispatch both remain 0; exact durable blocker is produced and has no approval override | contract/fault |
| `AC-WF-004-01`, `AC-WF-004-02`, `E2R-HISTORY-001` | Immutable old-unknown + later-Flash fixtures with varied facts | Only complete same-target, ordered, full-coverage, per-effect and postflight proof appends a supersession relation with zero hardware dispatch; old bytes/outcome remain unchanged | schema/compatibility contract |
| `AC-WF-004-03`, `E2R-COMPAT-001` | V1–V5 decode/export and V6 writer fixtures | Legacy authority/evidence/recovery bytes remain readable and immutable; none can mint capability, coverage or a supersession relation | compatibility contract |
| `AC-FLASH-007-01`, `AC-FLASH-013-01`, `E2R-NOQUESTION-001` | Agent/UI/human-action surface audit and fake eligible/ineligible flows | Initial Agent Flash, ordinary continuation and eligible recovery require no UI/chat/human decision; ineligible state is a diagnostic blocker, never an approval question | platform + contract |
| `E2R-GJ4-001` | After approval and host gates, execute the production UI driver on one real DAYU200; inspect Job/Session/Artifact/postflight/recovery lineage | Target lane is mechanically reconciled or recovered, real UI Flash succeeds, flashed build is read back, V6 evidence is truthful, and no E2/campaign/chat/outcome-decision prompt occurs | realHardware |

## Positive recovery vectors

1. `safeToReflash` confirmed failure: ordinary next attempt remains unchanged.
2. One unknown partition-write intent with complete effect closure: Runtime dispatches a distinct
   complete-overwrite recovery, never the original Step.
3. Multiple old and new unknown intents: recovery plan covers the union and total epoch budget is
   shared; one omitted effect rejects the whole recovery.
4. Recovery itself loses its outcome: its effect set joins the union; another recovery is possible
   only after a fresh complete proof and while the shared budget remains.
5. A later immutable real Flash already covers every old effect and has semantic postflight:
   Reconciler appends only a supersession relation and performs zero device dispatch.

## Negative and recovery tests

- Prove original unknown intent IDs, capability uses, Step IDs and journal bytes are never reused or
  rewritten by recovery.
- Reject unknown/different physical identity, stale binding, ambiguous USB topology, missing loader
  prerequisite, unstable power or mismatched Provider/tool.
- Reject an unbounded effect set and coverage that omits any optional, conditional, userdata,
  metadata, protected or unverifiable effect.
- Reject caller/Agent/UI/chat/evidence-supplied effect sets, coverage classifications, target facts,
  capability fields, outcomes and supersession links.
- Reject archive/Artifact/lease/hash/plan/Step-set drift and any candidate change to operation,
  partition, executable or argv.
- Reject recovery after explicit cancellation, attempt 17, elapsed time >= four hours or
  concurrency > 1.
- Crash before/after recovery reservation, intent, individual outcomes, postflight and supersession
  append; replay must never duplicate an external effect or publish a premature known epoch.
- For historical recognition, vary target, ordering, partition universe, one write outcome,
  reboot/rebind and runtime-build readback independently; any missing fact appends nothing.
- Scan UI and Runtime responses: eligible paths contain no human-action request; ineligible paths
  contain a stable machine-readable blocker and no “confirm/continue anyway” action.
- Scan logs/evidence for raw device identity, local user path, secrets and authority/capability bytes.

## Host gates before hardware

```bash
sh scripts/check-sdd.sh
.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"
.venv-sdd/bin/python scripts/catalog_gen/generate.py --check
swift test --package-path Packages/ArkDeckKit --parallel --num-workers 8
python3 scripts/check_pr_paths.py --repo-root . --preflight \
  --base-revision origin/main --head-revision HEAD
```

Every command must exit 0. Focused tests, fake recovery and simulation are development feedback;
they do not replace `E2R-GJ4-001` or authorize hardware.

## Proposal-phase non-interference

- Diff is confined to `openspec/changes/chg-2026-056-e2-policy-baseline-alignment/**`.
- Device/HDC/RockUSB, Runtime dispatch, capability/reservation and history mutation counts are 0.
- Existing waitingForRecovery Jobs and target-lane claims remain untouched.
- No proposal result is hardware evidence, recovery proof or `REAL_DEVICE_PASS`.

## Deviations

Any need for a new operation/Provider/profile, partition or argv change, caller-controlled proof,
identity relaxation, original-intent replay, coverage omission or path outside the approved task
requires another revision of this same change and maintainer review before implementation.

## Result gate

- [x] r5/r6 no-E2 adjudication and implementation are present on protected `main` through
  #1178/#1181/#1183.
- [ ] r7 is reviewed and merged by the human maintainer before implementation begins.
- [ ] All canonical and change-local contract acceptance passes.
- [ ] All host gates pass at the exact implementation head.
- [ ] Real DAYU200 autonomous recovery/UI Flash/postflight passes with truthful V6 evidence.
- [ ] macOS disposition is reviewed; Windows/Linux remain deferred.

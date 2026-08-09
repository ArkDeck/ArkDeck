# Verification Plan

> Change:CHG-2026-056-e2-policy-baseline-alignment@r11
> Status:planned
> Baseline:`CORE-3.0.0` -> proposed `CORE-4.0.0`
> Proposal phase executes zero real device, Runtime capability, recovery or history mutation.

## Environment

- Proposal review: latest protected `main`; no candidate-backed HDC/RockUSB/device/Runtime-store
  access.
- Host implementation: macOS, pinned toolchain, fake/scripted Providers, immutable journal fixtures
  and temporary stores only.
- Real validation after approval and implementation: production signed ArkDeck App,
  protected-main Runtime, exactly one bound DAYU200 and the supplied OpenHarmony 7.0.0.35 archive.
- The standalone UI driver is explicit manual real-device tooling and remains absent from default
  Swift/Xcode/UI test discovery.

## Acceptance matrix

| Acceptance | Method | Expected result | Evidence |
| --- | --- | --- | --- |
| `POL-RECOVERY-001`, `POL-AGENT-002`, `E2R-CATALOG-001` | Cross-file policy/Catalog/Provider/UI audit | Flash remains typed and destructive; only bare `flash.dayu200` is published/displayed; Steps/effect/Provider remain unchanged; exactly one profile `dayu200` retains the current recovery coverage; versioned operation/profile strings are rejected; no E2/UI/chat authority returns | document + contract |
| `AC-FLASH-015-03`, `E2R-RUNTIME-001` | Fake initial Agent Flash plus two isolated candidate decisions through production Runtime composition | Runtime independently validates the closed repair envelope, mints/reserves its exact capability and dispatches published fake Steps with no authority, Git/PR/merge or user-message input | contract |
| `AC-FLASH-015-02`, `AC-JOB-001-03`, `AC-JOB-001-05`, `AC-JOB-006-01`, `E2R-RECOVERY-001` | Seed durable outcomeUnknown, known identity and a fully covering Provider plan; run launch and live recovery | Original Step dispatch stays 0; a distinct capability/reservation/intent executes complete overwrite automatically; only all confirmed effects + reboot/rebind/postflight create recovered target epoch | contract/fault |
| `AC-FLASH-015-01`, `E2R-RECOVERY-NEGATIVE-001`, `E2R-NEGATIVE-001` | Pairwise faults over identity, binding/topology, effect closure, omitted/protected partition, coverage declaration, Artifact/tool/plan/repair-envelope drift, candidate/caller proof, cancellation, expiry and budget | Original replay, invalid candidate and recovery dispatch all remain 0; exact durable blocker is produced and has no approval override | contract/fault |
| `AC-WF-004-01`, `AC-WF-004-02`, `E2R-HISTORY-001` | Immutable old-unknown + later-Flash fixtures with varied facts | Only complete same-target, ordered, full-coverage, per-effect and postflight proof appends a supersession relation with zero hardware dispatch; old bytes/outcome remain unchanged | schema/compatibility contract |
| `AC-WF-004-03`, `E2R-COMPAT-001` | V1–V5 decode/export and V6 writer fixtures | Legacy authority/evidence/recovery bytes remain readable and immutable; none can mint capability, coverage or a supersession relation | compatibility contract |
| `AC-FLASH-007-01`, `AC-FLASH-013-01`, `E2R-NOQUESTION-001` | Agent/UI/human-action surface audit and fake eligible/ineligible flows | Initial Agent Flash, eligible next candidate and recovery require no UI/chat/human or per-attempt PR/merge decision; ineligible state is a diagnostic blocker, never an approval question | platform + contract |
| `AC-FLASH-010-02` | Exact advanced target + displaced active binding + correlated owner-only Runtime intent/receipt fixtures | Fresh exact Loader reactivates the same revision without a target-store write; non-adjacent revision, provider/hash/receipt drift and multiple topologies leave binding/target byte-stable and dispatch zero | contract/fault |
| `E2R-GJ4-001` | After approval and host gates, execute one Runtime-owned candidate-debug invocation on one real DAYU200; inspect Job/Session/Artifact/candidate/postflight/recovery lineage | Target lane is mechanically reconciled or recovered, real UI Flash succeeds or stops once with a truthful blocker, flashed build is read back on success, V6 evidence is truthful, and no intermediate PR or E2/campaign/chat/outcome-decision prompt occurs | realHardware |

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
- Reject `dayu200@1` and `dayu200@2` in Catalog lookup, Provider profile selection and Runtime
  recovery matching; accept exactly `dayu200`, with no alias or silent durable-record migration.
- Reject a Catalog that publishes bare `dayu200` together with any versioned variant, and prove the
  sole recovery universe remains the current nine-partition set.
- Assert the sole operation source is `Catalog/operations/flash.dayu200.json` and the old
  `.v1.json` path is absent; its document has no `version`, new wire/capability writers omit it, and
  `flash.dayu200@1` is decode/export-only legacy that cannot match or dispatch.
- Scan App/UI tests/localization/prototype/CLI/Agent/Provider output and require the sole visible
  operation label `flash.dayu200`, with no DAYU200 `.v1`/`@1` suffix.
- Assert DAYU200 hitrace/bytrace families expose no `-v1` suffix and their updated registry digest
  remains closed over the unchanged golden-resource manifest.
- Present an old rev2/chat-attestation binding and prove Runtime reports it unprepared, rejects
  same-revision replacement, leaves the bytes unchanged and dispatches no Flash effect.
- Present a displaced advanced target and prove reactivation requires the exact current-revision
  reconnect intent plus a directly-previous-revision, same-provider, same-connect-key confirmed HDC
  route receipt. Independently vary target, revision, provider executable, stable identity, connect
  key, action hash, receipt correlation, file ownership/mode, truncation and topology; every
  mismatch leaves binding/target unchanged and dispatches zero.
- Present two individually valid HDC route receipts with different topologies and prove Runtime
  refuses rather than ranking either route. Prove an exact committed reactivation can retry after a
  lost response but cannot emit `RuntimeTargetBindingLineageAdvance` or binding recovery proof.

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

## r9 host-validation non-interference

- Local implementation changes only Catalog/source/tests/docs inside the reviewed task paths.
- Device/HDC/RockUSB, Runtime dispatch, capability/reservation and history mutation counts are 0.
- Existing waitingForRecovery Jobs and target-lane claims remain untouched.
- No host-test result is hardware evidence, recovery proof or `REAL_DEVICE_PASS`.

## r10 candidate-loop verification addendum

- Fake-provider tests must run two or more isolated candidates inside one Runtime-owned invocation
  and prove there is no Git/PR/merge/chat field in the invocation or admission inputs.
- The candidate output decoder accepts only the closed decision grammar. Fuzz every forbidden
  authority, fact, target, plan, Step, executable, argv, outcome and coverage field and require
  external dispatch 0.
- Runtime recomputes the operation, plan, target/binding, Artifact, tool and decision envelope from
  protected sources after candidate evaluation and again before the first external effect.
- An ordinary next destructive epoch requires a durable predecessor `safeToReflash`; unknown
  intent uses only the existing complete-overwrite recovery proof and is never replayed.
- Candidate provenance is durable but cannot satisfy any admission predicate. Removing any
  Runtime-derived proof or introducing digest drift rejects the candidate.
- The DAYU200 repair envelope covers the observed mode/deadline/HDC-personality/postflight repair
  space without exposing raw serial/topology or allowing a candidate-selected target.
- One real GJ-4 invocation may begin only after r10 approval and all host gates. It must finish or
  stop truthfully without an intermediate PR; only the final successful candidate is promoted.
- Exercise the protected pre-admission actuator with at least two materially distinct closed UI
  candidates in one session: a refused candidate creates no Job, and the next candidate can reach
  `UI_REVIEW_PASS` without Git/PR/merge input. The candidate cannot name identities, facts, control
  identifiers, the submit action, executable/argv or authority.
- Once the fixed submit barrier is crossed, crash/timeout before a terminal observation seals the UI
  session as `submissionOutcomeUnknown`. A terminal non-success moves to Runtime continuation; only
  the exact accepted request, stripped of App client context and captured owner-only, can seed the
  existing Runtime debug invocation.

## Deviations

Any need for a new operation/Provider/profile, partition or argv change, caller-controlled proof,
identity relaxation, original-intent replay, coverage omission or path outside the approved task
requires another revision of this same change and maintainer review before implementation.

## Result gate

- [x] r5/r6 no-E2 adjudication and implementation are present on protected `main` through
  #1178/#1181/#1183.
- [x] r7 proposal/implementation are present on protected `main` through #1193/#1194.
- [x] r9 proposal/implementation are present on protected `main` through #1206/#1207.
- [x] r10 was reviewed and merged by the human maintainer in #1217 before candidate-backed
  device use; this is the protected-main policy boundary implemented by the follow-up product PR.
- [ ] r11 displaced-binding reactivation policy and product code are reviewed/merged together
  before any candidate build or reactivated binding is used against hardware.
- [ ] All canonical and change-local contract acceptance passes.
- [ ] All host gates pass at the exact implementation head.
- [ ] Real DAYU200 autonomous recovery/UI Flash/postflight passes with truthful V6 evidence.
- [ ] macOS disposition is reviewed; Windows/Linux remain deferred.

# Verification Plan

> Change:CHG-2026-056-e2-policy-baseline-alignment@r5
> Status:planned
> Baseline:`CORE-3.0.0` -> proposed `CORE-4.0.0`
> Proposal phase executes zero real device/authority/capability action.

## Environment

- Proposal review: latest protected `main`; no HDC/RockUSB/device access.
- Host implementation checks: macOS, pinned project toolchain, fake/scripted Providers and
  temporary stores only.
- Real validation after approval/implementation: production signed ArkDeck App, protected-main
  Runtime broker, exactly one bound DAYU200 and the user-supplied OpenHarmony 7.0.0.35 archive.
- The standalone UI driver is invoked explicitly and is absent from default test discovery.

## Acceptance matrix

| Acceptance | Method | Expected result | Evidence |
| --- | --- | --- | --- |
| `POL-AGENT-002`, `E2R-CATALOG-001` | Cross-file source audit plus catalog schema/generator unit and zero-drift checks | No new writer/admission requires E2/standing/campaign; both published destructive operations retain their effect and typed Steps while using unified RuntimeCapability policy | document + contract |
| `AC-FLASH-015-03`, `E2R-RUNTIME-001` | Fake broker end-to-end request with no authority/chat fields | Runtime materializes exact facts, mints/reserves its own capability and dispatches only declared fake typed Steps | contract; never hardware |
| `AC-FLASH-015-01`, `AC-FLASH-015-02`, `E2R-NEGATIVE-001` | Fault matrix over target/binding/input/plan/archive/artifact/tool/freshness/caller fields/reservation/lineage/outcome/cancel/expiry/budget | Every missing, forged, drifted, unknown, unresolved or unsafe case has new external dispatch count 0 | contract/fault |
| `AC-WF-004-01`, `AC-WF-004-02` | V5 schema/projector/semantic correlation fixtures | New read-only evidence uses default policy; mutation/destructive uses RuntimeCapability; incomplete facts publish 0 | schema/contract |
| `AC-WF-004-03`, `E2R-COMPAT-001` | Versioned decode/export fixtures plus legacy admission/migration negatives | V1-V4 bytes round-trip through legacy readers; standing/campaign cannot write V5, mint capability or dispatch | compatibility contract |
| `AC-FLASH-007-01`, standalone UI driver | Build/source membership audit and explicit accept/cancel dry navigation runs with fail-on-dispatch fixture | Cancel submits no request/capability/reservation; accept is UX-only; driver is absent from Swift/Xcode/default UI test discovery and navigation never claims Flash success | platform/contract |
| `E2R-GJ4-001` | After approval and all host gates, run production UI driver on one real DAYU200; inspect Job/Session/Artifact and postflight device version | Typed Flash succeeds, userdata impact is truthful, postflight proves the flashed build, V5 evidence records real executor/capability/use; no manual authority/campaign step | realHardware |

## Negative and recovery tests

- Reject caller-supplied RuntimeCapability bytes, capability IDs, trusted digests, target facts,
  Provider/argv/partition/Step overrides and UI/chat approval fields.
- Reject operation/version, Catalog, stable identity, binding, input, plan, Step set, archive,
  Artifact lease/hash, provider/tool, freshness and reservation drift.
- Crash before reservation, after reservation/before intent, after intent/before outcome and after
  outcome/before evidence; restart must reconcile without duplicate effect.
- Disconnect/cancel/timeout at every Flash safe boundary; any uncertain external outcome enters
  durable recovery and never obtains another use.
- Reject next attempt unless predecessor is durable terminal `safeToReflash`; reject attempt 17,
  elapsed time >= four hours and concurrency > 1.
- Decode historical standing/campaign/evidence bytes without mutation; reject new admission,
  migration, V5 projection or dispatch from them.
- Scan logs/evidence for raw device identity, local user path, secrets and authority bytes.

## Host gates before hardware

```bash
sh scripts/check-sdd.sh
.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"
.venv-sdd/bin/python scripts/catalog_gen/generate.py --check
swift test --package-path Packages/ArkDeckKit --parallel --num-workers 8
python3 scripts/check_pr_paths.py --repo-root . --preflight \
  --base-revision origin/main --head-revision HEAD
```

Every command must exit 0. Focused tests and simulation are development feedback only and do not
replace these gates or `E2R-GJ4-001`.

## Proposal-phase non-interference

- Diff is confined to `openspec/changes/chg-2026-056-e2-policy-baseline-alignment/**`.
- Device, HDC, RockUSB, authority/capability store and Runtime Job dispatch counts are 0.
- Any previously confirmed campaign remains unconsumed and is neither referenced nor migrated.
- No proposal result is hardware evidence or `REAL_DEVICE_PASS`.

## Deviations

Any deviation requires an explicit revision of this same change and maintainer review. No test,
platform limitation or elapsed device window may silently weaken the retained safety boundaries.

## Result gate

- [ ] r5 has been explicitly approved on protected `main` before implementation begins.
- [ ] All canonical and change-local contract acceptance passes.
- [ ] All host gates pass at the exact implementation head.
- [ ] Real DAYU200 UI Flash and postflight pass with truthful V5 evidence.
- [ ] macOS disposition is reviewed; Windows/Linux remain deferred.

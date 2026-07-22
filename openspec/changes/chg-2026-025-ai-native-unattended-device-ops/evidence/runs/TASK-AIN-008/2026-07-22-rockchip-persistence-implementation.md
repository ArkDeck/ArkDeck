# TASK-AIN-008 Rockchip persistence implementation run — 2026-07-22

- Task: `TASK-AIN-008 — Rockchip descriptor identity persistence gap`
- Branch: `agent/ain-008-persistence`
- Approved base: readiness PR #311 merged as
  `d3c7440e8b40c79f2a6ea6fb3ec181ee8e5bb5f5`
- Environment: macOS 26.5.2 (25F84), Xcode 26.6 (17F113), Apple Swift 6.3.3
- Classification: host/fake-only contract and persistence validation; network, real device, HDC,
  rkdeveloptool, product process launch and destructive dispatch attributable to this run were all
  zero

## Work performed

1. Added change-local Manifest and Journal Draft 2020-12 schemas at exact version `2.1.0`.
   Journal 2.1 inherits the v2 authorizedAgent payload shape without caller fields. Manifest 2.1
   adds the single closed Rockchip toolchain shape with pinned profile/version/hash/path source and
   numeric descriptor identity. Absolute/stable paths, bookmark bytes, caller labels, argv,
   environment and unknown members are not representable.
2. Extended the Storage readers, semantic validators, replay and Manifest/journal publication
   correlation for 2.1 while retaining exact single-version Session behavior. Existing `hdc|none`
   toolchain shapes remain readable. Rockchip is accepted only in non-simulated 2.1 Manifests and
   exact profile constants plus positive bounded descriptor fields are required.
3. Preserved the exact `ProcessExecutableIdentityReceipt` from the same trusted tool/device fact in
   internal final admission facts and through one-shot consumption. No public initializer, Codable
   surface, command, intent or dispatch capability was added.
4. Extended diagnostic export allowlisting only for `profileIdentifier`, `reportedVersion` and
   `pathSource`; existing `kind`/`sha256` and numeric descriptor fields round-trip. Local authorized
   path, stable descriptor path, bookmark material, stdout/stderr, argv and environment do not enter
   the Manifest or export.
5. Added `TEST-AIN-ROCKCHIP-PERSISTENCE-001` positive and negative coverage plus an offline schema
   validation helper. Negatives cover missing/drifted pinned strings, missing/non-positive/oversized
   descriptor fields, forbidden/extra fields, v2 Rockchip misuse, mixed Session versions and
   authorization usage drift.

## Verification commands and results

### Focused persistence, v2 regression and admission equality

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'AuthorizationAdmissionContractTests|SessionArtifactStorageContractTests/testAuthorizedAgentV2ManifestJournalRoundTripAndGhostActorDriftRejection|SessionArtifactStorageContractTests/testTEST_AIN_ROCKCHIP_PERSISTENCE_001'
RESULT: 6 tests executed, 0 failures
```

Canonical summaries emitted:

```text
TEST-AIN-FACT-001 PASS facts=trusted correlation=same-admission serial=readback executable-identity=same-receipt capability=one-shot dispatch=0
TEST-AIN-USAGE-001 PASS maxRuns=1 atomic-winner=1 retry=idempotent crash-after-replace=consumed no-refund=true
TEST-AIN-CONTRACT-001 manifest-v2=PASS device_dispatch=0 external_process=0
TEST-AIN-ROCKCHIP-PERSISTENCE-001 manifest=2.1.0 journal=2.1.0 identity=descriptor-bound export=non-sensitive negatives=closed-shape mixed-version=rejected dispatch=0
```

The positive test publishes a terminal 2.1 journal and Manifest with exact authorization,
reservation and destructive-intent correlation, then exports and reparses the Manifest. The
descriptor receipt remains numerically exact and the export contains none of the forbidden local
identity or caller-controlled fields.

### Draft 2020-12 schema validation

```text
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/private/tmp/arkdeck-sdd-python \
  /Users/fuhanfeng/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-008/schema-validation.py
RESULT: SCHEMA-AIN-008 PASS draft=2020-12 manifest-positive=1 manifest-negative=19 journal-positive=1 journal-negative=3 network=0

python3 -m json.tool openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/manifest.schema.v2.1-draft.json
python3 -m json.tool openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/journal-event.schema.v2.1-draft.json
RESULT: both JSON documents parsed successfully
```

The helper uses only checked-in schemas and fixtures. It performs no network access and does not
write a product Artifact or claim hardware evidence.

### Full Swift regression

```text
CI=true swift test --package-path Packages/ArkDeckKit
RESULT: 346 tests executed, 1 skipped manual sleep/wake observation, 0 failures
```

The existing full suite includes controlled local-process contract fixtures. TASK-AIN-008's new
tests and schema helper are host/fake-only and launched no product external process or device
operation.

### SDD, format, immutability and scope hygiene

```text
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/private/tmp/arkdeck-sdd-python sh scripts/check-sdd.sh
RESULT: check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

xcrun swift-format format --in-place <eight allowed Swift source/test paths>
xcrun swift-format lint --strict <eight allowed Swift source/test paths>
git diff --check
RESULT: PASS

git diff --exit-code origin/main -- \
  openspec/contracts/manifest.schema.json \
  openspec/contracts/journal-event.schema.json \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/manifest.schema.v2-draft.json \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/journal-event.schema.v2-draft.json
RESULT: PASS; historical v1/v2 schema bytes unchanged

git hash-object \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/manifest.schema.v2-draft.json \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/journal-event.schema.v2-draft.json
RESULT:
9ac334013968a5aba1a0bd77fe2acc982ba0e680
6285acd4ca0350d427aa624afa91be3107769a64
```

All readiness input blobs were rechecked against their pinned OIDs before implementation. The
working-tree path set is a subset of TASK-AIN-008's allowed paths. Current specs/contracts,
baseline, historical v1/v2 schema files, Provider/Profile, Process/Runtime, admission/provenance/
usage ledger, CLI and AIN-007 executor files are unchanged.

## Acceptance conclusion

- `TEST-AIN-ROCKCHIP-PERSISTENCE-001`: **PASS** for exact 2.1 terminal persistence, export and
  fail-closed negative vectors.
- Admission receipt equality: **PASS**; collector fact, final facts and consumed capability carry
  the same descriptor-bound `ProcessExecutableIdentityReceipt`.
- Historical v1/v2 and authorizedAgent correlation regression: **PASS**; no in-place rewrite and
  mixed versions remain rejected.
- Draft 2020-12 positive/negative validation: **PASS** for both new schemas.
- Network/HDC/rkdeveloptool/real-device/product-process/destructive dispatch attributable to this
  run: **0**.

## Deviations and residual risk

- No task scope or acceptance deviation. The first sandbox-only Swift invocation could not write
  the user Clang module cache; it failed before build/test execution and was rerun through the
  repository-approved controlled outside-sandbox Swift test path. This is an environment note, not
  a product failure.
- This task defines and validates persistence truth but does not construct or execute an AIN-007
  Rockchip product executor. No realHardware result, standing authorization use or device evidence
  is claimed.
- TASK-AIN-008 remains `ready` in this implementation PR. Marking it `done`, repinning AIN-007 and
  changing any change verification status require later, separate maintainer-reviewed PRs.

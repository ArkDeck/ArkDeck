# TASK-AIN-009 implementation run

Date: 2026-07-28

Classification: host-only contract/schema validation. This run is not real-device, hardware,
HDC, product-executor, control-plane, E0, E1, or E2 execution evidence.

## Authorization, base, and scope

- Fresh D1 readiness PR #735 exact head
  `fbefb13633d830c8a9d3c28c692bcc5cbd12853a` was approved by CODEOWNER `lvye`
  and merged as `3497e90c91cc5bbefc528233fc159227bd516427`.
- Implementation branch: `agent/task-ain-009`.
- Final protected-main base:
  `07daee30ba99636b5dc7a334bdefc3a07611acef`. The protected-main advances
  during implementation were #737 and #738, confined to
  `openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/**`; they have zero
  path/input intersection with this task.
- Environment: macOS 26.6 (`25G72`), arm64, Xcode 26.6 (`17F113`), Apple Swift
  6.3.3.
- Changed paths are limited to the four change-local contract/registry paths, this
  run directory, and
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceOperationContractTests.swift`.
  Current specs/contracts, Sources, App, Package.swift, and tasks.md are unchanged.

The readiness input blobs were rechecked after the final protected-main update and
remain exact:

| Input | pinned blob |
| --- | --- |
| agent-device-operation input draft | `1e76c4a334a0fe0155cb1deb5bc269bd07e69599` |
| human-action-required input draft | `cea4402b5c0fcabc143294d9aa1e0f3822fc550a` |
| design.md | `bde7c336550bfd9074abf25c2510a1adc5710f1e` |
| manual-boundary-inventory.md | `67468b5304704ec62f3a61b5ed247bb2a6190d97` |
| workflow-step.schema.json | `c510d96478f3192168478b1a1669b5fcd2a848f7` |
| workflow-step-registry.yaml | `d9121ef78531560ab856dfa07468ce1ab4d42df6` |
| provider-contracts.md | `ceb6709fb405fc46d72ef2126b715e252ac720ab` |
| journal-event.schema.json | `d25b7a55e9970d301558430febd235ccc910d8b7` |
| WorkflowStep.swift | `d96423593978f84a0db7623a1b94863e5d12de26` |
| JobStateMachine.swift | `c7350e2f74fcbb52a6e582c09c063c5dda0f13f6` |
| StrictJSON.swift | `d5df2a82ced6b8a06635c1e9f1887d70c693f005` |

## Contract result

1. Finalized `agent-device-operation` and `human-action-required` Draft 2020-12
   schemas at exact `$id`/`schemaVersion` 1.0.0. Every explicit object is closed.
2. Added a closed operation registry schema and instance covering exactly 15
   operations, 21 protected-main exact-descriptor profiles, 41 existing Core Step
   kinds as the only Step fact source, and 8 human blocker rules.
3. Request shape contains intent only. The vector corpus separately rejects each
   of the 20 forbidden caller facts plus nested and case-variant forms.
4. Result shape uses the exact 18 Core JobState values and a separate closed
   disposition. E0/E1/E2 authorization references are closed discriminated unions
   and must match `readOnly/deviceMutation/destructive` respectively.
5. Profile validation resolves every emitted Step through the current Core
   registry and takes the per-dimension maximum of operation floor, profile
   declaration, and Core minimum. Unknown operation/profile/Step, incomplete
   mapping, downgrade, and illegal elevation all fail closed.
6. Human records cover the exact 8 categories and 9 prohibited-automation values.
   Only the category's registered read-only probe plus a fresh receipt may produce
   `resolvedByFreshProbe`; text/assertion is not a resolution input.

Final file identities, excluding this self-referential run carrier:

| Path | SHA-256 | Git blob |
| --- | --- | --- |
| `contracts/agent-device-operation.schema.v1-draft.json` | `1450675a80a30d6e7b6060295de28e2e6cecb4ab9cf2cce2ecdfd0027496e96a` | `b2f41f6d14f18621561acbe93dbfccc3621405f4` |
| `contracts/human-action-required.schema.v1-draft.json` | `1cd4519f9491ce3a0f4f8725e15423d32f47caaff642270d0052dfed77e42d25` | `4bf28c508b81744a26334b9356d63b70be7bc039` |
| `contracts/agent-device-operation-registry.schema.v1-draft.json` | `13e0014359d8397603e7e3788568d6f15e278592536c683198d32156ff4fafe7` | `f75e5d97130d15f3133cb19b73420438db0bfc18` |
| `contracts/agent-device-operation-registry.v1-draft.json` | `926ba3d88fd8509ce9e9ebb66654f285624738a96d14916a0ad8ed0a5a929259` | `f101619358b08ffb818ccc8eac72b06c7b2062fe` |
| `evidence/runs/TASK-AIN-009/vectors.json` | `06ba40864a397da3c77f01df1761c1580980f8951eb374e33b9d53f175060748` | `e4a3d3f408576c5aa14362e62ec4dae031021595` |
| `evidence/runs/TASK-AIN-009/validate_contracts.py` | `c82e4ea9656b496f77b65cd8872118a0912ce79b9bb0d85b6bab3b7c4463f575` | `5995cd5fc4394fab15f7756a0e85a49605c03267` |
| `AgentDeviceOperationContractTests.swift` | `499594c5ca3f9f4ad05174936556535e1af7610017ad90583557b751750fc0dc` | `ed0f22af9341149cf4e812e94ecc5599937aeded` |

## Verification

### Independent stdlib validator

```text
/usr/bin/python3 \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-009/validate_contracts.py

TEST-AIN-OP-CONTRACT-001 PASS requests=3 results=4 operations=15 profiles=21 human_blockers=8 negatives=49 duplicates=2 core_steps=41 process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0
```

The validator uses only Python stdlib and checked-in bytes. It does not install a
package, open a network connection, spawn a child process, or access a device.

### Focused Swift contract matrix

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter AgentDeviceOperationContractTests

Executed 4 tests, with 0 failures (0 unexpected).
TEST-AIN-OP-CONTRACT-001 PASS requests=3 results=4 operations=15 profiles=21 human_blockers=8 negatives=49 process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0
```

The Swift tests read change-local bytes, reuse
`StrictJSONDuplicateValidator`, resolve Step metadata through
`WorkflowStepRegistry`, and compare state enums to `JobState.allCases`. They do
not import an execution, OpenHarmony, or workflow-dispatch module.

### Full regression and repository guards

```text
CI=true swift test --package-path Packages/ArkDeckKit
Executed 470 tests, with 1 test skipped and 0 failures (0 unexpected).

./scripts/check-sdd.sh
check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

python3 scripts/test_check_pr_paths.py
Ran 50 tests
OK

xcrun swift-format lint --strict \
  Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceOperationContractTests.swift
git diff --check
RESULT: PASS
```

The readiness baseline was 466 tests / 1 skipped / 0 failures. This task adds
four contract tests; the final result is 470 / 1 / 0.

## Acceptance, deviations, and residual risk

- `AIN-OP-CONTRACT-001`: **PASS** for closed schemas, operation-to-Core mapping,
  E0/E1/E2 references, human blocker registry, positive examples, and all 49
  stable-code negative vectors.
- `AC-WF-003-03` contract leg: **PASS** for rejecting executable/argv/shell/path,
  caller authority/facts/effect/outcome, unknown mapping, and duplicate members
  before any dispatch surface.
- Process/device/HDC/network dispatch attributable to this task: **0/0/0/0**.
- The first sandboxed focused Swift invocation stopped before compilation because
  the user Clang module cache was not writable. It was rerun through the approved
  controlled Swift test path and passed; this is an environment note, not a
  product failure.
- No scope or acceptance deviation remains. The registry freezes contract facts;
  it does not implement TASK-AIN-010 admission, any product executor/control
  plane, or real-device execution, and no hardware support is claimed.
- This implementation PR intentionally leaves TASK-AIN-009 `ready`. A later,
  independent maintainer-reviewed status PR must record `ready→done`; TASK-AIN-010
  readiness remains blocked until that merge.

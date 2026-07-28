# TASK-AIN-009R implementation run

Date: 2026-07-28

Classification: host-only contract/schema/vector validation. This run is not a
real-device, hardware, HDC, product-executor, control-plane, E0, E1, or E2
execution. No real capability, authorization, usage reservation, target
identity, device readback, or dispatch evidence was created.

## Authorization, base, and scope

- D1 readiness PR #746 was created by `github-actions[bot]`, approved by
  CODEOWNER `lvye` at exact head
  `1a45cb2d49a6118aff507e1689dd53bb09ba6290`, and merged as
  `ae07a98ee525ff65e578611e209e7ab9b7bdcd06`.
- Implementation branch: `agent/task-ain-009r-implementation`.
- Final protected-main implementation base:
  `38f0d4514ad16d9fe040fbd083d6e2f1a72e30f4`. The base advanced during
  implementation through #747 and #748. Their changes are confined to
  CHG-2026-044 evidence/status, `openspec/integrations/openharmony/profile.md`,
  and the SDD guard implementation/tests. Those paths have zero intersection
  with this task's pinned inputs and outputs; every pinned blob below remained
  exact after each fast-forward.
- Environment: macOS 26.6 (`25G72`), arm64, Xcode 26.6 (`17F113`), Apple
  Swift 6.3.3.
- Changed paths are limited to the five new change-local schemas, this run
  directory, and
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceCapabilityContractTests.swift`.
  Current specs/contracts, Sources, App, Package.swift, tasks.md, real
  capability/authorization registries, and device code are unchanged.

Every readiness input blob was rechecked after the readiness merge and remained
exact:

| Input group | pinned blobs |
| --- | --- |
| AIN-009 operation schema / registry schema / registry | `b2f41f6d14f18621561acbe93dbfccc3621405f4` / `f75e5d97130d15f3133cb19b73420438db0bfc18` / `f101619358b08ffb818ccc8eac72b06c7b2062fe` |
| r2 E2 usage | `b232db49d2d76fc2eb96fed6b7d0230455d99345` |
| Journal 2.0 / 2.1 | `6285acd4ca0350d427aa624afa91be3107769a64` / `ef71f22c45a7bc06bcde35b0606e94fb6bb79037` |
| Manifest 2.0 / 2.1 | `9ac334013968a5aba1a0bd77fe2acc982ba0e680` / `1fdb14da2ea8c0b45f88c3d5eef277b37e540976` |
| locked workflow-step schema / registry | `c510d96478f3192168478b1a1669b5fcd2a848f7` / `d9121ef78531560ab856dfa07468ce1ab4d42df6` |
| locked Journal / Manifest v1 | `d25b7a55e9970d301558430febd235ccc910d8b7` / `1100b951f8c7565e10f403d576acfe260e401155` |
| r4 proposal / design / workflow delta / device-auth delta / verification | `88093c32728eebd145ce0713b78af747a48331c1` / `bde7c336550bfd9074abf25c2510a1adc5710f1e` / `a3df2d253b6882538a8e649bc11876a0032270e3` / `41fafddb2e8a1233d3bd8ea6517f902fe40bee05` / `75a89dbcd4e91b717c374a52dbdd8d1357a4d16b` |
| WorkflowStep / JobStateMachine / StrictJSON | `d96423593978f84a0db7623a1b94863e5d12de26` / `c7350e2f74fcbb52a6e582c09c063c5dda0f13f6` / `d5df2a82ced6b8a06635c1e9f1887d70c693f005` |
| AIN-009 / usage / Journal / Manifest tests | `ed0f22af9341149cf4e812e94ecc5599937aeded` / `90e9790eca6bf8f397337b8f4cafa56fc7fb9ef6` / `274cc929d7eee30af2a8b05cae3b92672efe101b` / `335dc5fc62a7c30c6d0e209f1539b0c78d0caff8` |
| Package.swift | `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` |

## Contract result

1. Added a closed per-device E1 capability carrier at schema version 1.0.0.
   It pins hashed target/firmware/tool identity, binding floor, transport,
   operation/profile/configuration, five namespace kinds, impact/usage/time
   limits, root-forbidden fresh privilege facts, recovery policy, and the exact
   destructive adjacency deny set. Raw serial, connect key, path, argv,
   caller readback, usage and outcome fields are outside the carrier shape.
2. Frozen exactly 11 E1 operation/profile tuples. Configuration IDs and hashes
   are compared directly with the AIN-009 protected-main registry; the test does
   not maintain an independent hash table. `verifiedRollback` scopes preserve
   the readiness-approved strategy with an empty typed-compensation set rather
   than inventing unapproved HAP/SO runtime rollback Steps.
3. Added the inline E0/E1/E2 execution-authority union. Its three field sets
   match the AIN-009 result reference field sets exactly and map only
   `readyTask→readOnly`, `deviceCapability→deviceMutation`, and
   `standingAuthorization→destructive`.
4. Added the E1-only usage contract. A durable reservation consumes one
   contiguous ordinal without refund, permits one active job for the stable
   target, and carries exact forward and compensation leases. E0 has no usage
   reservation; E2 continues to use the unchanged r2
   `authorization-usage 1.0.0` ledger.
5. Added Journal/Manifest 2.2 contracts for exact authority/usage correlation
   across every authorized Agent external Step and compensation intent/outcome.
   Missing outcomes remain `outcomeUnknown`; ghost, duplicate, mixed-version,
   cross-kind and hidden outstanding intents reject.
6. Fixed protected-main provenance to `ArkDeck/ArkDeck`, protected `main`, the
   capability registry path, `github-actions[bot]`, exact-head `lvye` approval,
   `lvye` merge, pinned CODEOWNERS blob, current=head=merge carrier blob, and no
   offline cache. The fixtures describe these facts but never mint live
   authority.

### Persistence compatibility matrix

| Stored version | Read meaning | Write/migration result |
| --- | --- | --- |
| Journal/Manifest 1.x | locked historical semantics; no autonomous authority success | source bytes and declared version preserved |
| 2.0.0 | r2 standing-authorization correlation | existing semantics preserved; not rewritten to 2.2 |
| 2.1.0 | r2 standing authorization plus Rockchip descriptor identity | existing semantics and E2 usage ceiling preserved; not rewritten to 2.2 |
| 2.2.0 | E0/E1/E2 authority union plus external Step/compensation correlation | new Agent Job contract only; no down-write |

Historical schema byte hashes are pinned by the vectors and rechecked in both
Swift and the stdlib validator. Import or normalized read-only views do not mint
live authority, infer v1 `standardAgent` as E0, or infer 2.0/2.1 E2 as E1.

## Final file identities

The run record itself is excluded because it is self-referential.

| Path | SHA-256 | Git blob |
| --- | --- | --- |
| `contracts/agent-device-capability.schema.v1-draft.json` | `4c9e50d77f7340bbc7c69427f0c62c4f4b2773832c0529b4e6b031a9ced3bd0a` | `7199582380c1d308745fd7e5d18616e2db4fa837` |
| `contracts/agent-execution-authority.schema.v1-draft.json` | `b5fc66bc71ba7ee399f8edfc2560283802334082dede49917e848ed2d8009770` | `368e936cc4087c5999ba40da905fd40204b373c3` |
| `contracts/agent-authority-usage.schema.v1-draft.json` | `e62fb4e50397439b45d7eb00d976c00ebfa293c3830333ae35b3d8415beb498b` | `2dc14806c95c678cc9a51dffd31df7c1bf4633b5` |
| `contracts/journal-event.schema.v2.2-draft.json` | `00eec3b57dce513ceef930e133f29813c722fcf3d16ed928706d5fc2eebb1ee6` | `768140e670c936dd7ae5a4b01dbbd058fa54bdb3` |
| `contracts/manifest.schema.v2.2-draft.json` | `e5a9a0140fa1d9107f589670ec9f16640b8b190fed808eaacb4037930626d8c3` | `b90dc291e6f5159781928230ff33841690e84b01` |
| `AgentDeviceCapabilityContractTests.swift` | `20746bc5c35c4ae72910b0db6f0ccc32d7bed5a043a82724dc600e89b39ff030` | `b81e7419255131c67e3ef1f2d3c9cd385a47d292` |
| `evidence/runs/TASK-AIN-009R/vectors.json` | `d0c395c749503ae4d9106580fe4cf25f52f7add73d9fbaf052587dbb87c713b5` | `d596dafc17b48eee38c0acb031833123710b02a1` |
| `evidence/runs/TASK-AIN-009R/validate_contracts.py` | `66e34364207829ae0ce35749f59a067d784cca0abae26c8ad3d841d5e05d03ce` | `4635b8106dae1ed0e4c9c9cf28c0a5d795555759` |
| `evidence/runs/TASK-AIN-009R/duplicate-capability.json` | `5e976afd3229851f567a2b45403989294e11cac67c725d4d7649b93b33192e8e` | `b9acf5a351aeab761a1f80a7a0b14eed0b083c91` |
| `evidence/runs/TASK-AIN-009R/duplicate-capability-escaped.json` | `f505ba14fb73b487ed2d82b784f264dd2cd0786f99ecef708ef8afa09588e22e` | `b7f50af03d9d5195967aececadff2bebdb3be0a1` |

## Verification

### Independent stdlib validator

```text
python3 \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-009R/validate_contracts.py

TEST-AIN-CAP-CONTRACT-001 PASS e1_profiles=11 namespaces=5 authority_kinds=3 legacy_versions=3 process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0
```

The validator uses Python stdlib and checked-in bytes only. It validates schema
identity/closed objects/offline-or-pinned refs, registry equality, protected-main
provenance, validity and lease formulas, authority field sets, persistence
correlation, historical hashes, and two duplicate-member fixtures. It installs
no package and opens no network, child-process, HDC, or device surface.

### Focused Swift contract matrix

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter AgentDeviceCapabilityContractTests

Executed 6 tests, with 0 failures (0 unexpected).
TEST-AIN-CAP-CONTRACT-001 PASS e1_profiles=11 namespaces=5 authority_kinds=3 legacy_versions=3 process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0
```

The matrix includes 99 capability, 72 authority/usage/provenance, and 16
persistence single-fact negative cases, plus two duplicate-member cases,
positive coverage for all 11 E1 profiles/five namespaces/three authority kinds,
an `outcomeUnknown` crash vector, and three legacy versions.

### AIN-009 and historical persistence regression

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'AgentDeviceOperationContractTests|AuthorizationUsageLedgerContractTests|JournalRecoveryContractTests|SessionArtifactStorageContractTests'

Executed 99 tests, with 0 failures (0 unexpected).
```

The run retained the AIN-009 15-operation/21-profile/49-negative PASS, r2 E2
usage idempotency, v2/v2.1 Journal/Manifest correlation, descriptor-bound
Rockchip identity, crash recovery, and storage publication behavior.

### Full regression and repository guards

```text
CI=true swift test --package-path Packages/ArkDeckKit
Executed 476 tests, with 1 test skipped and 0 failures (0 unexpected).

./scripts/check-sdd.sh
check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

python3 scripts/test_check_pr_paths.py
Ran 50 tests
OK

xcrun swift-format lint --strict \
  Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceCapabilityContractTests.swift
git diff --check
RESULT: PASS
```

The readiness baseline was 470 tests / 1 skipped / 0 failures. This task adds
six contract tests; the final result is 476 / 1 / 0.

## Acceptance, deviations, and residual risk

- `AIN-CAP-CONTRACT-001`: **PASS** for the closed E1 carrier, protected-main
  provenance, 11 registry-bound profiles, field/limit/expiry/usage/concurrency
  negatives, authority union, Journal/Manifest 2.2 correlation, crash semantics,
  and historical version/hash compatibility.
- Contract legs for `AC-WF-003-02`, `AC-DEV-009-01`, `AC-JOB-002-01`, and
  `AC-JOB-006-01`: **PASS** without claiming product/runtime or hardware
  verification.
- Process/device/HDC/network dispatch attributable to this task: **0/0/0/0**.
- The optional local Python `jsonschema` package was unavailable. No required
  validator depends on it: the checked-in validator is stdlib-only and the
  Swift matrix independently checks the frozen structural and semantic
  invariants. This is an environment note, not a relaxed gate.
- After #747 advanced the base, direct invocation of its new
  `scripts/test_check_sdd.py` could not import the local optional `yaml` module.
  The updated production `./scripts/check-sdd.sh` itself passed on the final
  base, and this task does not install dependencies or modify that unrelated
  script. The PR SDD workflow remains the independent environment-backed
  recheck.
- No scope, privacy, authorization, or acceptance deviation remains. Fixtures
  use synthetic hashes/IDs/connect keys and are classified as contract evidence;
  they are not real target or capability records.
- This implementation PR intentionally leaves TASK-AIN-009R `ready`. A later,
  independent maintainer-reviewed status PR must record `ready→done`.
  TASK-AIN-010 remains blocked until that status merge and its own D1 readiness
  PR.

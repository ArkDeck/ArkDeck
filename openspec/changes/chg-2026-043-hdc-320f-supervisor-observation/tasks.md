# Tasks

## TASK-HSO-001 — Register exact 3.2.0f commandless supervisor identity family

- Status:ready
- Fresh readiness review r2(2026-07-28；host-only，零 HDC/设备；仅在维护者
  review/merge 本独立 D1 readiness PR 后生效):
  - **Audit base and approval:**protected main
    `d029cc4ebb9b91c647e904d943a65bef5ee95001`。CHG-2026-043 approval-only
    PR #738 exact head `a95ae3f229cf0f74bcc8681c92ce9239d1e1890e` 由维护者
    `lvye` APPROVED，并以
    `07daee30ba99636b5dc7a334bdefc3a07611acef` 合入；change current
    proposal blob `51c6304f7a080f01035580fc0593fe22460c1ba4` 为 `approved`。
    历史 blocked readiness #740 merge
    `b314d6dd586744480e7a66c2fa71c4d51199ab40` 识别的唯一 hard blocker 已由
    CHG-2026-044 清除；audit 时 open PR = 0。#749 后的 #750/#751 只修改
    CHG-2026-025 contracts/tests/tasks，与本 task、共享 integration/profile/fixture
    路径零交集。
  - **Reconciliation dependency satisfied:**CHG-2026-044 verification-only
    PR #749 exact head `83df97af1e95cd4e38b6ac7ea924043d321db668` 由 `lvye`
    APPROVED，并以 `672262ede8f2fe2c212264dafff1f7a387defdbc` 合入。
    其 proposal/verification/tasks/run protected-main blobs 分别为
    `2075f98770c9d86bb2731ecb6de5c94ec94627e2`、
    `7367a03badfb4d29251a8a12bf8d3620e4f9e9e5`、
    `f00f9e02cf5249d9345ffa6f5dd879d746c79532`、
    `3570f7f04d9b6ce0afadee26121748ece148e573`，状态为
    `verified`/`passed`/`done`。current OpenHarmony profile blob
    `4bfe204b1c13e53b93b35f840652206274614299` 的 header、正文与 current lock
    `INTEGRATION-PROFILES-0.6.0`/device registry 已一致指向
    `OPENHARMONY-TOOLS@0.5.0`；generic header↔lock guard 已在 SDD Guard 的
    production call path，旧冲突不再存在。
  - **Candidate version and absence pins:**在 audit base 上
    `OPENHARMONY-TOOLS@0.6.0`、`INTEGRATION-PROFILES-0.7.0` 与
    `OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0` 仅出现在本 change
    的候选声明或 CHG-2026-044 的“不占用”说明中，没有 current authority
    collision。canonical registry、`SupervisorObservation/1.0.0/` resource pack 与
    `HDCSupervisorObservationRegistryContractTests.swift` 三个 deliverable 路径均
    absent。因此本轮固定 proposal 的 `0.6.0` profile、`0.7.0` lock 与 `1.0.0`
    registry；任一 implementation-base collision 或 header/lock drift 都使 task
    重新 blocked，不得现场改号或覆盖。
  - **Provenance D1 acceptance (narrow):**#656 exact head
    `48de853d984e5781510c3d38ddc473d0d36e8373` / merge
    `af6d64d67af98c94e1f03581de6f52ecdb8a6bb2` 与 #658 exact head
    `76ef464bf18f536ea304076768a85391fc9d7b5e` / merge
    `6df25c25d0088238ce2700db07c4db6fbd92cc34` 均由 `lvye` 精确
    APPROVED。archived run blob
    `931d8c0009ab999b1f4e84741887132c07d4df05`（SHA-256
    `ef3372dadc19c4a0e84f6f15f3ac616751d0351cfc2372fa9cf943952275318e`）
    固定 exact macOS/hdc `3.2.0f`/executable SHA-256
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`/
    endpoint `127.0.0.1:8710`，并含跨 19:51–20:29 窗口四次一致的
    PID/start/executable/listener 观测。
  - **DEV-1 disposition:**该 accepted run 没有为每次 HDC command 留完整 pre/post
    bracket；本 D1 只接受它支撑 `platformProcessObservation` 的字段、exact tuple、
    listener normalization 与稳定性条件。新 family 固定 `exactArgv: []`、
    `invocationAllowed: false`，不消费 capture 中任何 command output；正式 observer
    仍须在每次使用时自行完成 bounded pre/post OS scan 与 candidate-byte 复核。
    该受理**不证明**被采集 server 的 pre-existing/external origin，不登记
    `checkserver`、health 或 client/server/daemon version，也不允许从 capture
    直接铸造 production receipt/generation。若实现需要以上任一事实，立即 blocked
    并另走维护者受控 capture/change；不得扩大本次 provenance。
  - **Shared consumer/resource closure:**`Package.swift` blob
    `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` 已复制整个
    `Fixtures/HDC/Probes`；legacy/device registry tests blobs
    `6f83b54e4d01148005a7348786c886cf4b7c7ade` /
    `ff7dab950caa390c0b982c0c765c39606190e80f` 分别只闭合自己的
    `1.0.0/` 与 `DeviceObservation/1.0.0/` 子树。两个既有 pack 的 git tree
    OID 分别为 `f906403bc878a27dbef79736203da98c32a020eb` 与
    `9ca93b91d18c554e4c137b7f3494550af072ebfc`；新增 sibling pack 无需修改
    `Package.swift` 或旧 tests，implementation 必须证明两个 tree 与 readonly/device
    canonical registry blobs `99e8cc3d9929f9502a3e978a53cd56ad285d2aad` /
    `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a` 全部不变。
  - **Closed registration and mutation contract:**新 registry/resource 只含一个
    `serverIdentityGeneration` entry：exact tool tuple/endpoint、
    `platformProcessObservation`、empty argv、invocation disallowed、existing exact
    one-listener owner 与 bounded pre/post equality。resource pack 只含 canonical
    byte-identical copy、manifest、redacted structured receipt/control；provenance 使用
    archive-stable change id + relative evidence path并钉 #656/#658 merge OID/DEV-1，
    不含 raw process/device identifier。contract 至少使下列 mutation 变红：
    tool version/hash/endpoint/profile/registry/resource hash、argv/invocation/effect、
    accepted merge OID/DEV-1 disclosure、3.2.0d cross-version substitution、old-pack
    byte drift；zero/multiple listener、wrong owner、PID/start/path/hash/listener drift、
    timeout/cancel/scan error、caller receipt/generation 与 fallback 均只能
    unsupported/unavailable/unknown，且所有 HDC/lifecycle/mutation counters 为 0。
  - **Baseline and PR boundary:**`scripts/check-sdd.sh` = 0 errors / 0 warnings /
    111 canonical AC；`scripts/test_check_sdd.py` = 56/56 PASS；
    `scripts/test_check_pr_paths.py` = 50/50 PASS；existing device/readonly registry
    focused suites = 15/15 + 7/7 PASS；`git diff --check` = PASS。本 readiness 只修改
    TASK-HSO-001 状态/本段/依赖/pins；不创建 registry/resource、不修改 profile/lock/
    macOS mapping/test/evidence，不开始 TASK-HSO-002。installed HDC、真实设备、
    network、server lifecycle/adoption、subserver/device/binding/destructive dispatch
    全部为 0；implementation/evidence 与后续 `ready→done` 继续使用独立 PR。
- Platform:macos
- Requirements:change-local integration authority compatible with `REQ-HDC-002`/
  `REQ-HDC-003`/`REQ-HDC-004`
- Acceptance:`HSO-REGISTRY-001`、`HSO-SEPARATION-001`、`HSO-NODISPATCH-001`
- Depends on:本 change proposal 与独立 approval-only PR 合入（已满足）；
  CHG-2026-044 profile/header/lock reconciliation `verified`（已满足）；
  CHG-2026-024 #656/#658 accepted provenance（已满足，且本 D1 仅按上列窄边界
  接受 commandless family 充分性）；独立 fresh readiness（本 PR，merge 后满足）
- Readiness input pins:

  ```yaml pins
  - commit: d029cc4ebb9b91c647e904d943a65bef5ee95001
  - commit: 07daee30ba99636b5dc7a334bdefc3a07611acef
  - commit: b314d6dd586744480e7a66c2fa71c4d51199ab40
  - commit: 672262ede8f2fe2c212264dafff1f7a387defdbc
  - commit: af6d64d67af98c94e1f03581de6f52ecdb8a6bb2
  - commit: 6df25c25d0088238ce2700db07c4db6fbd92cc34
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/proposal.md
    blob: 51c6304f7a080f01035580fc0593fe22460c1ba4
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/verification.md
    blob: 831fc3b3a895fa6c2cc6966a7278ac58cb5828b4
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/design.md
    blob: d8f25081442ea876e1d598e39cf58a0c64e72f4d
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/acceptance-cases.yaml
    blob: 6b7becef9571c34a89e764240138879369e6653b
  - path: openspec/changes/chg-2026-044-openharmony-profile-version-reconciliation/proposal.md
    blob: 2075f98770c9d86bb2731ecb6de5c94ec94627e2
  - path: openspec/changes/chg-2026-044-openharmony-profile-version-reconciliation/verification.md
    blob: 7367a03badfb4d29251a8a12bf8d3620e4f9e9e5
  - path: openspec/changes/chg-2026-044-openharmony-profile-version-reconciliation/tasks.md
    blob: f00f9e02cf5249d9345ffa6f5dd879d746c79532
  - path: openspec/changes/chg-2026-044-openharmony-profile-version-reconciliation/evidence/runs/TASK-OPVR-001/run.md
    blob: 3570f7f04d9b6ce0afadee26121748ece148e573
  - path: openspec/changes/archive/2026-07-28-chg-2026-024-hdc-device-snapshot-registration/evidence/runs/TASK-I24-001/run.md
    blob: 931d8c0009ab999b1f4e84741887132c07d4df05
  - path: openspec/integrations/openharmony/profile.md
    blob: 4bfe204b1c13e53b93b35f840652206274614299
    sha256: 477373827f026376e91d6629fa2eb95f87d5b9b99e61dafaf815e86689fc4824
  - path: openspec/integrations/INTEGRATION-PROFILES.lock.yaml
    blob: 9297820f25b9276859c60ba6bd89ab399066dcd0
    sha256: 802d87819b8ce39f197b7b59bfffde24d074cf7db33c3e80c89f9f8b3a5f8b46
  - path: openspec/integrations/openharmony/readonly-probes.yaml
    blob: 99e8cc3d9929f9502a3e978a53cd56ad285d2aad
  - path: openspec/integrations/openharmony/device-observation-probes.yaml
    blob: 399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a
  - path: openspec/platforms/macos/profile.md
    blob: e4bcf6da97f94c55efaf0a13806881038efa12e0
  - path: Packages/ArkDeckKit/Package.swift
    blob: 292135a2c80c63ddf7182f58e2f81ff7c7d6104d
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationRegistryContractTests.swift
    blob: ff7dab950caa390c0b982c0c765c39606190e80f
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCProbeRegistryContractTests.swift
    blob: 6f83b54e4d01148005a7348786c886cf4b7c7ade
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/resources.json
    blob: 5796449dee4a7166746d9b0d7245d26bd2b21aae
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/resources.json
    blob: c231cdccc99be3f4154cf4e9a11b15fbdb251b94
  - path: scripts/check_sdd.py
    blob: aa7dc6e34d187cb6458689d72ac28564b58fb29b
  - path: scripts/test_check_sdd.py
    blob: 7e6c47044b31065d2752ce78d9185b6a3869732b
  - artifact: absent:openspec/integrations/openharmony/supervisor-observation-probes.yaml
    commit: d029cc4ebb9b91c647e904d943a65bef5ee95001
  - artifact: absent:Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/SupervisorObservation/1.0.0
    commit: d029cc4ebb9b91c647e904d943a65bef5ee95001
  - artifact: absent:Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorObservationRegistryContractTests.swift
    commit: d029cc4ebb9b91c647e904d943a65bef5ee95001
  ```
- Applicable failure patterns:`AF-001`（共享 profile/lock consumer 与 allowed paths）、
  `AF-003`（accepted capture producer 与 caller boundary）、`AF-005`（evidence
  freshness/class/DEV-1）、`AF-006`（完整 OID、status/version/pin 漂移）、
  `AF-008`（hash/path/endpoint/identity adversarial matrix）、`AF-010`（绿测试未覆盖
  新 registry/resource/provenance 语义，须有独立 expected mutation-red）、
  `AF-013`（不得把 3.2.0d registry 形态直接照搬到 3.2.0f）、
  `AF-016`（全部 pin 从 protected main 一手重取）、
  `AF-018`（open PR/共享状态复核）
- Production reachability:not applicable for this registration task；只登记 integration
  authority，不接 production composition root、不执行 effect
- Trusted fact sources:exact 3.2.0f tool/server facts仅来自维护者控制并已 merge 的
  CHG-2026-024 #656/#658 evidence；registry/profile/lock facts来自受保护 main；
  合成 controls 只能证伪，不能建立 support。调用方不能构造或修改 accepted capture
- Allowed paths after readiness:
  - `openspec/integrations/openharmony/supervisor-observation-probes.yaml`
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/platforms/macos/profile.md`（仅新增本 family mapping/version adoption；
    不改变 Core/platform conformance）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/SupervisorObservation/1.0.0/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorObservationRegistryContractTests.swift`
  - `openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/evidence/**`
  - 本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:
  - `Packages/ArkDeckKit/Sources/**`
  - `ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**`
  - `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`
  - `openspec/integrations/openharmony/readonly-probes.yaml`
  - `openspec/integrations/openharmony/device-observation-probes.yaml`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/**`
  - CHG-2026-006/015/022/024 tasks/evidence 或其他 change evidence
- Risk:high（错误登记会把 OS 进程事实升级为 ownership authority）
- Hardware required:no；只可复用已受理 provenance。若 readiness 判不足，保持
  `blocked` 并另走维护者受控 capture plan
- Decision-Grade:D1（首次 readiness 的 authority/scope/provenance 接受）

### Deliverables

- 独立、版本化、hash-closed 的 exact 3.2.0f supervisor-observation registry/resource。
- OpenHarmony profile/Integration lock/macOS mapping 的一致 version/hash closure。
- contract tests 覆盖 exact tuple、零 argv、不可调用、稳定 receipt、provenance、
  negative controls 与两个既有 registry/resource byte identity。

### Verification

- `HSO-REGISTRY-001` → registry/resource/profile/lock/macOS closure + provenance review →
  exact IDs/versions/hashes/entry/evidence reference 全部一致。
- `HSO-SEPARATION-001` → Git blob/hash identity + cross-version mutation matrix → 两个既有
  registry/resource 不变，3.2.0d/3.2.0f authority 不可互换。
- `HSO-NODISPATCH-001` → static argv/effect audit + instrumented counters → registration、
  tests、Agent/CI installed HDC/设备/lifecycle/mutation dispatch 全 0。

### Notes / handoff

- proposal/approval 合入不使本任务 ready；readiness 必须单独 review/merge。
- 完成后在 `evidence/runs/TASK-HSO-001/` 追加 run 记录；implementation/evidence 与
  `ready→done` 使用独立 PR。

## TASK-HSO-002 — Adopt the same exact 3.2.0f candidate in production supervisor observation

- Status:blocked
- Platform:macos
- Requirements:compatible implementation of `REQ-HDC-002`、`REQ-HDC-003`、
  `REQ-HDC-004`、`REQ-UX-002`
- Acceptance:`HSO-SINGLE-CANDIDATE-001`、`HSO-NODISPATCH-001`
- Depends on:TASK-HSO-001 `done`；独立 readiness
- Readiness input pins:not yet established; readiness must pin TASK-HSO-001 merged registry/
  resource/profile/lock closure, production composition root and every allowed source/test blob
- Applicable failure patterns:readiness 时至少回答 production root 不可达、test-only
  wiring、caller-forged authority、second-candidate fallback、failure-state retention 与
  forbidden effect
- Production reachability:
  `HDCApplicationDiagnosticsFacade.attachSessionIfConfigured`
  → one selected `HDCCandidate` / one endpoint
  → internally constructed exact 3.2.0f commandless identity observer
  → observation-minted generation
  → `HDCServerSupervisor.observeRegisteredServerIdentity` four-evidence classifier
  → existing diagnostics presentation；同一 candidate 另进入既有
  `HDCDeviceObservationApplicationSession.makeProduction`
- Trusted fact sources:selected candidate来自 production discovery 并由
  `HDCCandidateIdentityVerifier` 对磁盘 bytes 复核；process/start/path/listener facts
  来自不可注入的 macOS observer；registry/profile/lock来自 TASK-HSO-001 protected-main
  closure；caller 不能注入 receipt/generation/process/socket list/runner
- Allowed paths after readiness:
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorObservabilityContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift`
  - `openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/evidence/**`
  - 本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:
  - `ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**`
  - `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`
  - `openspec/integrations/**`、`openspec/platforms/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift`
  - CHG-2026-006/015/022/024 tasks/evidence 或其他 change evidence
- Risk:high（错误 composition 可制造 external ownership 或把 device/server 事实跨候选拼接）
- Hardware required:no；仅 fake/system-observer contract 与 host static tests，禁止 installed
  HDC/真实设备
- Decision-Grade:D1（首次 production authority reachability readiness）

### Deliverables

- production facade 对 exact 3.2.0f 采用新 commandless supervisor identity route，同时把
  完全相同的 candidate/endpoint 交给既有 device observation session。
- internally constructed registry/observer，无 receipt/generation/process/socket/runner
  production injection surface。
- exact 3.2.0d 原路径保持行为与 tests 不变；3.2.0f health/version 保持 typed unknown。
- negative/mutation tests 覆盖 mismatch、zero/multiple listener、pre/post drift、candidate
  replacement、fallback、stale claim 与所有 forbidden dispatch。

### Verification

- `HSO-SINGLE-CANDIDATE-001` → production-root contract + candidate/endpoint identity spies +
  four-evidence matrix → 同一 3.2.0f candidate 建立 generation/conditional external ownership
  与 device session；无第二 discovery、候选或 session。
- `HSO-NODISPATCH-001` → command runner/lifecycle/subserver/device-mutation counters +
  failure injection → identity bootstrap 的 HDC child 与全部 mutation 恒为 0；显式 device
  refresh 至多保留一个既有 registered read-only child。
- regression → ArkDeckKit 全量 tests、SDD check/guard 与既有 HDC signed UI suite →
  3.2.0d、unknown presentation、device event 与 lifecycle safety 不回退。

### Notes / handoff

- TASK-HSO-001 未经独立 `done` PR 合入前，不得为本任务创建 readiness 或实现 PR。
- 完成后在 `evidence/runs/TASK-HSO-002/` 追加 run 记录；implementation/evidence 与
  `ready→done` 使用独立 PR。

# Tasks

## TASK-HSO-001 — Register exact 3.2.0f commandless supervisor identity family

- Status:done（2026-07-28 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效；本翻转不构成 change verified、TASK-HSO-002
  readiness/implementation、production adoption、external ownership、HDC/device/
  hardware support 或任何 dispatch authority）
- Done:2026-07-28；实现经 #755 exact head
  `38518eea9f487f76be2d065b882924376adbfdc3` 由维护者 `lvye` APPROVED 并合入
  protected main（merge commit
  `4fc0cec76638cd299e6ccbaff7c5124a048a2106`）。reviewed head 到 merge 在
  TASK-HSO-001 的 11 个 implementation/evidence 路径零差异；fresh main 上专用
  `HDCSupervisorObservationRegistryContractTests` = 9 tests / 0 failures，
  `check-sdd` = 0 errors / 0 warnings / 111 acceptance IDs，路径守卫 = 50/50，
  实现 PR 的 Agent PR、SDD Guard、allowed-paths 与 Swift CI 全部 SUCCESS。
  evidence = `evidence/runs/TASK-HSO-001/run.md`（blob
  `db56cd004dd78295ab7129ee01f4f658cba71c9c`）；本次状态复验仍为 host-only，
  installed HDC、真实 process/socket/device、network、lifecycle/adoption、
  subserver、binding/device mutation 与 destructive dispatch 全部为 0。
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

- Status:ready（2026-07-29 fresh D1 readiness；仅在维护者 review/merge 本独立
  readiness PR 后生效；不构成 implementation、evidence、`ready→done`、
  change verified、external ownership、health/version support、HDC/device/hardware
  support 或任何 dispatch authority）
- Fresh readiness review r1(2026-07-29；host-only，零 HDC/设备；仅在维护者
  review/merge 本独立 D1 readiness PR 后生效):
  - **Audit base, approval and dependency gate:**protected main
    `248eb1e5348fb2bcc90c69af5d7b17c6954a99ca`，audit 开始时 open PR = 0。
    CHG-2026-043 approval-only PR #738 exact head
    `a95ae3f229cf0f74bcc8681c92ce9239d1e1890e` 由维护者 `lvye` APPROVED，
    并以 `07daee30ba99636b5dc7a334bdefc3a07611acef` 合入。TASK-HSO-001
    implementation PR #755 exact head
    `38518eea9f487f76be2d065b882924376adbfdc3` 由 `lvye` APPROVED，并以
    `4fc0cec76638cd299e6ccbaff7c5124a048a2106` 合入；其独立 `ready→done`
    PR #756 exact head `30f816482a848f0943e58df5ff8bf5551257180e` 同样由 `lvye`
    APPROVED，并以本 audit base 合入。proposal current blob
    `51c6304f7a080f01035580fc0593fe22460c1ba4` 为 `approved`，TASK-HSO-001
    current status 为 `done`；前置门已闭合。
  - **Registered authority closure:**protected main 上 exact
    `OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0` canonical registry
    blob `b202b9d34680a0e7bbdba1d02637279ca4819d3f` / SHA-256
    `f1691f748da10f1bb7753167d71ff3b764a347676f97d5ec70a1e97ac35c9763`，
    resource tree `87421493b8d353a402e0f777ef684e55db1f2981`，profile/lock/macOS
    blobs `2ae13490e075f327bb7448ccacf908be5ba7e3aa` /
    `836d4ccc8c34c5826b6c53dcf9004e678a506d25` /
    `b7471666b0bbfbfade3fbd510ad831e45b3cf9b8`。它们闭合 exact macOS
    `3.2.0f` / executable SHA-256
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` /
    endpoint `127.0.0.1:8710` / empty argv / invocation disallowed；
    TASK-HSO-001 run blob
    `db56cd004dd78295ab7129ee01f4f658cba71c9c`（SHA-256
    `ac9554b997b94a32f5176a1a726f38a01b3523699937fe047fe881a73c2effb8`）
    已复查。3.2.0d readonly 与 3.2.0f device canonical blobs
    `99e8cc3d9929f9502a3e978a53cd56ad285d2aad` /
    `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a` 仍是独立 authority，不得替代、
    fallback 或跨 family 携带 receipt/generation/health/version。
  - **Production root and single-selection proof:**current
    `HDCApplicationDiagnosticsFacade.attachSessionIfConfigured` 在一次调用内只做一次
    `HDCExternalFirstDiscovery.discover`，把同一 local `candidate` 和一次选择的
    `endpoint` 先交给 supervisor composition，再交给
    `HDCDeviceObservationApplicationSession.makeProduction`。现状 supervisor
    只调用 exact 3.2.0d `observeRegisteredExistingServer`，所以 3.2.0f 会
    unsupported；这正是本任务需在已声明三个 production source 路径内闭合的 gap，
    不是 readiness 已实现的能力。实现必须以 candidate/endpoint identity spies
    证明两个 consumer 接收同一实例/值，且 replacement、fallback、第二次 discovery、
    第二 candidate 或第二 session 的 mutation 全部变红。
  - **Construction and consumer boundary:**新增
    `HDCSupervisorObservationProbeRegistry.swift` 在 audit base absent；SwiftPM target
    已按目录自动包含 source，因此现有 `Package.swift` blob
    `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` 无需修改。production factory
    只能接收 supervisor、已选择 candidate 与 endpoint，并在模块内构造 exact registry
    与 system observer；不得暴露 receipt、generation、PID/start/path/hash、
    process/socket list、command runner 或 registry injection。若 contract tests
    需要 fake observer，只能使用 module-internal test seam，Workflows/App production
    root 必须不可达；static source scan 与 mutation test 同时固定该边界。
  - **One commandless observer and exact normalization:**3.2.0f supervisor identity
    与既有 3.2.0f device production route 必须共享一个不可注入的 macOS
    identity-observer 实现，或以行为等价的独立 mutation matrix 证明完全相同的
    pre/post candidate-byte、PID/start/path/hash/endpoint/listener checks；本 task
    选择前者并在允许的 `HDCProduction.swift` 与新增 source 内重构。observer 必须
    消费 registered `listenerNormalization`：exact IPv4 loopback，以及仅当既有
    macOS socket rule 证明等价时接受 IPv4-mapped IPv6 loopback；port-only、
    wrong owner、unregistered address 与多义结果均 fail closed。若需要扩大
    registry/profile/macOS mapping 或修改 forbidden readonly registry，本任务立即
    重新 blocked，不得现场改 authority。
  - **Four-evidence and stale-claim gate:**current
    `HDCServerSupervisor.observeRegisteredServerIdentity` 已把 external classification
    固定为四证据 conjunction：pre-existing observation receipt、零 auto lifecycle
    dispatch、generation 非 ArkDeck-launched、无 active/unreconciled managed
    provenance。production adoption 必须调用该 classifier，不得复制、缩短或绕过；
    四项任缺一项只可 unknown。每个 unsupported/unavailable/unknown/timedOut/
    cancelled/scan-error/mismatch/drift 路径必须调用既有
    `recordUnverifiedServerProbeFailure` 等价失败入口，撤销 prior generation/external
    claim；“失败但保留旧 external” mutation 必须变红。health、client/server/daemon
    version 始终保持 typed unknown。
  - **Closed negative/effect matrix:**tests 必须独立覆盖 wrong version/hash/path/bytes/
    endpoint，zero/multiple/wrong-owner listener，pre/post PID/start/path/hash/endpoint/
    listener drift，timeout、cancellation、scan error，candidate replacement/fallback，
    caller-forged/persisted receipt/generation，四证据逐项缺失与 stale-claim retention。
    identity bootstrap 的 command/HDC child/server start-stop-restart/adoption/subserver/
    device/binding/destructive counters 全部为 0；只有既有显式 device refresh 可产生
    至多一个 registered read-only child，且不能授予 supervisor ownership。
    exact 3.2.0d route、device event/presentation 与 lifecycle safety 必须保持回归绿。
  - **Baseline and PR boundary:**macOS 26.6 (25G72)、Xcode 26.6 (17F113)、
    Swift 6.3.3；ArkDeckKit 全量 = 485 tests / 1 expected manual sleep-wake skip /
    0 failures / 0 unexpected，四个相关 suites 合计 107/107 PASS（device
    presentation 18、supervisor 55、supervisor observability 25、registry 9）。
    `scripts/check-sdd.sh` = 0 errors / 0 warnings / 111 acceptance IDs；
    `scripts/test_check_sdd.py` = 56/56 PASS；
    `scripts/test_check_pr_paths.py` = 50/50 PASS；`git diff --check` = PASS。
    本 readiness 只修改 TASK-HSO-002 状态/本段/依赖/pins，不创建 source/test/evidence，
    不接 production route；installed HDC、真实 process/socket/device、network、
    lifecycle/adoption、subserver、binding/device mutation 与 destructive dispatch
    全部为 0。implementation/evidence 与后续 `ready→done` 继续使用独立 PR。
- Platform:macos
- Requirements:compatible implementation of `REQ-HDC-002`、`REQ-HDC-003`、
  `REQ-HDC-004`、`REQ-UX-002`
- Acceptance:`HSO-SINGLE-CANDIDATE-001`、`HSO-NODISPATCH-001`
- Depends on:TASK-HSO-001 implementation #755 与独立 `ready→done` #756 合入
  （已满足）；独立 fresh readiness（本 PR，merge 后满足）
- Readiness input pins:

  ```yaml pins
  - commit: 248eb1e5348fb2bcc90c69af5d7b17c6954a99ca
  - commit: 07daee30ba99636b5dc7a334bdefc3a07611acef
  - commit: 4fc0cec76638cd299e6ccbaff7c5124a048a2106
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/tasks.md
    blob: 50cb041e687f1b5f71e61d507ab1d6a6c10a4386
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/proposal.md
    blob: 51c6304f7a080f01035580fc0593fe22460c1ba4
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/design.md
    blob: d8f25081442ea876e1d598e39cf58a0c64e72f4d
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/verification.md
    blob: 831fc3b3a895fa6c2cc6966a7278ac58cb5828b4
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/acceptance-cases.yaml
    blob: 6b7becef9571c34a89e764240138879369e6653b
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/evidence/runs/TASK-HSO-001/run.md
    blob: db56cd004dd78295ab7129ee01f4f658cba71c9c
    sha256: ac9554b997b94a32f5176a1a726f38a01b3523699937fe047fe881a73c2effb8
  - path: openspec/integrations/openharmony/supervisor-observation-probes.yaml
    blob: b202b9d34680a0e7bbdba1d02637279ca4819d3f
    sha256: f1691f748da10f1bb7753167d71ff3b764a347676f97d5ec70a1e97ac35c9763
  - path: openspec/integrations/openharmony/profile.md
    blob: 2ae13490e075f327bb7448ccacf908be5ba7e3aa
    sha256: 8f70c070c9657f224ed019cddcc207d97f63424e9a032fef0473f58edededde0
  - path: openspec/integrations/INTEGRATION-PROFILES.lock.yaml
    blob: 836d4ccc8c34c5826b6c53dcf9004e678a506d25
    sha256: 1ec25dc1afe9b57ae237afda9e454a53e9b6e3ee2231892af75969a2baa4644c
  - path: openspec/platforms/macos/profile.md
    blob: b7471666b0bbfbfade3fbd510ad831e45b3cf9b8
    sha256: b91154c03d96cdf138c3e3be75bbb92f3690a4bec68dfe0712d87c575afb4b5e
  - path: openspec/integrations/openharmony/readonly-probes.yaml
    blob: 99e8cc3d9929f9502a3e978a53cd56ad285d2aad
    sha256: b0ac1564109b8138c7a73cbb83684400967633f6e6b04701175a22d314d88da6
  - path: openspec/integrations/openharmony/device-observation-probes.yaml
    blob: 399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a
    sha256: 79814e45901ab7e4d9f9a271645cad62b0053a50534cba884cdff0c2e50b9d49
  - artifact: tree:Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/SupervisorObservation/1.0.0@87421493b8d353a402e0f777ef684e55db1f2981
    commit: 248eb1e5348fb2bcc90c69af5d7b17c6954a99ca
  - artifact: tree:Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0@f906403bc878a27dbef79736203da98c32a020eb
    commit: 248eb1e5348fb2bcc90c69af5d7b17c6954a99ca
  - artifact: tree:Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0@9ca93b91d18c554e4c137b7f3494550af072ebfc
    commit: 248eb1e5348fb2bcc90c69af5d7b17c6954a99ca
  - path: Packages/ArkDeckKit/Package.swift
    blob: 292135a2c80c63ddf7182f58e2f81ff7c7d6104d
  - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift
    blob: 8055fc65dde7b95c1ab87fa52bb54ed002b024ad
  - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift
    blob: 6c9ed05896d92624e03b39d9f1ab88422e56f6e6
  - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift
    blob: 2dfe8e9d8290d6e939b4e3531ac81bb332a7cc29
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift
    blob: 4f32e1f6e4c9142f332f35d0001e67f379304dba
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorObservabilityContractTests.swift
    blob: 3877c216fb985109f7bccefc1532b6a011143ac5
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorContractTests.swift
    blob: c09f6255d50b9c7b008f82f7f696c47f352fcb9b
  - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift
    blob: 86f8e4cdbc3fa307a4986eebbdd3d1b7c43a6525
  - artifact: absent:Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift
    commit: 248eb1e5348fb2bcc90c69af5d7b17c6954a99ca
  ```
- Applicable failure patterns:`AF-001`（production root、共享 observer consumer 与 allowed
  paths 全闭合）、`AF-003`（system observer producer 与 caller anti-forgery boundary）、
  `AF-005`（TASK-HSO-001 evidence freshness/class 与 host-only truthfulness）、
  `AF-006`（完整 OID、status/version/pin 漂移）、`AF-008`（candidate/hash/path/
  endpoint/process/listener/four-evidence/stale-claim adversarial matrix）、
  `AF-010`（绿测试须由独立 expected mutation-red 证明 production wiring 语义）、
  `AF-013`（不得照搬 3.2.0d command registry 或现有 test-only observer）、
  `AF-016`（全部 pin、PR review/head/merge 从 protected main/GitHub 一手重取）、
  `AF-018`（open PR/共享 production source 状态复核）
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

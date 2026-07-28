# Tasks

## TASK-HSO-001 — Register exact 3.2.0f commandless supervisor identity family

- Status:blocked
- Fresh readiness review(2026-07-28;host-only,零 HDC/设备；仅在维护者
  review/merge 本独立 readiness PR 后成为 current):
  - **Audit base:**protected main
    `07daee30ba99636b5dc7a334bdefc3a07611acef`（approval-only PR #738 merge）。
    #738 exact head `a95ae3f229cf0f74bcc8681c92ce9239d1e1890e` 由维护者
    `lvye` APPROVED；proposal #737 与 approval tree 均已逐路径复核 merge 后一致。
  - **Approval/dependency gate:**CHG-2026-043 已为 `approved`；CHG-2026-024 已
    verified/archived，accepted capture merges #656
    `af6d64d67af98c94e1f03581de6f52ecdb8a6bb2` 与 #658
    `6df25c25d0088238ce2700db07c4db6fbd92cc34` 均在 git 历史。其 current
    run blob = `931d8c0009ab999b1f4e84741887132c07d4df05`（SHA-256
    `ef3372dadc19c4a0e84f6f15f3ac616751d0351cfc2372fa9cf943952275318e`）。
    这些事实满足 change approval 与 evidence 可寻址性，**不自动接受 provenance
    对新 family 的充分性**。
  - **Hard blocker — authoritative profile version conflict:**current
    `openspec/integrations/openharmony/profile.md` blob
    `8889864cb023e43a745862e99a3f307d168e410c`（SHA-256
    `6bcf7e8ed5ee74215bc72963a5b0a7e862010e48bad03438445ae442c235cfd2`）
    的 header 仍是 `Version：0.4.0`；同一文件 device-observation 节却声明
    `OPENHARMONY-TOOLS@0.5.0`。current lock blob
    `9297820f25b9276859c60ba6bd89ab399066dcd0`（SHA-256
    `802d87819b8ce39f197b7b59bfffde24d074cf7db33c3e80c89f9f8b3a5f8b46`）
    又把 `OPENHARMONY-TOOLS` 登记为 `0.5.0`；device registry blob
    `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a` 也绑定
    `OPENHARMONY-TOOLS@0.5.0`。profile header / profile 正文 / lock / registry
    不一致，直接违反本任务 `HSO-REGISTRY-001` 的 version closure 前置。
  - **Lineage proof:**`git blame` 显示 profile header 的 `0.4.0` 最后来自
    `171a269d`；CHG-2026-024 implementation `ffca996f41be37d27137e7245c8fba3645fb0fb4`
    只新增 device-observation 节并把 lock bump 到 0.6.0 / profile entry 0.5.0，
    没有修改 header。故这不是两个历史 profile 并存的有意表达，而是 living
    integration authority 的漏同步。现有
    `HDCDeviceObservationRegistryContractTests` 15/15 与
    `HDCProbeRegistryContractTests` 7/7 PASS、`check-sdd` 0/0/111，也只说明当前
    guard 未覆盖 header↔lock 一致性，不能把绿灯升级为冲突已消失。
  - **Why candidate versions cannot be pinned:**proposal 的
    `OPENHARMONY-TOOLS@0.6.0` / `INTEGRATION-PROFILES-0.7.0` 在 change 外未占用，
    三个新 deliverable 路径在 audit base 均 absent；但选择 profile 0.6.0 会隐式
    采信 lock 的 0.5.0 而覆盖 header 的 0.4.0，选择 0.5.0 又与已登记 device
    profile 相撞。Agent 不得在权威冲突中自行选择更方便的解释，因此不产生可供
    implementation 使用的 candidate-version pin。
  - **Other preflight results:**open PR = 0；Package.swift blob
    `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` 已 `.copy("Fixtures/HDC/Probes")`；
    legacy probe test blob `6f83b54e4d01148005a7348786c886cf4b7c7ade`
    已把枚举限制在自身 `1.0.0/` 子树。故新增 sibling pack 无需修改
    `Package.swift` 或 legacy test，当前 allowed paths 在该面完整。readonly
    registry blob `99e8cc3d9929f9502a3e978a53cd56ad285d2aad` 与 device registry
    上述 blob 已重取，未发现 open-PR overlap；这些无阻塞结论不能覆盖版本冲突。
  - **Provenance gate:not adjudicated。**#656/#658 的 exact 3.2.0f
    tool/endpoint 与四次稳定 process/start/executable/listener observation 仍 current，
    `DEV-1`（非逐 command 完整 bracket）仍须在冲突修复后的 fresh readiness
    独立裁决。由于本 task 是 commandless family，不能把“无 HDC argv”反过来当作
    evidence 自动充分。
  - **Unblock gate:**先用独立 approved integration change 协调 living
    `OPENHARMONY-TOOLS` profile header、lock 与 device registry 的 current version
    lineage，并增加能在 header/lock 漂移时变红的 contract/guard；archived
    CHG-2026-024 evidence 不改写。该 remediation `done` 后，本任务仍须另起 fresh
    D1 readiness，重钉当时 main、候选版本、全部输入与 provenance 充分性。
  - **PR boundary:**本 readiness 仅修改 TASK-HSO-001 的本段/依赖描述，状态保持
    `blocked`；不夹带 profile/lock/test 修复，不创建新 registry/resource，不修改
    proposal/design/verification/acceptance，不开始 TASK-HSO-002，也不创建后续
    remediation proposal。installed HDC、真实设备、server lifecycle/adoption、
    subserver/device/binding/destructive dispatch 全部为 0。
- Platform:macos
- Requirements:change-local integration authority compatible with `REQ-HDC-002`/
  `REQ-HDC-003`/`REQ-HDC-004`
- Acceptance:`HSO-REGISTRY-001`、`HSO-SEPARATION-001`、`HSO-NODISPATCH-001`
- Depends on:本 change proposal 与独立 approval-only PR 合入（已满足）；
  CHG-2026-024 verified evidence（已满足可寻址性，充分性待 fresh readiness）；
  living OpenHarmony profile/header/lock version reconciliation change `done`（未满足）；
  独立 fresh readiness（本轮 blocked）
- Readiness input pins:本轮只固定用于复查 blocker 的 audit inputs，不授权
  implementation：

  ```yaml pins
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/proposal.md
    blob: 51c6304f7a080f01035580fc0593fe22460c1ba4
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/verification.md
    blob: 831fc3b3a895fa6c2cc6966a7278ac58cb5828b4
  - path: openspec/changes/archive/2026-07-28-chg-2026-024-hdc-device-snapshot-registration/evidence/runs/TASK-I24-001/run.md
    blob: 931d8c0009ab999b1f4e84741887132c07d4df05
  - path: openspec/integrations/openharmony/profile.md
    blob: 8889864cb023e43a745862e99a3f307d168e410c
  - path: openspec/integrations/INTEGRATION-PROFILES.lock.yaml
    blob: 9297820f25b9276859c60ba6bd89ab399066dcd0
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
  ```
- Applicable failure patterns:`AF-001`（共享 profile/lock consumer 与 allowed paths）、
  `AF-003`（accepted capture producer 与 caller boundary）、`AF-005`（evidence
  freshness/class/DEV-1）、`AF-006`（完整 OID、status/version/pin 漂移）、
  `AF-008`（hash/path/endpoint/identity adversarial matrix）、`AF-010`（绿测试未覆盖
  header↔lock 漂移，须有 mutation-red）、`AF-013`（不得把 3.2.0d registry
  形态直接照搬到 3.2.0f）、`AF-016`（全部 pin 从 protected main 一手重取）、
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

# Tasks

## TASK-HSO-001 — Register exact 3.2.0f commandless supervisor identity family

- Status:blocked
- Platform:macos
- Requirements:change-local integration authority compatible with `REQ-HDC-002`/
  `REQ-HDC-003`/`REQ-HDC-004`
- Acceptance:`HSO-REGISTRY-001`、`HSO-SEPARATION-001`、`HSO-NODISPATCH-001`
- Depends on:本 change proposal 与独立 approval-only PR 合入；CHG-2026-024
  verified evidence；独立 readiness
- Readiness input pins:not yet established; readiness must pin exact main commit, CHG-2026-024
  capture/evidence blobs and merge OIDs, current profile/lock/registry/resource blobs, target
  source/test blobs, candidate versions and no-overlap result
- Applicable failure patterns:readiness 时依据
  `openspec/planning/agent-failure-patterns.md` 重审；至少回答伪造 authority、
  跨版本事实拼接、假 evidence 升级与 forbidden-path 漂移
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

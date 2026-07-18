# Tasks — CHG-2026-005 HDC parser golden registration

> V2 治理:本 change 尚为 `proposed`；维护者批准并合入前，以下任务
> 不得执行，也不得生成可用于 `AC-HDC-005-01` 的 parserGolden 证据。

## TASK-I5-001 — 提升并登记完整 HDC semantic golden fixture pack

- Status:blocked(change 已 approved;success/healthy/checkserver/version 的 raw input 已由
  维护者受控采集并随本实现 PR 提交——维护者 review/merge 本实现 PR 即构成对 provenance 与
  登记的正式认可;done 翻转由独立状态 PR 执行)
- Completion evidence:`evidence/runs/TASK-I5-001/run.md`(五 fixture 三方一致登记、
  Bundle.module 资源测试 3/0、全量 172/0、guard 0 error、零 dispatch;含真实 3.2.0d 无
  `[success]` 标记的实测披露——parser 接线属 M1-006)
- Requirements/AC:`REQ-HDC-001`、`REQ-HDC-002`、`REQ-HDC-003`、`REQ-HDC-005`；
  `AC-HDC-005-01`(仅 fixture prerequisite，其他 family 仅为 platform matrix input)
- Depends on:none；但缺任一 required raw input/provenance 时 fail closed，不得开始登记
- Allowed paths:
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCGoldenResourceContractTests.swift`
  - `Packages/ArkDeckKit/Package.swift`（仅为 `ArkDeckContractTests` 声明
    `.copy("Fixtures/HDC/Golden")` resources；必须保留 `Golden/<version>/...` 目录树，
    不得改变其他 target/product/dependency）
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/changes/chg-2026-005-hdc-parser-golden-registration/evidence/runs/TASK-I5-001/**`
  - `openspec/changes/chg-2026-005-hdc-parser-golden-registration/tasks.md`（仅更新
    `TASK-I5-001` 状态与 completion evidence）
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/baselines/**`
  - `Packages/ArkDeckKit/Sources/**`
  - 上述清单以外的 Tests/Fixtures 与其他 change/task evidence
- Risk:low(仓库内固定字节、hash 与登记文件；无子进程、HDC、网络或设备)
- Hardware required:no

### Deliverables

- 从已有 M0A candidate 精确提取的 failure raw fixture files；
- 从维护者认可的 authoritative/human-captured input 逐字节登记 standalone success、
  healthy/checkserver 与 version raw fixture；记录 capture/source context 与 evidence class，
  不执行真实 `hdc`，不从 parser 常量反向编造真实 output；
- 每个 fixture 的 ID/version/path/SHA-256/source lineage/exit code/stream/expected
  semantic classification 登记；
- 新版本 OpenHarmony integration profile 逐 family 固定 probe/mapping，并明确未登记 family
  为 unknown/unsupported；
- `ArkDeckContractTests` 通过 SwiftPM `.copy("Fixtures/HDC/Golden")` 注册并保留版本化
  resource 目录树，
  `HDCGoldenResourceContractTests` 仅经 `Bundle.module` 定位并重算每个 fixture hash；不使用
  `#filePath`/仓库 checkout 相对路径，避免未声明 raw file 与安装后路径漂移；
- 新版本 Integration lock 与 Core conformance shared-input fixture 列表，字段与
  hash 精确一致；
- run record 记录 base revision、输入/输出 hash、字节对应、命令、结果与
  零 dispatch 边界。

### Verification

- 字节级证明 failure fixtures 仅来自 `HDCFixtures.exitZeroFailure` 与
  `HDCFixtures.largeOutputFailureTail`；success/health/version fixture 与维护者认可的原始
  input bytes 完全相等，且 provenance 不来自 Agent-run installed HDC；
- 静态 family coverage audit 证明 M1-006 fake-hdc 中每个被 adapter 当成 supported 的
  success/failure/health/version raw family 都有 profile entry 与 pinned fixture；
- 独立重算每个 SHA-256，与 Integration lock 及 Core conformance 登记三方
  完全一致；
- `HDCGoldenResourceContractTests` 从 `Bundle.module` 枚举精确 fixture 集并验证 bytes/hash；
  SwiftPM build output 不含 `found ... file(s) which are unhandled`；
- `swift build --package-path Packages/ArkDeckKit --build-tests` 与
  `swift test --package-path Packages/ArkDeckKit --filter HDCGoldenResourceContractTests` 通过；
- `scripts/check-sdd.sh` 与 `git diff --check` 通过；
- 只得结论 fixture prerequisite registered，不得将
  `AC-HDC-005-01` 、`TASK-M1-006` 或任何 platform conformance 标记为 passed/done。

## TASK-I5-002 — 恢复 TASK-M1-006 readiness

- Status:blocked(等待 `TASK-I5-001` done 并合入 main;`TASK-M1-005` 已 done——实现 PR #37
  main `9e1f1da`、状态 PR #38 main `0e7aa8e`)
- Requirements/AC:`REQ-HDC-001`、`REQ-HDC-002`、`REQ-HDC-003`、`REQ-HDC-005`；
  `AC-HDC-005-01`(只读 fixture dependency)
- Depends on:`TASK-I5-001`、`TASK-M1-005`；且 M1-006 的 UI/durable-audit readiness
  amendment 必须已由维护者合入
- Allowed paths:
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`（仅更新
    `TASK-M1-006` readiness/status 与对应 blocker 结论）
  - `openspec/changes/chg-2026-005-hdc-parser-golden-registration/evidence/runs/TASK-I5-002/**`
  - `openspec/changes/chg-2026-005-hdc-parser-golden-registration/tasks.md`（仅更新
    `TASK-I5-002` 状态与 completion evidence）
- Forbidden paths:全部源码、Tests/Fixtures、Core/spec/contract/baseline/platform/integration
  输入与其他 task/evidence。
- Risk:low(只读 readiness/status 复核)
- Hardware required:no

### Deliverables

- 独立 readiness/status PR 验证 failure + success/healthy/checkserver/version pinned fixture
  在 `main` 中存在、hash 匹配且与 profile mapping 一致；
- 复核 `TASK-M1-005` 已 done 且其 production `DurableSessionAuditAppending`/
  `SessionManifestPublishing` 接口有 reopen/replay/confirmation evidence，
  M1-006 的 Workflows durable adapter、HDC UI/XCUITest 与 Package/Xcode 接线路径已经
  approved；
- 只有上述门禁全部满足时才将 `TASK-M1-006` 从 `blocked` 恢复为
  `ready`，并明确 pinned golden path 只读，实现任务不得重写 fixture 后自行
  判 pass；同一 PR 内将 `TASK-I5-002` 状态和 completion evidence 如实更新。

### Verification

- 重算全部 pinned fixture hash；核对 OpenHarmony profile/Integration lock/Core conformance
  登记及 supported family closure；
- 核对 `Package.swift` resource declaration 仍精确指向 `Fixtures/HDC/Golden`，且 I5-001
  build/resource smoke evidence 已在 `main`；M1-006 只读使用 `Bundle.module`，无需再次修改
  resource declaration；
- 确认 M1-006 所有其他依赖为 `done`，并逐项核对 UI Scenario 与 durable
  audit adapter 所需 allowed paths/verification 已存在且无冲突 forbidden path；
- `scripts/check-sdd.sh` 与 `git diff --check` 通过；本 PR 不带实现或
  parserGolden pass evidence。

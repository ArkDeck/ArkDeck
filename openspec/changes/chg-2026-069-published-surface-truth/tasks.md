# Tasks — CHG-2026-069

两个任务,串行。Task 的 `ready` 只有在本 proposal PR 经维护者 review/merge
进入 protected `main`、且 design.md 的三条裁决已给出结论后生效;合入前
不得开始实现 PR。实现 PR 推 `agent/**` 分支由 CI 以 bot 身份开 PR,标题
声明 Task ID,先跑 `scripts/check_pr_paths.py --preflight` 并直接看退出码。

**两个任务都会移动 `catalogDigest`,必须串行,且与仓内任何其他 digest
变更串行。**

## TASK-PST-001 — 收回六个永拒 enum 值

- Status:blocked(等 design.md §1 与 §3 的裁决;proposal 未 merge 前不开工)
- Golden Journey:GJ-5(发布面即真相);GJ-1/GJ-3 的提交前反馈质量
- Platform:macos
- Requirements:proposal「目标」1、「诚实边界」全部条目
- Acceptance:PST-AC-1..4(见 verification.md)
- Depends on:本 proposal merge;design.md §1 裁决(A/B)与 §3 裁决(1/2/3)
- Applicable failure patterns:
  - `AF-004`(生产者→消费者类型缝)——enum 是生成器的输入,`RuntimeJobEngine`
    的手写分支是它的下游消费者;删值必须同时删分支,否则留下一段永不触发
    的死码,而下一个读它的人会以为那个值还存在;
  - `AF-010`(套套逻辑断言)——负向用例必须断言拒绝**发生在 schema 层**
    (理由为 `outside its enum`),不能只断言「被拒了」——手写分支删除前后
    都会被拒,只断言结果的测试对本任务零信息量。
- Production reachability:
  `Agent/CLI/App → operation.describe(投影 enum) → job.submit →
   validateInputs(schema 层拒绝) → 授权闸`
- Trusted fact sources:不新增;Catalog JSON 仍是 enum 的唯一正本
- Allowed paths:
  - `Catalog/operations/debug.hap.v1.json`
  - `Catalog/operations/deploy.native-library.app-owned.v1.json`
  - `Catalog/operations/capture.diagnostics.v1.json`
  - `Catalog/generated/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Tests/**`
  - `scripts/catalog_gen/test_generate.py`
  - `openspec/changes/chg-2026-069-published-surface-truth/**`
- Forbidden paths:
  - `openspec/contracts/**`、`openspec/specs/**`、`openspec/constitution.md`
  - `AGENTS.md`、`PRODUCT-LOOP.md`、`.github/**`
  - 安全内核(capability/admission/binding/journal/recovery)的任何行为面
- Risk:low(纯收窄;六个值今天 100% 被拒,无调用方失去能力)
- Hardware required:no
- 交付内容(按 §1 裁决走 A 或 B):
  1. 方案 A:从三个 operation JSON 的 enum 删除六个值;删除
     `validateSupportedPlanInputs` 中对应的手写分支(注意
     `restartProfile` 是**补集式**判断,收窄后整段变死码);未实现语义
     写进对应 operation 的 `notes`。
  2. 方案 B:字段 schema 加 `unimplementedValues`,生成器下发、
     `operation.describe` 投影,**并加断言 `unimplementedValues` 与
     `validateSupportedPlanInputs` 拒绝集逐字相等的契约测试**。
  3. 按 §3 裁决处理四个退化为单值的字段(推荐选项 2:保留 + `notes`)。
  4. `python3 scripts/catalog_gen/generate.py --write` 再生,零漂移。

## TASK-PST-002 — 退役 `deploy.native-library.system@1`

- Status:blocked(等 design.md §2 裁决 + 操作者真机 journal 零引用确认)
- Golden Journey:GJ-5(发布面即真相)
- Platform:macos
- Requirements:proposal「目标」2、3、「诚实边界」全部条目
- Acceptance:PST-AC-5..8(见 verification.md)
- Depends on:`TASK-PST-001` 合入(digest 串行);design.md §2 裁决;
  **操作者在活机器上确认 `rg 'deploy.native-library.system' <state-dir>`
  零命中**——非零则回到 design.md §2 重新裁决,不得径直删除
- Applicable failure patterns:
  - `AF-001`(消费者枚举完整性)——2026-08-20 实测 8 处:2 个 profile、
    1 个 operation JSON、2 个生成物、1 个生成器测试、2 个 Swift 测试。
    **开工前必须重扫一遍**(`rg -n 'deploy.native-library.system' --hidden`),
    以实测为准而不是以本清单为准;
  - `AF-002`(生产可达)——「删除后一切仍可达」以全量测试 + `arkdeck`
    只读冒烟(`operation list` 返回 24 条)取证,不以编译通过为证。
- Production reachability:
  `Agent/CLI/App → operation.list(24 条)→ job.submit → 未知 reference
   走既有 unknownOperation 错误`
- Trusted fact sources:不新增(纯减法)
- Allowed paths:
  - `Catalog/operations/deploy.native-library.system.v1.json`(删)
  - `Catalog/profiles/dayu200.json`
  - `Catalog/profiles/openharmony-standard.v1.json`
  - `Catalog/generated/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Tests/**`
  - `scripts/catalog_gen/test_generate.py`
  - `openspec/changes/chg-2026-069-published-surface-truth/**`
- Forbidden paths:同 `TASK-PST-001`
- Risk:low(零 lowering,今天 100% `operationNotSupported`)
- Hardware required:no(操作者的 journal 确认是**前置条件**,不是验收项)
- 交付内容:
  1. 按 §2 裁决删除或搬迁 operation JSON;两个 profile 各删一行
     `supportedOperations` 条目;生成器再生(零漂移)。
  2. 清理 8 处名册中的测试侧引用,含
     `RuntimeArtifactContractTests.swift` 的 `pinnedUntilVerified` 永久
     保留名单里的那一行。
  3. AR-15 的 `artifactMapping` 全目录覆盖断言在本任务之后加入(可同车,
     但必须在删除生效之后),断言
     `catalog.artifacts[required] ⊆ artifactMapping ∪ finalizeArtifacts`
     对全部 24 个 operation 成立。

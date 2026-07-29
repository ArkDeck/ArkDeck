# Tasks

## TASK-WSC-001 — Close typed diagnostics stdout action identity

- Status:ready
- Grade:D1
- Platform:macos
- Requirements:`REQ-WF-001`
- Acceptance:`AC-WF-001-01`、`AC-WF-001-02`
- Depends on:本 proposal PR 合并(即批准)
- Readiness input pins:

  ```yaml pins
  - path: openspec/specs/workflow-journal-recovery/spec.md
    blob: f97c64785533f832d6798a63e8c7c96080bb7b69
  - path: openspec/contracts/workflow-step.schema.json
    blob: c510d96478f3192168478b1a1669b5fcd2a848f7
  - path: openspec/contracts/catalogs/dump-recipes.yaml
    blob: d7aa1123ae35c321481575dfdbb2536126346b21
  - path: Catalog/operations/capture.diagnostics.v1.json
    blob: 56bf769f02827b1c2b4f6b354cb29b59c52cce74
  - path: Catalog/operations/debug.hap.v1.json
    blob: 6f231c5b6f8e9a3ced3a5f7ce0d3fb79abe7f5c8
  - path: Catalog/operations/flash.dayu200.v1.json
    blob: f07e0eff81e2ef132706c566d30e521eb82931a4
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift
    blob: d96423593978f84a0db7623a1b94863e5d12de26
  - path: scripts/catalog_gen/generate.py
    blob: 9820e75d27ace3501cad9e16829cd9c689fc3c97
  ```
- Applicable failure patterns:`AF-001`(共享 schema/generator/Swift
  consumer 必须同时纳入 allowed paths)、`AF-004`(Catalog producer 与
  Swift/schema consumers 必须端到端对齐)
- Production reachability:
  `scripts/catalog_gen` / checked-in generated Catalog →
  `RuntimeOperationCatalog` → `RuntimeJobEngine` typed plan →
  `WorkflowStepValidator` durable intent → provider dispatch。
  本任务不新建 authority；E0/E1 admission 仍在 engine，effect dispatch point
  仍是 descriptor-bound provider dispatcher。
- Trusted fact sources:
  action identity 只来自 reviewed `Catalog/operations/*.json` 与 reviewed
  diagnostics recipe contract；generator 绑定 exact catalog/action pair 并写入
  generated Swift。调用方只能提交 operation + typed inputs，不能提交 actionRef、
  executable、argv、shell 或验证 receipt。
- Allowed paths:
  - `Catalog/schema/operation.schema.json`
  - `Catalog/operations/capture.diagnostics.v1.json`
  - `Catalog/operations/debug.hap.v1.json`
  - `Catalog/operations/flash.dayu200.v1.json`
  - `Catalog/generated/effect-authorization-matrix.md`
  - `openspec/contracts/workflow-step.schema.json`
  - `openspec/contracts/catalogs/diagnostics-stdout.yaml`
  - `scripts/catalog_gen/generate.py`
  - `scripts/catalog_gen/test_generate.py`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeOperationCatalogContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/WorkflowStepContractTests.swift`
  - `openspec/changes/chg-2026-050-diagnostics-step-contract/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/verification/**`
  - `openspec/integrations/**`
  - `openspec/platforms/**`
  - `openspec/baselines/**`
  - `openspec/contracts/workflow-step-registry.yaml`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `ArkDeckApp/**`
  - `.github/**`
  - `AGENTS.md`
- Risk:medium
- Hardware required:no

### Deliverables

- Catalog stdout steps carry a closed, generated `actionRef`.
- Diagnostics stdout recipe and workflow-step schema/Swift validator accept the
  same exact action pairs and reject all other pairs.
- Catalog generator rejects missing/unknown/misplaced actionRef and preserves
  the pair in generated Swift.
- Contract vectors prove default/boundary typed inputs construct a valid
  `WorkflowStep`, malformed/raw-command inputs fail before dispatch, and
  Catalog/generated output has zero drift.

### Verification

- `AC-WF-001-01` → existing free-command negative suite → zero external dispatch.
- `AC-WF-001-02` → generator negatives + JSON Schema/Swift parity matrix +
  generated-drift check → missing/unknown/unrepresentable actionRef is rejected
  before Runtime dispatch.
- Full `scripts/check-sdd.sh`, catalog generator tests and
  `swift test --package-path Packages/ArkDeckKit`.

### Stop conditions

- 任一 operation 的 effect/authorization/binding/step order 需要变化；
- 需要增加任意 executable/argv/shell/raw command/path 字段；
- Schema 与 Swift validator 无法用同一 exact action pair 保持闭合；
- 既有测试只有弱化断言才能通过。

任一命中即 blocked，并新起 scoped remediation；不得扩大本任务。

### Notes / handoff

完成后在 `evidence/runs/TASK-WSC-001/` 追加 run 记录。完成并合入后，
CHG-2026-049 仍需 fresh readiness，不能由本任务替它翻回 ready。

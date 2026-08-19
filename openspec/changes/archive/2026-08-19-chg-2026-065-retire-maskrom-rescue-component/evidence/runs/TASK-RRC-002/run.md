# TASK-RRC-002 — vendor 时代死代码与误导命名清理（2026-08-19）

## 变更清单

| 项 | 实际处置 |
|---|---|
| `RockchipFlashExecutionStaging.swift`(777 行) | 删除。`wl` 时代逐分区 tar 展开 + 镜像缓存，生产零调用（arkforged 经 `importArtifact` 收整包并自做空间预检） |
| `RockchipFlashExecutionFaultContractTests.swift` | 删除（其唯一主体是上述 staging）。其中被 `CompleteOverwriteRecoveryContractTests` 复用的 gzip/tar 构造器抽出为 `GzipTarTestArchive.swift`（自带错误类型，不再引用已删的 `RockchipFlashStagingError`） |
| `RuntimeJobEngine` 容量门 | 删除 `flashStagingAvailableBytes` 属性/注入参数与 `RockchipFlashStagingCapacity` 预检块（timeline 不再出现 `flash staging capacity preflight` 行；无任何测试断言该行） |
| `RockchipAuthorizationFacts.swift` | 删除整文件（`RockchipProductExecutePlanFactPort` 及其类型仅剩 test-only 调用方）。其"describe → forBuild → validate → makePlan"组合契约保留在 `Dayu20070035RuntimePlanOnlyContractTests` 的本地 helper 中——与 `FlashApplicationFacade` 的预览物化同构，反例覆盖（缺镜像/无版本/未知分区 fail-closed）逐条保留 |
| `RockchipFlashExecutionHost.swift` → `RockchipDeviceBinding.swift` | **纯文件改名**：`RockchipFlashExecutionHost` 作为类型早已不存在（文件内是 `RockchipProductBindingStore`/`RockchipDeviceBinding*`/USB 只读探测），只有文件名在误导。任务文本预想的"改类型名"经核实为无的放矢，按实际执行 |
| `RockchipFlashSessionReconcile.swift` → `RockchipLegacyFlashJournalReconcile.swift` | 文件 + 类型改名：`RockchipFlashSessionReconciler` → `RockchipLegacyFlashJournalReconciler`、`RockchipFlashSessionReconcileError` → `RockchipLegacyFlashJournalReconcileError`；CLI `arkdeck flash reconcile` 行为不变；契约测试文件/类同步改名。数据面类型（RunLock/Finding/OrphanedReservation）保名 |
| `scripts/README.md` | 索引行更新（RRC-001 顺延项；路径授权经 docs 治理 PR 补入本 task Allowed paths） |

旧名残留：`RockchipFlashSessionReconcil*` 全仓 0 处；`RockchipProductExecutePlanFactPort` 仅测试内历史注释 1 处（tripwire 只扫 Sources，且该名已无类型）。

## 验证

- `swift test --package-path Packages/ArkDeckKit --parallel`：**1726/1726 通过，exit 0**
  （较 RRC-001 基线少 5：删除的 staging 断言与新增 helper 的净差）。
- RRC-AC-5：staging/容量门源与测试均已删除，生产 grep 零引用。
- RRC-AC-6：改名逐引用完成，无 typealias。
- RRC-AC-7：端口及 error 类型删除，契约覆盖迁至组合 helper。

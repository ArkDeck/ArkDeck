# Verification — CHG-2026-069

> Change:CHG-2026-069-published-surface-truth@r1
> Status:planned;proposal merge 只批准 scope,不代表实现或验收通过

## Environment

- macOS 26 / Xcode 26.6 / Swift 6.3;
  `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test` 全量 +
  `build-for-testing`。
- 生成器:`python3 scripts/catalog_gen/generate.py --write` 后
  `git diff --exit-code`(双向零漂移由 check-sdd 承担)。
- **无真机需求。** 操作者的 journal 零引用确认是 `TASK-PST-002` 的
  **前置条件**,不是本表的验收项——它决定该不该开工,不决定开工后是否
  通过。

## Acceptance matrix

| AC ID | Verification method | Expected result |
| --- | --- | --- |
| PST-AC-1 六个值不再发布 | 契约测试遍历 catalog | `debug.hap@1` 的 `installPolicy`/`cleanupPolicy`/`portForwardProfile`、`deploy.native-library.app-owned@1` 的 `restartProfile`、`capture.diagnostics@1` 的 `redactionProfile` 的已发布 enum 中,六个值一个不剩(方案 A);或六个值逐字出现在各自字段的 `unimplementedValues` 中(方案 B) |
| PST-AC-2 拒绝前移到 schema 层 | 负向契约测试,逐值一条 | 提交含被删值的 request → `invalidInput`,**理由为 `input <key> value is outside its enum`**;断言必须比对理由,只断言「被拒」不算通过(AF-010) |
| PST-AC-3 死码消失 | 源码断言 + 全量测试 | 方案 A:`validateSupportedPlanInputs` 中针对六个值的分支不存在(含 `restartProfile` 的补集式整段);方案 B:契约测试断言 `unimplementedValues` 并集与该函数拒绝集**逐字相等** |
| PST-AC-4 生成器零漂移 | `generate.py --write` + `git diff --exit-code` | 退出码 0;`RuntimeOperationCatalogGenerated.swift` 与 `effect-authorization-matrix.md` 与 JSON 双向一致 |
| PST-AC-5 operation 名册 24 条 | `arkdeck operation list`(只读)+ 契约测试 | 返回 24 条且不含 `deploy.native-library.system@1`;既有「本引擎不新增已发布 operation」的两向集合断言同步更新为 24 条 |
| PST-AC-6 消费者零残留 | `rg -n 'deploy.native-library.system' --hidden` | 除 `openspec/`(历史证据与本 change 自身)外零命中;两个 profile 的 `supportedOperations` 不含它 |
| PST-AC-7 artifactMapping 全目录覆盖 | 新增契约测试 | 对全部 24 个 operation,`catalog.artifacts[required] ⊆ artifactMapping ∪ finalizeArtifacts` 成立,**零例外名单** |
| PST-AC-8 全量回归 | 全量 `swift test` + `build-for-testing` | 全绿;安全内核相关合约测试逐条未改动且全绿 |

## 不在本次验收内

- **`catalogDigest` 变更对既有 `REAL_DEVICE_PASS` 的影响处置**:按
  PRODUCT-LOOP §6 由维护者在合入时决定哪些真机验收需要重取。本 change
  只负责如实声明 digest 会移动。
- **system `.so` 部署能力本身**:PRODUCT-LOOP §20 的冻结项,本 change
  不解冻、不实现、不承诺时间。
- **六个值所代表语义的实现**(`installFresh` 的前置缺席读回、
  `restorePrevious` 的快照/恢复步、`debugger-default` 的端口转发编排、
  `restartProcess`/`none` 的重启读回、`strict` 脱敏):各自都是独立的
  能力设计,本 change 只把「发布了但不存在」这件事收回。
- **单值 enum 字段的最终去留**:design.md §3 给出推荐,裁决权在维护者;
  无论选哪个,`TASK-PST-001` 的验收都以裁决结论为准。

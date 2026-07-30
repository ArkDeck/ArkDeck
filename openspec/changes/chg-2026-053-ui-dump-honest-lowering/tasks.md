# Tasks — CHG-2026-053

单任务垂直交付(PRODUCT-LOOP §4:一个问题、一个垂直任务、一个产品 PR)。

## TASK-UDR-001 — capture-ui-dump 诚实执行垂直修复

- Status:done
- Done:2026-07-30;随本实现 PR 合入生效(维护者 review + merge 即批准);
  UDR-AC-1..3 PASS、UDR-AC-4 pending-hardware(定义为不阻塞 done),
  evidence = `evidence/runs/TASK-UDR-001/run-r1.md`
- Platform:macos
- Requirements:proposal What 1-5(契约 windowInventory、step 切换与重生成、
  componentTree fail-closed 背线、真实 INV-1 lowering、argv 层测试)
- Acceptance:change-local UDR-AC-1..4,登记于 `verification.md`
- Depends on:none(change 随本 proposal PR 合入即 approved)
- Hardware required:no(contract/fake 面即可交付;UDR-AC-4 真机复验随下一次
  已接管设备的 E0 运行补记,如实分类,不以 fake 顶替、不阻塞本任务)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `openspec/contracts/catalogs/diagnostics-stdout.yaml`
  - `openspec/contracts/workflow-step.schema.json`(schema 与 Swift validator
    的 action 对必须同步,否则两面契约漂移)
  - `scripts/catalog_gen/test_generate.py`(生成器契约钉死 stdout action
    引用集与 schema 词表;action 集变更必须同 PR 更新 pin,先例
    CHG-2026-050 TASK-WSC-001 授权面)
  - `openspec/changes/chg-2026-053-ui-dump-honest-lowering/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/verification/**`(全局)、`openspec/baselines/**`、
    `openspec/contracts/workflow-step-registry.yaml`
  - `scripts/**`(仅上列 `catalog_gen/test_generate.py` 单文件除外)、
    `.github/**`、`AGENTS.md`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(已发布 operation 的 step actionRef 变更——journal 身份与真实
  命令自此一致;E0-only,零 mutation 面;componentTree 转为结构性拒绝,
  不存在静默降级)

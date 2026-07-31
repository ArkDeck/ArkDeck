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

## TASK-UDR-002 — 组件树按文件型产物交付(r2)

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准);
  UDR-AC-5..7 PASS(contract 面),**UDR-AC-8 亦 PASS** —— 提案预期它是
  pending-hardware,实际当天真机一次跑通(`job-cdeb06b6…`,`ui-tree.json`
  26,143 字节 / 42 节点);evidence = `evidence/runs/TASK-UDR-002/run-r2.md`
- Platform:macos
- Requirements:proposal r2 What 1-5(三个 optional 步骤、`uiComponentTree` 输入与
  `ui-tree.json` 产物、effect 随输入升级、dumpLayout lowering 与既有接收/清理复用、
  windowInventory 腿不变),以及 r2「实现约束」一节的脱敏发布路径
- Acceptance:change-local UDR-AC-5..8,登记于 `verification.md`
- Depends on:TASK-UDR-001(done);r2 proposal 合入即 approved
- Hardware required:no(contract/fake 面即可交付)。**但 UDR-AC-8 需要一次设备
  窗口**:命令面已在 2026-07-31 实测为 `[R]`,ArkDeck 的 lowering 与端到端未验证;
  按 UDR-AC-4 的先例,该 AC 保持 pending-hardware 且不阻塞任务 done
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `scripts/catalog_gen/test_generate.py`(生成器 pin 随 catalog 步骤/输入集
    变更同 PR 更新;先例 CHG-2026-053 TASK-UDR-001 与 CHG-2026-050 TASK-WSC-001)
  - `openspec/changes/chg-2026-053-ui-dump-honest-lowering/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/verification/**`(全局)、`openspec/baselines/**`、
    `openspec/contracts/**`(r2 不新增 action:文件型步骤按 kind 映射,
    无 actionRef,故契约目录整体不在范围内)
  - `scripts/**`(仅上列 `catalog_gen/test_generate.py` 单文件除外)、
    `.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、`ArkDeck.xcodeproj/**`、
    `ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(**首次让一个 readOnly 起步的 operation 在输入驱动下把 UI 采集升为
  deviceMutation**;三层约束:未请求时计划与授权面逐字节不变、请求时经既有
  capability 路径、收不到文件按 D4 语义 fail closed。另有一条易错点已写进
  proposal:含文本的 JSON 必须走脱敏 publish,不得复用 trace 的 file-backed 发布)

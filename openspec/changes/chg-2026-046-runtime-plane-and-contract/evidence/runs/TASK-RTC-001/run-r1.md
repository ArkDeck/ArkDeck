# TASK-RTC-001 run r1 — MU-1 垂直交付

- Date:2026-07-29
- Executor:agent(实现;批准与合并 = 维护者)
- Base:main `7125cda` (#772 之后)
- Evidence class:contract(零设备执行、零硬件 evidence 主张)

## 交付面

- **T01 治理**:`AGENTS.md`(新增"控制平面"节 + 执行规则改垂直 PR 形态)、
  `openspec/governance/enforcement.md` 2.1.0→2.2.0(ADDED 控制平面分离节,
  MODIFIED PR 载体规则,D0 例句同步)、`openspec/project.md`(控制平面与
  Catalog 节)、`docs/adr/0004-runtime-plane-separation.md`。
  `scripts/host_loop/**` 零字节改动(diff 为证);其硬件门/D0 门为既有
  实现事实,本 change 只做治理成文。D2/E2 规则逐条保留:
  "真实硬件与 destructive 操作"节零改动;AGENTS.md 禁令节零改动。
- **T02 API v2**:`RuntimeOperationModelsV2.swift`(request/manifest/错误码
  /codec:治理字段 fail-closed 拒绝、major≠2 fail-closed、minor 前向兼容、
  重复键拒绝、1MiB 上限)+ `RuntimeOperationLegacyAdapter.swift`
  (v1→v2 单向升级、治理身份降级为 provenance、未映射操作 fail-closed)。
- **T03 Capability**:`ArkDeckCore/RuntimeCapability.swift`(模型不变量 +
  纯授权判定 + E0 默认只读策略)+
  `ArkDeckStorage/RuntimeCapabilityStore.swift`(durable install/list/
  inspect/revoke/consume;flock + 原子改名 + fsync;reservation 幂等重试、
  漂移冲突、拒绝零消耗)。
- **T04 Catalog**:`Catalog/`(schema + 6 operations + 2 profiles +
  生成 matrix)、`scripts/catalog_gen/`(校验器/生成器 + 27 项测试)、
  `ArkDeckCore/RuntimeOperationCatalogTypes.swift` + 生成常量、
  `check_sdd.py` family 11(双向 drift,实测:语义变异 → 2 error,
  还原 → 0 error)、`scripts/README.md` 边界表行。

## 测试结果(本树,非 /private/tmp 检出)

- `swift test` 全量:**557 tests / 1 skipped / 0 failures**(新增 48:
  RuntimeCapabilityTests 9、RuntimeOperationCatalogTests 9、
  RuntimeOperationV2ContractTests 16、RuntimeCapabilityStoreContractTests 10,
  另含既有套件零回归)
- `scripts/check-sdd.sh`:0 error / 0 warning / 111 AC(family 11 生效)
- `test_check_sdd.py`:62 OK(含新增 OperationCatalogFamilyTests 6)
- `test_check_pr_paths.py`:50 OK;`test_agent_pr_workflow.py`:8 OK;
  `test_sdd_runtime_entry.py`:33 OK
- `host_loop` 套件:644 OK(1 expected failure,基线既有)
- `catalog_gen/test_generate.py`:27 OK(含 schema↔validator 词表锁步、
  负向矩阵、确定性、digest 稳定性)

## AC 结论

- `RTC-GOV-001` PASS(文本交付 + host_loop/D2/E2 零弱化,diff 复核)
- `RTC-API-001` PASS(round-trip、治理键拒绝矩阵 9 变体、版本门、
  前向兼容、重复键、超限)
- `RTC-CAP-001` PASS(不变量 + 过期/撤销/耗尽/跨 scope/超 ceiling/
  plan digest 全 fail-closed;消耗原子且重试幂等、拒绝零消耗、重开持久)
- `RTC-CAT-001` PASS(schema 全过、词表封闭、E2 钉死、双向 drift 实测、
  生成确定性)
- `RTC-COMPAT-001` PASS(全量套件零回归;v1 契约测试零修改;adapter
  10 映射 + 5 未映射 fail-closed + 授权不迁移)

## 偏差与遗留

- `catalog_gen` 测试经 `test_check_sdd.py` 子进程桥接进 CI(sdd-guard 已
  跑 test_check_sdd.py;`.github/**` 在本任务 Forbidden paths,故不改
  workflow)。后续 MU 若动 `.github/**` 可改为直接 discover。
- v1 的 sendOwnedFile/receiveOwnedFile/createPortForward/removePortForward/
  rebootDevice 无 v2 composite 对应,adapter 显式 fail-closed;进入 MU-4
  (T13 port-forward 属 debug.hap 输入)与后续 catalog 增补决策。
- Runtime v2 的 result/job 模型随 MU-2 引擎交付(v1 policyBlocked 丢
  blockerCode 缺陷已在 v2 错误码设计中修正,result 面落地在 MU-2)。

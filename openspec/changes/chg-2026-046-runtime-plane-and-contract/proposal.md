---
id: CHG-2026-046-runtime-plane-and-contract
revision: 1
status: approved # 合并本 PR 即维护者批准(V2 "merge 即批准");本 change 同时交付该合并语义的成文化(见 What changes / T01)
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Runtime plane separation and device runtime contract (MU-1)

## Why

《ArkDeck AI 自动化设备调试改造:完整执行任务清单》(维护者 2026-07-29 下达)
要求把日常设备运行从仓库治理流程中解耦:让 AI 通过受控、可恢复、可审计的
typed operation 自动完成设备接管、诊断抓取、HAP 调试、`.so` 部署与刷机,
日常 E0/E1 运行不再要求 OpenSpec task、GitHub PR 或逐次人工审批。

PRE-00 基线映射(baseline `2e1fe11e0c5860599bde03448a1f48d9ee596b80`,
本 change 基于 `7125cda`;全量 Swift 套件通过、check-sdd 0 错误/111 AC、
脚本测试 147 项全绿)确认了根因:

1. `AgentDeviceOperationRequest`(v1.0.0)把 `changeId`/`taskId` 定为必填
   并用正则强校验(`AgentDeviceOperationModels.swift:142`),运行时身份与
   仓库治理身份被结构性绑死;授权模型(`AgentExecutionAuthorityKind
   .readyTask`)同样以 change/task 为载体。
2. operation 语义分散在 draft registry JSON(chg-2026-025 目录内,无任何
   production Swift 加载方)、`WorkflowStepRegistry`(Swift)、
   `workflow-step-registry.yaml` 与散落文档中,新增 operation 需要手工同步
   多处;E1/E2 授权无独立于 Git task 的可撤销 capability 载体。
3. 治理文档(AGENTS.md / enforcement.md)将 proposal→approval→readiness→
   实现→done→verify→archive 各自定为独立 PR,一个任务的生命周期需要 5+ 个
   PR;其中 readiness-only/done-only/verified-only PR 是纯状态载体。

## What changes

本 change 是清单 **MU-1**(T01+T02+T03+T04)的垂直交付单元,含治理文本、
契约代码、catalog 数据、生成器与测试,由单一实现 PR 交付。

### T01 — Repo Agent 与 Device Runtime 两平面分离,简化治理流程

- `AGENTS.md`、`openspec/project.md`、`openspec/governance/enforcement.md`
  明确两个控制平面:**Repo Agent**(改代码/契约/catalog,经 OpenSpec+PR)
  与 **Device Agent Runtime**(执行已发布 operation,产生 runtime job/
  session/artifact,不产生 Git task/PR)。
- 只有以下变化仍需 OpenSpec/PR 审批:新 operation 或破坏性修改、新
  provider、新 integration/device profile、E2 安全策略变化。
- 风险分级成文:D0(文档/生成物/纯状态)、D1(普通代码、E0、可逆 E1)、
  D2(刷机/解锁/格式化/系统分区 mutation);现行 D2 审批规则全部保留。
- 废止 readiness-only / status-only / done-only / verified-only 独立 PR
  形态:一个垂直交付单元一个 PR,测试与 evidence 随实现同 PR 提交,任务
  状态翻转随实现 PR 完成;proposal 可携带 `status: approved` 落地,合并
  行为本身即维护者批准(与 V2 "merge 即批准" 信任根一致)。
- `host_loop` 职责边界成文:仅领取仓库开发任务;设备执行门
  (`hardware required` 拒领、`DISPATCHABLE_GRADES = {"D0"}`)现已存在,
  本 change 不改其代码,仅将该边界从实现事实升格为治理承诺。

### T02 — Runtime API v2,运行时删除仓库治理字段

- 新增 `RuntimeOperationRequest`(schema 2.0.0):`requestID` +
  `idempotencyKey` + `target`(durable target)+ `operation`(id@version)
  + typed `inputs` + `requestedOutputs` + 可选 `authorization`
  (runtime capability 引用)+ 可选 `clientContext`。
- v2 请求**结构性排除** `changeId`/`taskId`/PR OID/主干 commit OID:顶层
  出现任一治理字段即 fail-closed 拒绝(稳定错误码)。
- 仓库来源信息移入 `PublishedOperationBundleManifest`
  (`sourceRevision`/`sourceChangeID`/`sourceTaskID` 全部可选)。
- 提供 legacy v1→v2 adapter(v1 契约与测试保持通过,adapter 输出
  deprecation 注记);新执行内核(MU-2 起)只接受 v2。
- 稳定错误码:invalid request / unknown operation / invalid input /
  target not found / authorization required / conflict /
  unsupported profile / unsupported version;未知主版本 fail-closed,
  次版本内未知字段前向兼容。

### T03 — Runtime Capability 模型,替代逐任务审批

- 新增 `RuntimeCapability` 模型:capability ID、target scope、operation/
  version scope、effect ceiling、input constraints、签发/失效时间、最大/
  剩余使用次数、issuer/provenance、E2 exact plan digest、revoke 状态。
- 策略:E0 可由本地默认只读策略允许(仍受 target/timeout/bytes 约束);
  E1 使用 standing capability;E2 使用绑定精确 plan digest 与 artifact
  hash 的一次性 capability。过期/撤销/耗尽/跨 scope 一律 fail-closed。
- 新增 durable `RuntimeCapabilityStore`(复用 ArkDeckStorage 既有 durable
  原语与 reservation 语义):install/list/inspect/revoke/原子消耗;失败
  恢复不得重复消耗。现有 `AuthorizationUsageLedger` 保留为 legacy 载体,
  由 v1 adapter 继续消费,待 T25 迁移收尾后退役——不构成第二套并行授权
  执行路径。

### T04 — Operation Catalog v1 与生成/校验

- 新增仓库顶层 `Catalog/`:`schema/operation.schema.json` + 六个
  operation 文档(`observe.device.v1`、`capture.diagnostics.v1`、
  `debug.hap.v1`、`deploy.native-library.app-owned.v1`、
  `deploy.native-library.system.v1`、`flash.dayu200.v1`)+ profiles +
  `generated/`(effect/authorization matrix 文档)。
- catalog 字段:id/version/provider、effect/authorization/binding policy、
  typed input/output schema、ordered steps(封闭于
  `workflow-step-registry.yaml` 词表,禁止 generic shell step)、timeout/
  output budget、retry policy、unknown-outcome policy、compensation、
  artifact/privacy policy、concurrency key、profile constraints。
- 生成器 `scripts/catalog_gen/`(僅标准库 + 既有 PyYAML pin)从 catalog
  生成 Swift 常量(`ArkDeckCore` 内 `RuntimeOperationCatalog`)与 matrix
  文档;`check_sdd.py` 新增 catalog 一致性 family(schema 校验、步骤词表
  封闭、生成物 drift 双向比对),CI 现有 sdd-guard 入口自动覆盖。

## Out of scope

- 不实现 daemon/provider/job engine 接线(MU-2:T05-T08)、bootstrap 与
  真实 E0 走通(MU-3:T09-T11)及其后各 MU;
- 不修改 `openspec/specs/**` 任何 Core Requirement/AC 文本、不 bump Core
  baseline、不动 `openspec/contracts/workflow-step-registry.yaml`;
- 不删除 v1 请求模型、`TrustedDeviceOperationHost`、
  `AuthorizationUsageLedger`(T25 统一迁移退役);
- 不执行任何设备命令、不产生硬件 evidence(本 MU 无硬件面);
- 不修改 `scripts/host_loop/**` 代码与 `check_pr_paths.py` 判定逻辑。

## 与既有 change/task 的映射(PRE-00 第 4 项)

- `chg-2026-025-ai-native-unattended-device-ops` 是本清单的直接前身:其已
  done 任务(AIN-001/002/003/003R/005/006/007/008/009/009R/010/BKMK-001)
  交付的 host/契约/授权/持久化能力被本 change 及后续 MU **复用而非重建**;
  其 blocked 任务与清单映射为 AIN-011→T10/T11、AIN-012→T12、AIN-013→T13、
  AIN-014→T15、AIN-015→T19/T20、AIN-016→T11/T13/T15 硬件 evidence、
  AIN-004→T18、AIN-010P→T10、AIN-017→T25。上述 blocked 任务在对应 MU 落地
  时按 supersede/merge 处置并在该 MU 的 change 内登记,本 change 不翻转
  它们的状态。
- `chg-2026-008` 的 UD-* blocked 任务→T12;`chg-2026-006` M0B-002→T11
  evidence;`chg-2026-026` blocked RKFUI-*→T17/T21;`chg-2026-031`
  SSET-*→T14/T21;`chg-2026-036`(BRC-003 ready 等 D2 release 环境)与
  `chg-2026-045`(HOR-001 已实现合入 #772)独立推进,不受本 change 影响。

## Scope

- Canonical Core Requirements claimed:none(纯新增 capability 契约面)
- Canonical Acceptance claimed:none
- Change-local acceptance:`RTC-GOV-001`、`RTC-API-001`、`RTC-CAP-001`、
  `RTC-CAT-001`、`RTC-COMPAT-001`
- Contracts/schemas:新增 `Catalog/schema/operation.schema.json` 与六个
  operation 文档;不修改既有 `openspec/contracts/**`
- Core baseline bump:no;保持 `CORE-2.1.0`

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | 契约与治理交付;无 conformance 迁移 | 新增纯值类型契约、catalog 数据与治理文本 |
| Windows | deferred / unchanged | 端口未启动;契约保持 Foundation-neutral |
| Linux | deferred / unchanged | 端口未启动;契约保持 Foundation-neutral |

## Safety, privacy, and compatibility

- 本 change 零设备执行、零硬件 evidence 主张;新增代码均为值类型契约、
  durable 存储与生成器,不接入任何 dispatch 路径。
- v2 请求与 capability 模型全部 fail-closed:未知主版本、治理字段出现、
  capability 过期/撤销/耗尽/跨 scope 一律拒绝并有测试钉死。
- E2 审批语义不弱化:catalog 中 `deploy.native-library.system.v1` 与
  `flash.dayu200.v1` 固定 destructive + 一次性 exact-plan capability,
  默认策略不签发;现行 standing authorization 机制在迁移期继续有效。
- 兼容性:v1 请求经 adapter 继续可用,既有全部契约测试保持通过;
  `AuthorizationUsageLedger`、`TrustedDeviceOperationHost` 行为不变。
- 回滚:revert 实现 PR 即完整回滚(新增文件为主,治理文本按 diff 回退);
  无数据迁移、无持久状态格式变更。

## Approval and flow

按本 change T01 交付的新流程执行:本 proposal PR 携带 `status: approved`
落地,**维护者 review + merge 本 PR 即批准该 scope**(与 V2 "合并即批准"
信任根一致,不再有独立 approval-only PR)。TASK-RTC-001 以 `ready` 建立,
其实现、测试、evidence 与状态翻转由**一个**垂直实现 PR 交付;change 级
verify 与 archive 仍为独立后续动作。

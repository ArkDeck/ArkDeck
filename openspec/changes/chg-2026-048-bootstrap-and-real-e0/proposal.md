---
id: CHG-2026-048-bootstrap-and-real-e0
revision: 3
status: approved # r2 由 #802 批准；本 r3 仅在维护者 review/merge 后生效
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Bootstrap and real E0 walking skeleton (MU-3)

## Why

MU-1/MU-2(CHG-2026-046/047,均已合入)交付了契约、catalog、capability、
daemon 与 job engine,但 runtime 仍无法接管一台真实设备:没有"零 binding
时如何安全建立 binding"的启动路径(鸡生蛋死锁),HDC E0 typed action 只有
观察三件套,`arkdeck-agentd` 的 dispatcher 显式拒绝真实 dispatch。清单
MU-3(T09-T11)是全清单的**强制门槛**:真实 `observe.device@1` 走通之前,
不再扩展新治理框架或更多抽象。

## What changes(T09-T11 垂直交付)

- **T09 Bootstrap 状态机**:独立 E0-only admission path
  (discoverHostTools → observeHDCServer → enumerateDeviceCandidates →
  waitForPhysicalTrust → observeSelectedDevice → createDurableTarget →
  persistInitialBinding → handoffToNormalRuntime)。effect ceiling 永久
  E0/readOnly,封闭观察 action,结构性无 mutation 面;多候选须显式选择,
  unauthorized/offline → waitingForHuman 并给出明确人工提示;re-adopt
  幂等。durable target 存 daemon 状态目录(stable identity sha +
  binding revision + facts snapshot),binding 经既有
  `DeviceBindingJournalAdapter` 语义持久。daemon 增
  `doctor`/`target.list`/`target.adopt` 实现(MU-2 占位转正),CLI 增
  `arkdeck doctor` / `device list` / `device adopt`(经 AgentClient,
  零直连执行栈)。
- **T10 HDC E0 typed action pack**:扩展 `HDCProviderAction` 观察族为
  完整 E0 面——allowlisted property query、bounded HiLog capture、
  UI Dump/HiDumper capture、bounded trace capture、receive
  provider-created remote artifact、remote temp cleanup;全部 typed
  request(duration/buffer/filter/bytes 有界有默认),remote temp 路径
  由 provider 生成并绑定 session/step,输出经 semantic parser
  (截断/超时/invalid UTF-8/空输出显式 outcome),artifact 接收验
  hash 并清理远端;未知 profile → unsupported。reboot 保持原 effect
  分类,不入 E0。
- **T11 `observe.device@1` walking skeleton**:生产 dispatcher 绑定
  descriptor 校验执行器(`ProcessIdentityBoundRequest`,替换 MU-2 的
  fail-closed 拒绝器),HDC provider 获得生产 facts/lowering 组合
  (external-first discovery → descriptor → 真实 argv,均 provider 内部);
  端到端:CLI submit → daemon → engine → 真设备观察 → device-facts/
  tool-facts/binding-snapshot/manifest artifacts → 重启后可查;identity
  与 durable binding 不一致 fail-closed;请求零 changeID/taskID。

## 硬件门槛(如实分层)

契约/fixture/fake-integration 面随实现 PR 交付并可绿;**真机验收
(BER-HW-001/002)必须维护者设备窗口**:执行 = 维护者按设备窗口模型
运行 Agent 起草的步骤并贴回 transcript,Agent 核验后以 evidence 补记。
实现 PR 落地时任务状态 = `done`(代码面)且 hardware 面显式标注
`hardware-pending`;窗口完成前**不得**声称 T11 完成、不得开工 MU-4。

## Out of scope

- capture.diagnostics@1 组合 operation(T12/MU-4;本 change 只交付其
  下层 E0 action)、HAP/E1 面(T13)、artifact 策略强化(T14);
- Rockchip 面零改动;E2 面零改动;`Catalog/` 数据零改动
  (observe.device@1 已在 catalog);
- 不修改 `openspec/specs/**`、不动既有守卫钉住的 HDCProduction 段。

## 与既有 change/task 的映射

- 吸收 chg-2026-025 blocked 任务的对应面:AIN-011(E0 观察/HiLog/
  Artifact executor)→ 本 change T10/T11;AIN-010P(E0 registration
  capture)→ T10 的 profile 登记面。**两任务状态本 change 不翻转**,
  supersede 登记留待其 change 修订(T25 统一收尾)。
- 复用:MU-2 全部地基 + 既有 discovery/verifier/binding adapter/
  probe registries(chg-2026-022/043 面原样消费)。

## Scope

- Canonical Core Requirements claimed:none
- Change-local acceptance:`BER-BOOT-001`、`BER-E0-001`、`BER-SKEL-001`
  (contract/fake)+ `BER-HW-001`、`BER-HW-002`(真机,窗口后补记)
- Core baseline bump:no

## r2 scope reconciliation（2026-07-29）

本节是 D1 proposal revision；它只在维护者 review/merge 本 PR 后生效。
它修复 r1 proposal/design 与实现 PR #781 中 verification/acceptance
判据之间的冲突，不把该冲突包装成 D0 verification 结论。

- r1 `What changes` 的 T11 句子中
  `device-facts/tool-facts/binding-snapshot/manifest artifacts`、
  `design.md` §3 的四文件落盘/`artifact.*` 读取 bullet，以及
  `tasks.md` T11 scope 中的 `artifacts`，均由本 r2 **替换**为：
  `observe.device@1` 经 production descriptor-bound dispatcher 得到
  succeeded + 完整 durable job timeline，daemon 重启后仍可查询；
  identity/binding/descriptor drift 与治理字段继续 fail closed。
- artifact 文件发布与 `artifact.*` 读取不属于 CHG-2026-048 的
  `BER-SKEL-001`/`BER-HW-001` 判据，递延 T14（CHG-2026-049）。
  CHG-2026-048 verification 不得借用 CHG-2026-049 的后续实现或证据，
  也不得声称四文件已经由本 change 交付。
- `BER-BOOT-001`、`BER-E0-001`、`BER-HW-002` 以及 T09/T10 的范围、
  安全边界和证据等级均不变；不修改 Core、catalog、代码、硬件 evidence
  或既有 run 记录。

## r3 binding/evidence remediation（2026-07-29）

本节是 D1 proposal revision；它只在维护者 review/merge 本 PR 后生效。
r2 merge OID 为
`34204b304efa9887dc811e7d99420df4519168ea`。r2 明确保留
identity/binding drift fail-closed，但合后 verification audit 发现该判据
与正式硬件证据仍未闭环，故 T11 gate 重新打开，不得直接翻 `verified`：

1. `RuntimeJobEngine` 当前从未调用 `DeviceProvider.resolveFacts`；
   `expectedBindingRevision` 只做 `>= 1` 的 wire validation，并被写入
   context/journal，却没有与 `RuntimeTargetStore.bindingRevision` 比较；
2. production `TargetStoreFactsPort` 只把 durable target record 回显为
   `ProviderFacts`，没有用 descriptor-bound E0 observation 证明当前连接
   的设备身份；device-bound intent 仍写 `pending-binding` 与全零 identity
   hash；
3. `ObserveDeviceSkeletonContractTests` 只有 descriptor drift 负向，没有
   target-not-found、binding revision drift 或 live identity mismatch 的
   零推进断言；
4. PR #784 的 Markdown 记录没有形成
   `openspec/contracts/hardware-evidence.schema.json` V2 record，缺
   `evidenceId`、physical confirmation time、firmware、`executedAt`、
   typed stepKinds/provider 等必填字段；其 restart 是 terminal job 后
   history query，replug 只比较 targetId，没有覆盖非终态安全恢复与
   mismatch fail-closed。

r3 **不放宽** `BER-SKEL-001`/`BER-HW-002`。但最新 main 又由
PR #804 合入 `CHG-2026-051@r2`（merge
`a09d3243b8bdec133198f843d4c258d39f54aa34`），该 approved change 已
明确独占以下闭环：hardware-evidence V3 current contract、三个 operation
的 exact-target/model/firmware typed preflight、production provider facts、
runtime receipt/projector 与 current Core baseline 晋升。它同时规定消费方
change 只能在其 verification/archive 后 fresh readiness + fresh run。

因此本 r3 新增 `TASK-BER-002`，状态为 **blocked**，而不是在
CHG-2026-048 内复制或抢先实现同一 gate：

- `CHG-2026-051/TASK-AHE-001` done 且 change verified/archive 前，
  CHG-2026-048 不修改 Runtime/Catalog/schema，不起草 D2 window、不执行
  设备命令、不借用其 scoped delta；
- 依赖关闭后，CHG-2026-048 必须以独立 r4 D1 fresh-readiness pin 当时
  current baseline/schema/Catalog/runtime，确认 exact-target preflight、
  binding journal 与 evidence projector 已成为可消费 current contract；
- r4 后重放 `BER-SKEL-001` 的 target/revision/live-identity 负向与
  restart contract；任一不满足时在 r4 显式列出本 change 仍需的最小
  remediation，不得假设 CHG-2026-051 自动证明本 AC；
- contract 通过后再开独立 D2 window PR，按届时 current evidence schema
  与 executor 模型 fresh 执行，覆盖 preflight 非终态重启/同
  idempotency 安全续行、物理拔插 rebind、错误 revision 零推进，并产生
  schema-valid record + 脱敏 run。PR #784 只作历史输入，不追认。

本 revision 不修改 Core、catalog、operation、provider/effect 分类、
hardware-evidence schema、代码或既有 raw evidence。dependency、
fresh-readiness、必要实现、D2 window、硬件 evidence 与 change
verification 均是顺序独立载体，前一门未合入时后一门零投机开工。

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | bootstrap/E0/生产 dispatch 实现 | 真机验收按设备窗口模型 |
| Windows / Linux | deferred / unchanged | transport/provider 边界已留 |

## Safety, privacy, and compatibility

- Bootstrap 结构性 E0:状态机类型面不含任何 mutation action 构造路径;
  普通 runtime 校验不因 bootstrap 放宽(独立 admission,非绕行)。
- 生产 dispatch 全链 fail-closed:descriptor 身份漂移拒绝(既有
  ProcessExecutor 语义)、未知 profile 拒绝、identity mismatch 拒绝;
  E0 仍受默认策略 timeout/bytes 约束。
- HiLog/dump/trace 原始产物不入 Git,落 daemon 私有状态目录;序列号等
  身份字节按既有脱敏纪律不入仓内 evidence。
- 回滚:revert 实现 PR;durable target 存储为新增独立文件。

## Approval and flow

本 proposal PR 合并即批准。TASK-BER-001 以 ready 建立;实现 PR 交付
代码+测试+文档+evidence(contract 面)+状态翻转(hardware-pending 注记);
真机 evidence 由后续设备窗口补记(evidence-only 追加,不改实现)。

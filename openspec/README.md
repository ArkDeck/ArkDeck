# ArkDeck Spec-Driven Development

> 模型：Living Specs + Audited Change Packages  
> 状态：Candidate baseline / execution gate closed  
> 日期：2026-07-12

交付/支持生命周期以当前 accepted `platforms/PLATFORM-PROFILES.lock.yaml` 为唯一事实源；Core baseline 与 Core conformance 只声明共同目标和不可删减的 AC，不固化哪个平台已交付。处于 `not_started_platforms` 或未达到 `verified` release gate 的 Profile 不得据此声称支持。

即使 Profile 为 `verified`，支持范围也只等于其 approved PCE 的 exact OS/architecture/package cell、source commit、release artifact hash 与有效期；PCE 必须逐项覆盖 Core AC、Port 和平台 `conformance-cases.yaml`。不得把单一测试机结果外推成整个平台支持。

ArkDeck 使用一种工具中立、可兼容 OpenSpec 的 SDD 结构：

- 借鉴 GitHub Spec Kit 的 Constitution、Spec → Plan → Tasks 和一致性检查；
- 借鉴 Kiro 的 EARS 式 Requirement 与 Given/When/Then 验收场景；
- 使用 OpenSpec 的 current specs、change delta 和 archive 作为长期演进模型。

核心选择是 **Living Spec**：`openspec/specs/` 描述当前候选或已接受的产品目标行为；design、tasks 和代码必须服从有效 baseline 与 approved delta。它不表示某项能力已经实现，实际可用性只能由 platform status、hardware matrix 和 verification evidence 证明。变更必须先形成 proposal 和 spec delta，通过验收后再合入 current specs。

## 目录

```text
AGENTS.md
openspec/
├── constitution.md
├── project.md
├── config.yaml
├── MIGRATION_MAP.md
├── architecture/
│   ├── system.md
│   ├── platform-ports.md
│   └── core-portability.md
├── specs/                       # 当前有效、跨平台的行为规格
│   └── <capability>/spec.md
├── contracts/                   # 机器可校验的数据与 Provider 契约
├── integrations/                # OpenHarmony/HDC/工具的版本化 Adapter 输入
│   └── INTEGRATION-PROFILES.lock.yaml
├── platforms/
│   ├── PLATFORM-PROFILES.lock.yaml
│   ├── linux/
│   ├── macos/
│   └── windows/
├── verification/
│   ├── policy.md
│   ├── core-conformance.yaml
│   ├── acceptance-index.txt
│   ├── acceptance-cases.yaml
│   ├── traceability.md
│   ├── hardware-matrix.md
│   └── hardware-evidence/*.json
├── baselines/                   # Core 候选/已接受 lock 与完整 file manifest
├── changes/
│   ├── <change-id>/
│   └── archive/
├── templates/change/
├── delivery/
├── planning/
└── references/
```

## 文件职责

| Artifact | 内容 | 是否可由执行 Agent 直接改 |
| --- | --- | --- |
| Constitution | 治理、安全、平台一致性和变更规则 | 否；必须经人类批准的 Core change |
| Current spec | WHAT/WHY、可观察行为、失败语义和 AC | accepted 后不可直改 |
| Contract/schema | 跨平台数据/接口的机器边界 | 不可绕过；语义变更走 Core change |
| Integration profile | HDC/OpenHarmony 工具语义、parser family 和 Adapter 输入 | 必须版本化、固定 hash；变更走 integration change |
| Platform profile | HOW：平台 API、UI、打包、签名和平台验证 | 可在已批准 platform change 内修改 |
| ADR | 为什么选择某种实现；append-only | 可新增，不得藏产品规则 |
| Change package | immutable proposal/delta/design/tasks/verification plan + append-only claim/run/result evidence | 运行态不回写已批准输入 |
| Task packet | 一个 Agent turn/PR 可闭环的执行单元 | V1 revision 固定为 1；范围变化生成新 Task ID，旧 Task 以 attested superseded run 终止 |

## 状态分离

```text
Spec:     draft → review → accepted → superseded | retired
Change:   proposed source → approved lock → claimed/implementing → verified result → archived
                              └→ superseded（唯一 approved successor；旧 claim 先终态）
Task:     draft → ready → in_progress → review → done
                                      └→ blocked | superseded
Platform lane (accepted lock): currentDelivery | notStarted
Platform conformance: notStarted | verified | needsReverification | nonConformant
Release claim: only exact approved release subject/cells of a verified profile are releasable
```

`done`、`accepted`、`verified` 不是同义词。代码写完不能替代规格接受或验收证据；Change 的 `superseded` 是由唯一 approved successor 推导的终态，不改写 predecessor proposal/Task packet。

## 生命周期与质量门

```text
Explore
  → Proposal
  → Spec Delta + Acceptance Scenarios
  → Design / ADR / Contract
  → Verification Plan
  → Review Gate
  → Tasks
  → Implement
  → Verify + Evidence
  → Archive and merge delta into living specs
```

- G0：Constitution 与 Core baseline 已接受。
- G1：范围和影响已批准。
- G2：每个 SHALL/SHALL NOT 都可测试且没有阻塞性 TBD。
- G3：Design 覆盖全部 Requirement，未引入 Core override。
- G4：每个 Task 固定 Requirement、AC、路径、依赖和验证。
- G5：所有适用 AC 有证据；没有降级测试或模拟冒充真机。
- G6：归档后 current specs、baseline、traceability 与实现一致。

## 需求格式

每个 Requirement 使用稳定 ID、规范句和至少一个验收场景：

```markdown
### Requirement: REQ-FLASH-005 Plan-only 零设备副作用

WHEN 用户运行真实 Flash Provider 的 plan-only，THE SYSTEM SHALL 生成完整计划，
AND SHALL NOT 派发任何 deviceMutation 或 destructive step。

#### Scenario: AC-FLASH-005-01 完整但不执行的计划

- GIVEN 一个包含 erase 和 flashPartition 的有效 Profile
- WHEN plan-only 成功完成
- THEN 两个步骤都出现在 plan Artifact 中并标记 notExecuted(planned)
- AND mutation runner 调用数为 0
```

每个独立规范子句都必须由至少一个 AC 覆盖；“Requirement 有一个 Scenario”只是结构下限，不能用一个象征性用例掩盖其余 SHALL。Safety coverage 由 `verification/core-conformance.yaml` 机器标记，并在同一 invariant 的 Requirement/AC 组合中覆盖正常、拒绝/失败和恢复或重启。单个 Requirement 不必机械重复三类场景，但套件不得缺少任何标记类别。模糊词不能作为验收条件。

## Integration 与跨平台一致性

`integrations/` 是共享 Adapter 输入，不是可随实现漂移的笔记。执行 Task 必须固定其 version/hash，且 profile/catalog/fixture 必须属于 accepted `INTEGRATION-PROFILES` lock；parser family、命令映射或能力判断变化创建 Integration change 和新 lock revision，不必伪装成 Core 语义变更。Core、Integration、Platform Profile、Conformance 是四条独立版本轴，Task 将它们组合固定。macOS、Windows 与 Linux 使用同一 Core 和同一被选 Integration/Conformance 输入；平台 Profile 只能补充 HOW 与平台测试，不能自行删减 AC 或声明 `notApplicable`。current delivery/not started 与 conformance 状态随 Platform lock revision 演进，不反向改写 Core。

## Agent 持续执行入口

每个新 Agent 按以下固定顺序工作：

1. 读取仓库根 `AGENTS.md`，运行 `scripts/check-sdd.sh`；
2. 只选择 approved supersession lineage 当前 head 中状态为 `ready/unclaimed`、hash pin 完整且已批准的 immutable Task packet；旧 Change 被 successor 批准后即使 packet bytes 仍为 `ready` 也不可领取；
3. 通过受保护 claim 服务原子取得符合 `task-claim.schema.json` 的 claim 和 exact owner attestation；受保护 CI 同时要求仓库外 identity ledger snapshot 收录全部 immutable identity，执行 Agent 不得自行生成该 snapshot；
4. 不改写 Task packet，只修改其允许路径，并把每次 attempt 写成 `task-run.schema.json` + 同 owner terminal attestation；controlled lab 还必须在真实设备 dispatch 前取得 typed plan 与 exact target 人类 authorization；
5. 将 AC 结果和 evidence 写入 change package；需要改变规则时停止并创建 delta，不能在实现任务中改 Core；
6. verification 通过不等于 Agent 可自行 archive；sync/archive 和 baseline ratification 仍需要人类批准。

当前 candidate baseline 的 execution gate 是 closed，因此这里只能继续审查 SDD，不能把 M0A Task 改为 `ready` 或开始产品实现。

`acceptance-index.txt` 固定完整 Core AC 集；`acceptance-cases.yaml` 为每条 Core AC 固定 Test ID、方法、规范期望来源和最低证据等级；change-local `acceptance-cases.yaml` 同样固定平台 AC。`core-conformance.yaml` 组合固定 Core cases、contracts、accepted Integration lock/catalog/fixture inputs。平台 Profile lock 与 Task packet 固定工程输入，不把 macOS/Windows/Linux API 选择或 parser fixture churn 混进 Core 语义版本。

## 旧计划

`docs/PLAN.md` 被保留为迁移依据。迁移覆盖关系记录在 `MIGRATION_MAP.md`；拆分完成后不得继续双写。

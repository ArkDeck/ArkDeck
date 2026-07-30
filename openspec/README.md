# ArkDeck Spec-Driven Development

> 模型:Living Specs + Change Packages(V2 git-native 治理)
> 状态:Core baseline CORE-2.0.0(ratification 状态见 `baselines/CORE-2.0.0.yaml`)
> 日期:2026-07-14

ArkDeck 使用一种工具中立的 SDD 结构:

- 借鉴 GitHub Spec Kit 的 Constitution、Spec → Plan → Tasks 和一致性检查;
- 借鉴 Kiro 的 EARS 式 Requirement 与 Given/When/Then 验收场景;
- 借鉴 OpenSpec 的 current specs、change delta 和 archive 作为长期演进模型。

核心选择是 **Living Spec**:`openspec/specs/` 描述当前候选或已接受的产品目标行为;design、tasks 和代码必须服从有效 baseline 与 approved delta。它不表示某项能力已经实现,实际可用性只能由 platform status、hardware matrix 和 verification evidence 证明。变更必须先形成 proposal 和 spec delta,通过验收后再合入 current specs。

治理与批准语义见 `governance/enforcement.md`:受保护 main + 维护者 PR review 是唯一信任根;CI 只做只读一致性校验。

## 目录

```text
AGENTS.md
openspec/
├── constitution.md
├── project.md
├── config.yaml
├── MIGRATION_MAP.md
├── architecture/                # system / platform-ports / core-portability / exclusive-resources
├── specs/                       # 当前有效、跨平台的行为规格
│   └── <capability>/spec.md
├── contracts/                   # 机器可校验的数据与 Provider 契约、capability registry、catalogs
├── governance/                  # enforcement.md(信任模型与 CI 校验)
├── integrations/                # OpenHarmony/HDC/工具的版本化 Adapter 输入
├── platforms/                   # 平台 profile 与交付状态(macos active;windows/linux future)
├── verification/                # policy / acceptance-index / acceptance-cases / traceability / hardware-matrix
├── baselines/                   # Core baseline 版本记录
├── changes/                     # change packages 与 archive/
├── templates/change/
├── delivery/                    # roadmap
├── planning/                    # backlog / open-questions / postmortem
└── references/
```

## 文件职责

| Artifact | 内容 | 是否可由执行 Agent 直接改 |
| --- | --- | --- |
| Constitution | 治理、安全、平台一致性和变更规则 | 否;经维护者批准的 Core change |
| Current spec | WHAT/WHY、可观察行为、失败语义和 AC | 否;经 approved change delta 合入 |
| Contract/schema | 跨平台数据/接口的机器边界 | 否;语义变更走 Core change |
| Integration profile | HDC/OpenHarmony 工具语义、parser family 和 Adapter 输入 | 版本化;变更走 integration change |
| Platform profile | HOW:平台 API、UI、打包、签名和平台验证 | 可在已批准 platform change 内修改 |
| ADR | 为什么选择某种实现;append-only | 可新增,不得藏产品规则 |
| Change package | proposal/delta/design/tasks/verification + evidence | 状态转换经 PR review 生效 |

## 状态

```text
Spec:     draft → review → accepted → superseded | retired
Change:   proposed → approved → implementing → verified → archived(└→ rejected)
Task:     ready → in_progress → done(└→ blocked)
Platform: notStarted | verified | needsReverification | nonConformant
```

`done`、`accepted`、`verified` 不是同义词。代码写完不能替代规格接受或验收证据。

## 生命周期与质量门

```text
Explore → Proposal → Spec Delta + Acceptance Scenarios → Design/ADR/Contract
  → Verification Plan → Review Gate → Tasks → Implement → Verify + Evidence
  → Archive and merge delta into living specs
```

- G0:Constitution 与 Core baseline 已接受。
- G1:范围和影响已批准。
- G2:每个 SHALL/SHALL NOT 都可测试且没有阻塞性 TBD。
- G3:Design 覆盖全部 Requirement,未引入 Core override。
- G4:每个 Task 明确 Requirement、AC、路径、依赖和验证。
- G5:所有适用 AC 有证据;没有降级测试或模拟冒充真机。
- G6:归档后 current specs、baseline、traceability 与实现一致。

## 需求格式

每个 Requirement 使用稳定 ID、规范句和至少一个验收场景:

```markdown
### Requirement: REQ-FLASH-005 Plan-only 零设备副作用

WHEN 用户运行真实 Flash Provider 的 plan-only,THE SYSTEM SHALL 生成完整计划,
AND SHALL NOT 派发任何 deviceMutation 或 destructive step。

#### Scenario: AC-FLASH-005-01 完整但不执行的计划

- GIVEN 一个包含 erase 和 flashPartition 的有效 Profile
- WHEN plan-only 成功完成
- THEN 两个步骤都出现在 plan Artifact 中并标记 notExecuted(planned)
- AND mutation runner 调用数为 0
```

每个独立规范子句都应由 AC 覆盖;"Requirement 有一个 Scenario"只是结构下限,不能用一个象征性用例掩盖其余 SHALL。模糊词不能作为验收条件。

`acceptance-index.txt` 固定完整 Core AC 集;`acceptance-cases.yaml` 为每条 Core AC 登记方法与最低证据等级。CI 校验三方 ID 集合精确一致。

## Integration 与跨平台一致性

`integrations/` 是共享 Adapter 输入,不是可随实现漂移的笔记。parser family、命令映射或能力判断变化创建 integration change 和新 profile 版本,不必伪装成 Core 语义变更。macOS、Windows 与 Linux 使用同一 Core;平台 Profile 只能补充 HOW 与平台测试,不能自行删减 AC 或声明 `notApplicable`。

## Agent 执行入口

1. 读取仓库根 `AGENTS.md`,运行 `scripts/check-sdd.sh`;

> **SDD checker 运行时(TASK-SDR-001)**:`check-sdd.sh` 按
> `ARKDECK_PYTHON` → 当前 checkout `.venv-sdd` → 同一 Git repository
> 主 checkout 的共享 `.venv-sdd`(git common-dir 推导)→ PATH `python3`
> 选择解释器;选中候选 preflight(PyYAML exact pin)失败即 fail closed,
> 不静默降级。checker 本身零安装、零联网、零仓库写入。**每台机器首次
> 使用前人工运行一次 `scripts/bootstrap-sdd.sh`**(在主 checkout 创建
> ignored `.venv-sdd` 并安装 `scripts/requirements-sdd.txt`;checker
> 只提示、永不调用它)。
2. 读取仓库根 `PRODUCT-LOOP.md`,确认当前阻塞最高优先级 Golden Journey 的产品缺陷;
3. 按 `PRODUCT-LOOP.md` §4 组装一个垂直产品任务(根因 + 产品代码修复 + 必要测试 +
   适用时真机验证 + 最小文档更新);仅安全内核治理(恰四类 Repo 审批与
   `PRODUCT-LOOP.md` §3 安全条件)才进入 change package 流程;
4. 真实运行结果随交付 PR 如实记录(simulation/fake 不得记为真实设备结果);
   不能在实现中放宽 Constitution 安全不变量;
5. 通过 `agent/**` 分支 → PR → 维护者 review 合入。产品 PR 的任务声明仅作
   `check_pr_paths` 路径护栏,不触发治理连锁义务(见 `PRODUCT-LOOP.md` §16)。

> 兼容注记(2026-07-30):原步骤 2「选择 ready 任务」与步骤 4「更新 tasks.md
> 状态」自产品闭环优先阶段起对产品工作不再适用,仅在安全内核治理 change 内保留。

## 旧计划

`docs/PLAN.md` 被保留为迁移依据。迁移覆盖关系记录在 `MIGRATION_MAP.md`;拆分完成后不得继续双写。

# ArkDeck Agent Guide

本文件保留全局边界、完成标准与按需入口。目标是完成用户当前任务，交付可验证的产品结果。

## 工作方式

- 明确目标行为与完成条件后，直接完成实现、必要验证和最小文档更新。普通修复不因旧 Task
  blocked、缺少 readiness 或历史 change 未归档而停止，也不拆成状态类 PR。
- 按当前请求确定范围；常规实现选择自行判断。只有缺失信息会实质改变范围、正确性或未获
  授权的副作用时才提问，同时继续独立工作。沿用会话中已有授权。
- 先检查 diff 并保留用户修改，定位相关实现、测试和任务，再读取下表对应资料；不通读全部
  specs、change 或 skills，也不重复加载未变内容。历史命令、版本和状态与当前实现核对。
- 使用用户的语言，简要说明实际修改、验证与阻塞。产品迭代按 `PRODUCT-LOOP.md` §19
  汇报；完成即交付，不主动追加治理、重构、无关功能或为“下一轮建议”制造任务。

## 按任务读取与权威顺序

| 任务 | 入口 |
| --- | --- |
| 产品能力与优先级 | [PRODUCT-LOOP.md](PRODUCT-LOOP.md) 对应 Golden Journey；`Packages/ArkDeckKit/Sources/`、`ArkDeckApp/` |
| Operation、Runtime、Provider、Artifact | 对应 `openspec/specs/`、`openspec/contracts/`、`Catalog/` 与 integration/platform profile |
| 身份、副作用准入、恢复、隐私 | [Constitution](openspec/constitution.md) 对应 Safety invariant / `POL-*`，再读相关 contract |
| 新 operation 或已发布 operation 的破坏性修改、新 provider、新 integration/device profile、destructive 准入安全策略变化 | 同车 OpenSpec change + 维护者 PR review；读取 [enforcement](openspec/governance/enforcement.md)、[verification policy](openspec/verification/policy.md) 与所属 change |
| 真机验收已发布 operation，或验收 App 呈现 | [验收指南](scripts/agent-guides/acceptance.md) |
| 准备 commit、push、创建或更新 PR | [提交指南](scripts/agent-guides/contributing.md)；提交前读取 |
| 维护 AGENTS.md、项目 skill 或排查指令冲突 | [指令维护](scripts/agent-guides/instructions.md) |

表中操作指南仅在命中对应任务时读取，是本文件的按需说明；无需预先加载全部链接。
仓内资料冲突时：Constitution Safety invariants / `POL-*` > `PRODUCT-LOOP.md` > 本文件及其操作指南 >
current specs/contracts 与 approved scoped delta > integration/platform profile >
enforcement/policy 与 change 设计 > 代码和注释。`docs/PLAN.md` 仅是历史设计输入。

安全不变量冲突时停止受影响的危险推进，给出条款与冲突，交维护者裁决；普通流程冲突按
`PRODUCT-LOOP.md` 执行并记录一行兼容说明，不自动创建 change。其他同层冲突采用对当前
Golden Journey 风险最小的解释并说明。旧 E0/E1/E2 或确认流程不得覆盖 `POL-AGENT-002`
的现行 Runtime authority 规则。

## Agent 禁令与设备执行边界

- Repo Agent 修改代码与测试；Device Runtime 只执行 protected `main` 已发布 Catalog 的
  typed operation。每次设备运行只产生 Runtime 记录，不要求 Git task/PR、changeId、ready
  packet 或每轮聊天确认。
- 设备操作仅提交 operation reference、typed inputs、target/artifact/capability reference
  与预算；不绕过 Provider 执行 raw HDC、刷机命令、raw shell 或任意远端路径。此限制针对
  设备执行面，不禁止 Repo Agent 使用本地主机命令编辑、构建和测试。Provider lowering
  使用 executable + argument array；device-scoped HDC 绑定精确目标。
- `hostOnly`/`readOnly` 使用 bounded 默认只读准入；`deviceMutation`/`destructive` 仅由
  protected-main Runtime 根据 fresh trusted facts 与完整 materialized plan 生成、reserve、
  consume 精确匹配的 RuntimeCapability。Agent、caller、candidate、repairer 不得创建、修改、
  扩大或管理 capability、trusted facts、reservation/outcome/supersession record、Provider
  coverage declaration 或 hardware evidence。
- 身份或副作用结果不确定时 fail closed；unknown intent 永不 replay。只有
  `POL-RECOVERY-001` 的完整机械证明成立，Runtime 才可发起独立 complete-overwrite recovery；
  缺失证明时零新 dispatch，用户确认不能代替证明。
- 不为通过测试放宽 accepted Core requirement、Safety invariant 或 Acceptance Scenario，
  不自行标记 approved/verified。语义变更经相应 change 与维护者 review；平台不满足 Core
  时标记 blocked/nonConformant 或不发布，不创建平台豁免。
- candidate/repairer 是 Runtime 隔离角色：candidate 仅在 task-owned isolation build/test；
  repairer 不接触 source workspace；两者不接触 transport、Runtime、raw shell 或 capability
  admin。`scripts/host_loop` 只领取 `Hardware required:no` 的 D0 Repo 任务，不执行设备 job。
- Raw Artifact 不原地修改，派生处理保留来源；默认本地保存，导出由用户发起，secret 不写入
  日志或 evidence。fake、fixture、simulation、plan-only 不能充当真机验收；
  `REAL_DEVICE_PASS` 只用于当前 Catalog digest 上的真实设备结果。

## 验证与完成

开发时用针对性检查验证可观察行为与关键失败路径。修改 `Catalog/**`、`openspec/contracts/**`
或生成物时保持 schema、generator vocabulary/pins、Swift validator 与 contract tests 一致。
最终本地验证在仓库根目录运行统一入口：

```bash
python3 scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

它执行公共检查，再按完整 diff 选择 Swift、App build-for-testing、design-system、Rust 测试；
可信 base 不可得时选择全部车道。`--filter`/`--skip-build` 仅用于开发反馈。
通过后，仅因新改动、失败或未解决风险扩大或重复测试。未执行检查及原因如实写入交付说明。

protected `main` 的 required status checks 是 SDD Guard 的 `guard` 与 Swift CI 的 `swift` 聚合
job（后者始终上报，被选中的车道任一失败即失败）。这是 GitHub 分支保护设置而非仓内文件，
用 `gh api repos/ArkDeck/ArkDeck/branches/main/protection/required_status_checks/contexts`
核对；两者缺一，CI 红就挡不住合入。CI 绿只表示验证通过，不构成维护者批准。

使用用户指定或任务所需的 skill，读取 `SKILL.md` 后仅加载相关 references；用户明确要求优先于 skill 流程建议。
若指令导致暂停，链接具体文件、引用条款并说明缺口，区分要求与自身解释。

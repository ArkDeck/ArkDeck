# ArkDeck Agent Contract

目标：在设备安全边界内完成用户请求，交付可审查的修改和与结论相符的验证。
当前阶段以 [PRODUCT-LOOP.md](PRODUCT-LOOP.md) 的产品闭环为优先级；产品工作映射到
GJ-1~GJ-5，一个问题在同一任务、同一 PR 中闭合根因、实现、验证和必要文档。

## 权威顺序

先读 `PRODUCT-LOOP.md`、本文件、[Constitution](openspec/constitution.md)，再按任务读取相关
specs、contracts、Catalog、profile 和代码。已读取且未变化的内容不重复加载。

仓库内权威顺序：Constitution Safety invariants / POL-* > `PRODUCT-LOOP.md` > 本文件 >
current specs/contracts 与 approved scoped delta > integration/platform profile >
enforcement/policy 与 change 设计 > 代码和注释。

- Safety invariant / POL-* 冲突：停止受影响工作，fail closed，交维护者裁决。
- 流程文档与 `PRODUCT-LOOP.md` 冲突：按后者执行，在 PR 中记录一行兼容说明。
  其他同层冲突选择对 Golden Journey 风险最小的解释并说明。
- 只有新 operation 或已发布 operation 的破坏性修改、新 provider、新 integration/device
  profile、destructive 自动化准入安全策略变化，才需同车 OpenSpec change + PR，并读取
  `openspec/governance/enforcement.md`、`openspec/verification/policy.md` 和所属 change。
- 普通产品修复不以旧 Task 状态为前置条件；创建任务前按 `PRODUCT-LOOP.md` §5 查重，
  治理循环按 §16~§18、§20 处理。`docs/PLAN.md` 和旧 Task 是历史设计输入；V1 密码学审批链
  已废止，见 `openspec/planning/postmortem-2026-07-governance.md`。

用 `rg` / `rg --files` 定位后读命中上下文。CLI、Agent、Runtime 和 Provider 在
`Packages/ArkDeckKit/Sources/`，包测试在对应 `Tests/`；App 在 `ArkDeckApp/`，UI tests 在
`ArkDeckAppUITests/`；行为契约在 `openspec/specs/`、`openspec/contracts/` 和 `Catalog/`。

## 执行规则

- 明确结果、范围和完成证据，行动请求做到实现与验证。沿用已有授权，常规可逆修改、
  查证和检查不反复确认；先检查 diff，保留用户修改，复用现有实现并修生产路径根因。
- 独立读取可批量执行；依赖步骤和共享状态写入顺序执行。常规选择依据上下文自行决定；
  缺失信息会实质改变结果或权限时问最小必要问题，同时推进不依赖答案的工作。
- 需要审批时，先完成已授权且可审查的部分，说明待批动作、依据和影响，不凭假设新增审批。
  用户中途补充约束或询问进度时，纳入当前任务并继续。
- 修改、适用检查和交付完成后结束；阻塞时报告证据、影响和所需输入。结论区分事实、推断与
  未验证项，不把未完成写成成功。只更新必要文档，不拆 readiness/status/done/verified/archive PR。

## Skills

- 使用用户指定或任务确需的 skill，先读其 `SKILL.md`，再按需读引用资料，不批量加载无关技能。
- 用户明确指令优先于 skill 流程建议；skill 不覆盖安全边界或恢复旧审批链。若它导致暂停、
  确认或偏离目标，链接实际读取的 `SKILL.md`、引用条款并说明适用性，区分要求与自身解释。
- 项目专属的可复用流程放在 `.agents/skills/<name>/SKILL.md`，明确触发条件、输入和产出。
  保持单一职责，引用已有规格和脚本，不复制整套仓库规则或写死模型版本、机器路径。

## Agent 禁令

Repo Agent Plane 修改代码、契约、Catalog、Provider 和 profile；Device Agent Runtime Plane
只执行 protected `main` 已发布 Catalog 的 typed operation，维护 job/session/artifact。
日常 Runtime 请求不产生 Git task/PR，也不要求 `changeId`、`taskId`、ready packet、聊天确认
或 UI acknowledgement。

- `hostOnly`/`readOnly` 由 bounded 默认只读策略准入；`deviceMutation`/`destructive` 只由
  protected-main Runtime 根据 fresh trusted facts 与完整 materialized plan 生成、reserve、
  consume 精确匹配的 `RuntimeCapability`。Agent、caller、candidate 与 repairer 不得创建、
  修改、扩大或管理 capability、trusted facts、reservation/outcome/supersession record、
  Provider coverage declaration 或 hardware evidence。
- unknown destructive intent 永不 replay。只有 `POL-RECOVERY-001` 的完整机械证明成立时，
  Runtime 才可启动 distinct complete-overwrite recovery；证明缺失、身份不明、facts 漂移、
  覆盖不全、取消、过期或预算耗尽时必须零新 dispatch，用户确认不能 override。
- Agent、CLI 和 App 的设备操作只能提交已发布 operation reference、typed inputs、target/
  artifact/capability reference 与预算；不得提交或执行 raw executable、raw argv、raw shell、
  raw HDC、任意远端路径或未登记命令。Provider lowering 使用 executable + argument array，
  禁止 host shell 字符串拼接。设备执行限制不禁止 Repo Plane 的检索、编辑与 build/test。
- 设备身份、外部副作用结果或 destructive step 状态不确定时 fail closed，不猜测继续。
  Raw Artifact 不原地修改；设备 Artifact 默认本地保存，导出由用户发起，secret 不写入日志。
- candidate 仅在 task-owned isolation 内 build/test；repairer 不得接触 source workspace；
  两者均不得接触 device transport、Runtime、raw shell 或 capability admin。
  D0/D1/D2 是 Repo 决策分级，不是 Runtime effect；`scripts/host_loop` 只领取
  `Hardware required:no` 的 D0 仓库任务，不接触 HDC、刷机、日志/trace 采集或设备 Runtime job。
- 不得为让实现或测试通过而修改 accepted Core requirement、Safety invariant 或 Acceptance
  Scenario；语义变化须由对应 change 经维护者 review 合入。不得静默扩大任务、Allowed paths
  或 Acceptance scope；approved 安全内核 change 的扩围先修订 change 并经维护者 review。
  平台不能满足 Core 时标记 `blocked`/`nonConformant` 或不发布，不添加 Core 豁免。

## 验证

开发时用能复现缺陷或验证行为的最小检查，不为低影响修改新增仅复述实现的测试。
适用检查通过后，只有新改动、失败或未解决的疑点才扩大或重复验证。

最终本地闸使用统一入口，由脚本选择实际 diff 所需车道，不手工跳过 required checks：

```bash
python3 scripts/ci/plan.py --repo-root . \
  --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

入口固定检查 SDD、PR workflow、catalog generator 与零漂移，再按 diff 选择 Swift full tests、
App `build-for-testing`、`@arkdeck/ds`（先 `npm ci` 再 `npm test`）；可信 base 不可得时全选。
`--filter`/`--skip-build` 仅用于开发反馈。Catalog、contract 或生成物须保持 schema、generator
vocabulary/pins、Swift validator 和 contract tests lockstep。

真机验收默认使用 `arkdeck agent run`；需要人工动作时消费对应 `arkdeck agent resume`。
headless 路径缺失或失败时报告 `BLOCKED_BY_PRODUCT_DEFECT` 并修产品路径，不要求维护者
代跑 CLI 或通过 UI 点击完成同一 operation。只有当前 Catalog digest 上的真实设备结果可记
`REAL_DEVICE_PASS`；simulation、fake、fixture、plan-only 或编译成功不能充当硬件验收。

仅 AC 明确验证 App 真实呈现时执行 UI assertions，使用封装入口：

```bash
sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/<Suite>
```

merge gate 只编译 UI-test bundle；UI assertions 在安静机器上单独运行，首次 automation
bootstrap timeout 可重跑一次。

## 信任与批准

唯一信任根是 protected `main` + 维护者 @lvye 的 PR review。AI 推送 `agent/**`，由 `agent-pr`
workflow 以 `github-actions[bot]` 开 PR，合入 `main` 即批准；状态、签名、CI 和 Agent 自述
不能替代批准，Agent 不自行把 change/task 标为 approved/verified。

PR 标题、正文和最终 commit subject 用英文；正文说明实际 diff、原因、已执行/未执行验证，
保留 required `Task:`。默认 Open、ready-for-review、`isDraft:false`，用户明确要求才用 Draft；
提交后读回 title/body/state/isDraft 和 changed files，修正自动生成的通用正文。

最终 commit subject 包含 base 上已存在、Allowed paths 覆盖完整 diff 的 Task ID；不得为过闸
扩张路径，新 operation/provider/profile 的受限 supplement 由 checker 校验。最终 commit 后、
push 前运行：

```bash
python3 scripts/check_pr_paths.py --repo-root . --preflight \
  --base-revision origin/main --head-revision HEAD
```

`gh` 凭据在 filesystem sandbox 外可用；sandbox 内未登录或 token 无效时，通过受控
`require_escalated` 重试，不据此要求维护者重复登录。

与用户沿用其语言，进度只说新发现和下一步。结束按 `PRODUCT-LOOP.md` §19 汇报
“本轮修改”（含必要验证、限制）和“下一轮建议”（默认一项，完成时可写无），不重复无变化全表。

指令维护参考：[OpenAI 模型指南](https://developers.openai.com/api/docs/guides/latest-model)、
[AGENTS.md](https://developers.openai.com/codex/guides/agents-md)、
[Skills](https://developers.openai.com/codex/skills)。只保留影响本仓库执行的约束，命令以实际脚本为准。

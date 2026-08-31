# ArkDeck Agent Contract

本文件是 AI Agent、自动化工具和人工贡献者进入 ArkDeck 仓库后的执行入口。

> **当前阶段:产品闭环优先。**执行优先级、Golden Journey 和工作方式以
> `PRODUCT-LOOP.md` 为准；安全边界以 Constitution 的 Safety invariants / POL-* 为准。
> V1 密码学审批链已经废止，历史与事故记录见
> `openspec/planning/postmortem-2026-07-governance.md`。

## 必读与权威顺序

按以下顺序读取：

1. `PRODUCT-LOOP.md`；
2. 本文件；
3. `openspec/constitution.md`；
4. 当前工作涉及的 living specs、contracts、`Catalog/`、integration/platform profile
   与代码；
5. 仅当工作属于下文四类安全内核治理时，再读
   `openspec/governance/enforcement.md`、`openspec/verification/policy.md` 与所属 change。

发生冲突时，权威顺序为：Constitution Safety invariants / POL-* >
`PRODUCT-LOOP.md` > 本文件 > current specs/contracts 与 approved scoped delta >
integration/platform profile > enforcement/policy 与 change 设计 > 代码和注释。

- 涉及 Safety invariant / POL-* 的冲突：停止受影响工作，fail closed，交维护者裁决；
- 流程文档与 `PRODUCT-LOOP.md` 冲突：按 `PRODUCT-LOOP.md` 执行，在 PR 中记录一行
  兼容说明，不自动创建 change；
- 其他同层冲突：选择对 Golden Journey 推进风险最小的解释并在 PR 中说明。

`docs/PLAN.md` 是历史设计输入，不是实现规则的事实源。本文件只保留日常执行边界；
destructive admission、recovery、identity、Artifact 和隐私协议的完整定义只在上述权威文件
维护，不在此复制。

## 控制平面与信任模型

- **Repo Agent Plane** 修改代码、contracts、`Catalog/`、provider、profile 与安全策略。
  只有四类变化必须同车提交 OpenSpec change + PR：新 operation 或已发布 operation 的
  破坏性修改、新 provider、新 integration/device profile、destructive 自动化准入安全策略
  变化。普通 Golden Journey 产品缺陷不需要新 change、readiness 或状态 PR。
- **Device Agent Runtime Plane** 只执行 protected `main` 已发布 Catalog 中的 typed
  operation，维护 job/session/artifact。每次运行只产生 Runtime 记录，不产生 Git task/PR，
  也不要求 `changeId`、`taskId`、ready packet、聊天确认或 UI acknowledgement。
- `hostOnly`/`readOnly` 由 bounded 默认只读策略准入；`deviceMutation`/`destructive` 只由
  protected-main Runtime 根据 fresh trusted facts 与完整 materialized plan 生成、reserve、
  consume 精确匹配的 `RuntimeCapability`。Agent、caller、candidate 与 repairer 不得创建、
  修改、扩大或管理 capability、trusted facts、reservation/outcome/supersession record、
  Provider coverage declaration 或 hardware evidence。
- unknown destructive intent 永不 replay。只有 Constitution `POL-RECOVERY-001` 的完整机械
  证明成立时，Runtime 才可启动 distinct complete-overwrite recovery；缺失证明、身份不明、
  facts 漂移、覆盖不全、取消、过期或预算耗尽时必须零新 dispatch，且用户确认不能 override。
- D0/D1/D2 是 Repo Plane 的决策分级，不是 Runtime effect 等级。`scripts/host_loop` 只领取
  `Hardware required:no` 的 D0 仓库任务，不得接触 HDC、刷机、日志/trace 采集或任何设备
  Runtime job；产品缺陷由交互式 Agent 会话直接处理。

唯一信任根是受保护的 `main` + 人类维护者（@lvye）的 PR review。AI 起草的变更推送
`agent/**` 分支，由 `agent-pr` workflow 以 `github-actions[bot]` 开 PR；合并进 `main` 即批准。
仓库文件、状态字段、签名、CI 结果或 Agent 自述均不能替代维护者批准，Agent 不得自行把
change/task 标为 approved/verified。

## Agent 禁令

- 不得为让实现或测试通过而修改 accepted Core requirement、Safety invariant 或 Acceptance
  Scenario；此类语义变化必须由对应 change 经维护者 review 合入。
- Agent、CLI 和 App 只能提交已发布 operation reference、typed inputs、target/artifact/
  capability reference 与预算；不得提交或执行 raw executable、raw argv、raw shell、raw HDC、
  任意远端路径或未登记命令。Provider lowering 必须使用 executable + argument array，禁止
  host shell 字符串拼接。
- 不得把 simulation、fake、fixture 或 plan-only 结果记为真实设备或硬件验收。
- 设备身份、外部副作用结果或 destructive step 状态不确定时必须 fail closed，不得猜测继续。
- candidate 仅可在 task-owned isolation 内 build/test；repairer 不得接触 source workspace；
  两者均不得接触 device transport、Runtime、raw shell 或 capability admin。
- 不得静默扩大任务、Allowed paths 或 Acceptance scope；确需改变 approved 安全内核 change
  的范围时，先修订其 change 并经维护者 review。
- 平台不能满足 Core 时标记 `blocked`/`nonConformant` 或不发布，不得把平台限制写成 Core
  豁免。

## 执行规则

- **Golden Journey 是唯一进度指标。**产品工作映射到 GJ-1~GJ-5；只有当前 Catalog digest
  上的真实设备结果可记 `REAL_DEVICE_PASS`。每轮结束按 `PRODUCT-LOOP.md` §19 只汇报
  “本轮修改”和“下一轮建议”，不重复无变化的全表。
- **一个问题 = 一个垂直产品任务 = 一个 PR。**同一 PR 包含根因、产品代码、必要测试、
  适用的真实设备验证、最小文档更新与完成结论；不得拆出 readiness/status/done/verified/
  archive-only PR。
- **真机验收默认走 Agent/CLI。**验证已发布 operation、Runtime、Provider、binding、Job、
  journal 或 Artifact 时直接使用 `arkdeck agent run`；需要人工动作时只消费对应
  `arkdeck agent resume`。只有 AC 明确验证 App 呈现时才运行 App/UI。headless 路径缺失或
  失败应报告 `BLOCKED_BY_PRODUCT_DEFECT` 并修产品路径，不得要求维护者代跑 CLI 或回退到
  UI 点击完成同一 operation 验收。
- **PR 内容使用英文。**PR 标题和正文必须用英文；Agent 分支的最终 commit subject 也用英文，
  因为 workflow 会用它生成标题。与用户的对话不受此限制，沿用用户使用的语言。PR 正文必须
  概括实际 diff、原因与已执行或明确未执行的验证，并保留 required `Task:` 声明；branch 名或
  自动生成的通用文字不能替代修改说明。默认提交 Open、ready-for-review、`isDraft:false` 的
  PR，只有用户明确要求时才使用 WIP/Draft。提交后读回 title/body/state/isDraft 与 changed files。
- **push 前闭合 Task 和路径声明。**`agent/**` 最终 commit subject 必须包含 base 上已存在、
  Allowed paths 覆盖完整 diff 的 Task ID。不得为通过门禁扩张路径；新 operation/provider/
  profile 的受限自描述 supplement 由 checker 机械校验，不得自行放宽。最终 commit 后、push 前运行：

  ```bash
  python3 scripts/check_pr_paths.py --repo-root . --preflight \
    --base-revision origin/main --head-revision HEAD
  ```

- **最终本地闸只使用统一入口。**它固定运行 SDD、PR workflow tests、catalog generator tests
  与零漂移检查，再按实际 diff 选择 ArkDeckKit full tests、App `build-for-testing` 与
  `@arkdeck/ds` interaction tests（后者先 `npm ci` 再 `npm test`，跳过安装会得到误导性的
  局部通过）；可信 base 不可得时 fail closed 选择全部车道。`--filter`/`--skip-build`
  只能用于开发反馈。

  ```bash
  python3 scripts/ci/plan.py \
    --repo-root . \
    --base-revision origin/main \
    --head-revision HEAD \
    --merge-base \
    --include-worktree \
    --run-local
  ```

- **UI assertions 不属于 merge gate。**`swift-ci.yml` 只编译 UI-test bundle；nightly
  `swift-slow-lanes.yml` 会执行大部分 UI tests。当前 AC 需要验证 App 真实呈现时，使用封装了
  签名、独立 DerivedData 和 runner 清理的本地入口，不要手写 `xcodebuild test`：

  ```bash
  sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/<Suite>
  ```

  UI tests 对负载敏感，应在安静机器上单独运行；首次 automation bootstrap timeout 可重跑一次。
- 改动 `Catalog/**`、`openspec/contracts/**` 或生成物时，必须保持 schema、generator
  vocabulary/pins、Swift validator 与 contract tests lockstep。
- 创建新任务、处理旧 Task 或怀疑进入治理循环时，直接按 `PRODUCT-LOOP.md` §2、§5、
  §16~§18、§20 执行；旧 OpenSpec Task 是历史设计记录，不因其 blocked 状态停止当前产品修复。

## 工具环境

本项目的 GitHub CLI（`gh`）凭据在 filesystem sandbox 外可用。若 sandbox 内
`gh auth status` 报未登录或 token 无效，应通过受控 `require_escalated` 在 sandbox 外重试，
不得据此要求维护者重复登录。

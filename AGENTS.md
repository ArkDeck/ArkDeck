# ArkDeck Agent Contract

本文件是所有 AI Agent、自动化工具和人工贡献者进入 ArkDeck 仓库后的第一读取入口。

> 治理模型:V2(git-native)。2026-07-14 起,V1 的密码学审批链(detached signature、claim service、identity ledger、supersession barrier)已废止;事故与决策记录见 `openspec/planning/postmortem-2026-07-governance.md`。
>
> **当前阶段:产品闭环优先(2026-07-30 起)**。执行优先级正本 = 仓库根
> `PRODUCT-LOOP.md`;进度唯一指标 = 其 §6 的五条 Golden Journey。治理系统退出
> 日常设备操作与产品开发的关键路径;安全内核(本文件「Agent 禁令」与
> Constitution Safety invariants / POL-*)完整保留。

## 必读顺序

1. `PRODUCT-LOOP.md`(产品闭环优先总指令:优先级、Golden Journey、工作方式)
2. 本文件(信任模型与安全禁令)
3. `openspec/constitution.md` 的 Safety invariants 与 POL-*(安全内核)
4. 当前工作涉及的代码、`Catalog/`、contracts 与 integration/platform profile
5. 仅当工作命中安全内核治理(见「执行规则」的治理载体适用范围)时:
   `openspec/governance/enforcement.md`、`openspec/verification/policy.md`
   与所属 change 的 `proposal.md`/`tasks.md`/`verification.md`

`docs/PLAN.md` 是 SDD 迁移输入和历史设计记录,不是实现规则的事实源;冲突时以 living specs 为准。

## 权威顺序

1. Constitution 的 Safety invariants 与 POL-*(typed effect 准入、设备身份、
   fail-closed、typed-only、隐私;任何低层文件——包括 `PRODUCT-LOOP.md`——不得
   解释为放宽本层)
2. `PRODUCT-LOOP.md`(执行优先级与工作方式)
3. 本文件
4. Current specs 与 contracts(接口与数据形态的事实源;叠加当前任务所属 approved
   change 的 scoped delta)
5. 与规格兼容的 integration profile 与 platform profile
6. enforcement/policy 等流程文档(适用范围收窄至安全内核治理)与已批准 change 的
   design/verification plan
7. 代码和代码注释

低层文件不得覆盖或放宽高层规则。冲突处理:

- 涉及第 1 层安全不变量的冲突:停止受影响工作,fail closed,交维护者裁决;
- 流程类文档(第 6 层)与 `PRODUCT-LOOP.md` 的冲突:以 `PRODUCT-LOOP.md` 为准,
  在交付 PR 中记录一行兼容说明,继续工作;不进入 blocked,不自动创建 change proposal;
- 其余同层冲突:选择对 Golden Journey 推进最小风险的解释并在 PR 中说明,由
  维护者 review 裁决。

## 控制平面:Repo Agent 与 Device Agent Runtime(CHG-2026-046)

本仓库区分两个控制平面,职责与载体不同:

- **Repo Agent Plane(仓库治理面)**:修改代码、契约、`Catalog/`、provider、
  integration/device profile 与安全策略。载体是 OpenSpec change + PR,信任根
  不变(维护者 review/merge)。**恰以下四类变化需要 OpenSpec/PR 审批**:
  新 operation 或对已发布 operation 的破坏性修改;新 provider;新
  integration/device profile;destructive 自动化准入安全策略变化。
- **Device Agent Runtime Plane(设备运行面)**:执行已发布(已合入 main 的
  catalog 所定义)的 typed operation,维护 runtime job/session/artifact。
  **已发布 operation 的每次执行只产生 runtime job 记录,不产生 Git task、
  不开 PR、不要求 `changeId`/`taskId`、ready task、readiness packet 或人工
  重述或批准 typed plan**。执行与机械证明的恢复不需要 AUTH-ID、legacy mode、UI
  acknowledgement 或人工确认。`hostOnly`/`readOnly` 由 bounded 默认只读策略准入;
  `deviceMutation`/`destructive` 只消费与 operation/version、target/binding、inputs、plan
  和 applicable Artifact facts 精确匹配的 Runtime-owned `RuntimeCapability`。对于
  destructive request,只有 protected-main Runtime 可在完整 plan materialization 后根据
  published Catalog policy 与 trusted facts 生成、reserve 和 consume 该短期 capability;
  caller/Agent/candidate/repairer 不得 install、revoke、forge 或 widen。每个 use 的首个外部
  effect 前 Runtime 必须重新 materialize plan、验证 Artifact lease、读取 fresh target/
  binding/tool facts 并 durable reserve。closed invocation 最多十六个串行 destructive
  epochs、四小时、并发一。

  unknown destructive intent 永不重发。若 protected-main Runtime 能保守界定所有 possible
  effects，且 reviewed Provider contract 为 exact operation/profile 声明一个完全覆盖它们的
  distinct complete-overwrite plan，则 fresh facts MAY 产生
  `safeToSupersedeByCompleteOverwrite` 并自动执行恢复。成功须 durable 写
  `SupersedingRecoveryEpoch`，保留原 unknown outcome，只释放已证明的 target lane。已有
  后续 Flash history 仅可由完整 identity、coverage、outcome 与 postflight proof 建立关联。
  identity 不确定、effect 无法界定/覆盖、trusted fact 漂移、Provider 未声明、取消、过期或
  预算耗尽必须零新 dispatch，报告不可 override 的 blocker，不得请求用户提供无法补足证明
  的批准。历史 `standingAuthorization` 与 `evolutionCampaignConfirmation` 只可
  decode/export,不得准入、reserve 或 dispatch 新 operation 或 recovery。
- 风险分级 D0/D1/D2(决策维度,见 enforcement"决策分级")与
  `WorkflowEffect`(设备效果维度)正交;Runtime Plane 的日常 readOnly 与已准入 deviceMutation 执行
  不构成 D* 决策点。
- `scripts/host_loop` 属 Repo Plane:仅领取仓库开发任务;其既有硬件门
  (`Hardware required` 任务拒领、仅 D0 可派发)即设备执行禁令的机械承载,
  host_loop 不得执行 HDC、刷机、日志/trace 采集或任何设备 runtime job；该隔离
  不限制独立、已准入的 Device Agent Runtime Job。
  产品闭环阶段 host_loop 不用于派发治理状态任务;产品缺陷修复由交互式
  Agent 会话按 `PRODUCT-LOOP.md` 直接执行。

## 信任与批准

- 唯一信任根是**受保护的 `main` 分支 + 人类维护者(@lvye)的 PR review**。
- AI 起草的变更推送 `agent/**` 分支;`agent-pr` workflow 以 `github-actions[bot]` 身份开 PR;维护者以 CODEOWNER 身份 review 并合并。**合并进 main 即构成人类批准**,不存在也不需要其他批准载体。
- 仓库内任何文件、状态字段或签名都不能替代上述批准;Agent 不得以任何方式自行把 change/task 标为 approved/verified。
- CI 的 SDD Guard 是只读一致性校验,只负责发现规格/索引/change 结构问题,不承担授权语义。
  它**不止跑 `scripts/check-sdd.sh`**:还跑生成器自己的 unittest 套件与零漂移检查
  (见下方本地闸)。只跑 `check-sdd.sh` 就推送会在 CI 才发现 catalog/schema 词表漂移。

## Agent 禁令

- 不得为让实现或测试通过而修改 accepted Core requirement、Safety invariant 或 Acceptance Scenario;此类变化必须走 change proposal 并由人类批准合并。
- Device Agent Runtime Plane MAY 执行已发布 Catalog 的 typed operation。执行与机械证明的
  recovery 不需要 Git task/PR、AUTH-ID、legacy mode、UI acknowledgement 或人工重述/批准
  typed plan。`hostOnly`/`readOnly` 使用 bounded 默认只读策略;`deviceMutation`/`destructive`
  使用 Runtime-owned `RuntimeCapability`。destructive Runtime 必须先完整 materialize 已发布
  typed plan,验证 Artifact lease,读取 fresh target/binding/tool facts,再生成并 durable reserve
  与 operation/version、target/binding、exact inputs、plan/archive/artifact/tool 完全一致的短期
  capability。Agent-facing surface 不得暴露 capability install/revoke/admin,caller/Agent/
  candidate/repairer 不得创建、提供、修改或扩大 trusted facts、capability、reservation/
  outcome/supersession record、uncertain-effect set、Provider coverage declaration 或 hardware
  evidence。自动化 invocation 最多 16 个串行 destructive epochs、四小时、并发一;普通继续
  只有前一 attempt 已 durable terminal 且分类为 `safeToReflash` 才可运行。

  unknown destructive intent 永不 replay。只有 Runtime 从 durable facts 保守界定全部 possible
  effects，并用 exact published Provider complete-overwrite contract、fresh same-target facts、
  immutable Artifact、完整 coverage/verification 和 budget 机械证明
  `safeToSupersedeByCompleteOverwrite` 时，才可启动 distinct recovery。恢复使用新的
  capability/reservation/intent；全部 effect 与 reboot/rebind/postflight confirmed 后才能写
  `SupersedingRecoveryEpoch`。原 outcome 保持 unknown，原 Job 不得投影为 succeeded。已有
  后续 Flash 也只能由完整 durable proof 建立 relation。缺失/漂移、unknown identity、无法
  界定或覆盖的 effect、Provider 未声明、取消、过期或预算耗尽都 fail closed（零新 dispatch）
  并报告不可由确认绕过的 blocker；不得把 replay 改名为 recovery，或把 success string 当
  coverage proof。candidate 仅可在 task-owned isolation 内 build/test;repairer 不得接触 source
  workspace;两者均不得接触 device transport、Runtime、raw shell 或 capability admin，亦不得
  改变 operation/partition/plan/archive/step set/target/coverage proof。历史
  `standingAuthorization`、`evolutionCampaignConfirmation`、one-shot `chatConfirmation` 与
  legacy mode 仅可 decode/export,不得迁移为 RuntimeCapability,新的 admission/reservation/
  dispatch 必须拒绝。UI acknowledgement 仅传达 userdata impact，不是 authority，也不是
  headless Agent、ordinary continuation 或 eligible recovery 的前置条件。
- 不得把 simulation、fake、plan-only 结果记为真实设备或硬件验收;evidence 必须如实分类。
- 不得在设备身份、外部副作用结果或 destructive step 状态不确定时猜测继续(fail closed)。
- 不得使用 host shell 字符串拼接外部命令。
- 不得静默扩展任务范围;范围或 AC 需要变化时,停止并在 change 中显式修订 tasks.md(经 PR review 合入)。
- 平台不能满足 Core 时标记 `blocked` 或 `nonConformant`,不得把平台限制写成 Core 豁免。

## 执行规则(产品闭环阶段)

- **真机验收默认走 Agent/CLI,不是 App UI**:验证已发布 operation、Runtime、Provider、
  binding、Job、journal 或 Artifact 时,Agent SHALL 优先直接执行 `arkdeck agent run`
  (需要人工动作时仅消费并 `agent resume` 对应 `RuntimeHumanAction`),不得要求维护者打开
  App、点击按钮或代跑 host CLI。只有当前 AC 明确验证 App 交互/呈现时才运行 App/UI
  入口;该 UI 腿只证明 App surface,不得成为同一 operation 真机准入或
  `REAL_DEVICE_PASS` 的通用前置。首次设备信任、多候选消歧与物理拔插仍可请求最小
  physical assistance;UI acknowledgement 永远不是 Runtime authority。若 headless 路径
  缺失或失败,应报告 `BLOCKED_BY_PRODUCT_DEFECT` 并修复该产品路径,不得静默回退到 UI
  点击完成验收。
- **进度唯一指标 = Golden Journey**(`PRODUCT-LOOP.md` §6):每轮工作必须映射到
  GJ-1~GJ-5 之一;状态只能取 `NOT_STARTED`/`IMPLEMENTING`/`BLOCKED_BY_PRODUCT_DEFECT`/
  `REAL_DEVICE_PASS`,文档完成、schema 完成或 fake test 通过不构成 `REAL_DEVICE_PASS`。
  每轮结束按 §19 只汇报「本轮修改」与「下一轮建议」;不得固定展开 Golden Journey
  全表、治理循环检查、重复任务检查或其他无变化状态。
- **一个问题 = 一个垂直产品任务 = 一个 PR**(§4):根因说明 + 产品代码修复 + 必要测试 +
  真实设备验证(适用时)+ 最小必要文档更新 + 完成结论同车交付;PR 标题与描述必须如实
  覆盖其全部内容。**不再创建 readiness-only、status-only、done-only、verified-only、
  archive-only PR**;不为同一问题追加 readiness/verification/archive 载体。
- **PR content and language**: Write commit messages, PR titles, and PR descriptions in
  English. Every PR description MUST summarize the actual changes in its diff, explain
  why they are needed, and report verification performed or explicitly not run. A Task ID,
  branch name, or generic generated message alone is not a change summary. When updating
  an automatically generated PR description, preserve the required `Task:` declaration.
- **PR submission state**: Submit PRs as Open and ready for review (`isDraft: false`) by
  default. Use WIP/Draft status, title prefixes, or labels only when the user explicitly
  requests WIP/Draft. If automation creates a draft without that request, mark it ready
  for review before reporting submission. Read back the published PR title, description,
  state, and draft flag to verify that its actual changes are described in English and
  that it is Open and not a draft, unless WIP/Draft was explicitly requested.
- **Agent PR 声明必须在 push 前闭合**:`agent/**` 分支的最终 commit subject 必须包含
  一个 base 上已存在的完整 Task ID,例如
  `fix(TASK-DHA-001): close GJ-2 debug loop`;禁止只写 `GJ-*`/`CHG-*` 而省略
  Task ID。最终 commit 完成后、push 前必须运行
  `python3 scripts/check_pr_paths.py --repo-root . --preflight
  --base-revision origin/main --head-revision HEAD`;该命令只接受 Allowed paths 覆盖完整
  diff 的 base-tree active Task。新 operation/provider/integration profile 的垂直 PR 仍须在
  commit subject 声明一个 base-tree active Task；该 Task 必须覆盖全部生产/测试路径。
  checker 仅可把同车新建且 base 中完全不存在的单一 `openspec/changes/chg-*/` 四件套，
  以及与该 change 唯一新 Task ID 精确同名的 `evidence/runs/<TASK-ID>/`，作为受限的
  自描述 supplement；新 Task 的 Allowed paths 必须描述完整 diff，但不产生任何路径权限，
  且 change 目录必须精确只有四件套，diff 必须同时含 base Task 已授权的
  `Packages/**`、App/UI、Catalog 或 Xcode 生产/测试实现路径。除此之外不得声明仅由当前
  head 新建/恢复的 Task,不得为通过门禁扩张 Allowed paths。`agent-pr` workflow 使用同一 preflight 结果创建初始 PR 正文,
  Agent 不得先 push 再依赖编辑 PR 正文补 `Task:`。
- **本地闸由与 GitHub 共用的路径分类器选择编译车道**。统一入口始终执行 SDD、
  catalog generator unittest 与零漂移三道门；随后按 `origin/main...HEAD + worktree`
  的实际改动选择编译验证：`Packages/ArkDeckKit/**` 跑并行全量 Swift test；
  `ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**` 跑 App/UI-test bundle
  `build-for-testing`；Package 生产 source/manifest 同时跑两条；纯文档与设计稿不分配
  Swift/Xcode 编译。可信 base、merge-base 或 diff 不可得时 fail closed 跑两条。
  `--filter`/`--skip-build` 仍只用于开发反馈,不得替代被分类器选中的最终车道:

  ```bash
  python3 scripts/ci/plan.py \
    --repo-root . \
    --base-revision origin/main \
    --head-revision HEAD \
    --merge-base \
    --include-worktree \
    --run-local
  ```

  该入口使用稳定的 worktree 外 SwiftPM cache；只改测试时不会重编未变化的生产
  module，只改 App 时不会额外执行 ArkDeckKit 全量测试。分类器完成后再执行上面的
  preflight,才等价于 CI 的门。
- **UI 测试不在任何门里,要跑必须手动跑**。`swift-ci.yml` 对 `ArkDeckHDCUITests`
  只做 `build-for-testing`,所以 XCUITest 编译不过会红、断言挂了不会。需要验证
  App 真实呈现时用:

  ```bash
  sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/<Suite>
  ```

  不要直接手写 `xcodebuild test`：有两个坑会伪装成「这台机器不行」——
  ① CI 用的 `CODE_SIGNING_ALLOWED=NO` 会产出无签名 runner，arm64 一启动即被
  SIGKILL，报错写作 `Test crashed with signal kill before establishing connection`
  或 `hung before establishing connection`，只字不提签名；
  ② runner 二进制执行过一次后无法就地重链，下次 `ld` 报 `can't write output file`
  并指向一个明明存在且可写的路径，必须先删 runner bundle。该脚本已封装这两条
  以及独立 DerivedData 与残留进程清理。首次在一个全新 DerivedData 上跑可能报
  `Timed out while enabling automation mode`——同一条命令再跑一次即可，不是环境坏了。

  UI 测试**对负载敏感**:与其他构建并行跑会出现成片的 wait 超时假红。判断一条
  失败是否是自己引入的,先在安静的机器上单独重跑,再用 `git worktree add` 拉出
  改动前的 commit 跑同一条对照——不要凭失败本身下结论。
改动触及 `Catalog/**`、`openspec/contracts/**` 或生成物
  时仍须确认 schema、生成器词表/pin、Swift 校验器与合约测试多处 lockstep，分类器
  不改变这三道通用门及 Swift 面全量回归的语义。
- **产品工作不需要治理载体**:修复 Golden Journey 产品缺陷不要求 ready 任务包、不创建新
  OpenSpec change、不刷新旧任务状态。CI 的任务声明(`scripts/check_pr_paths.py`)仅是
  路径护栏:产品 PR 声明一个 base 上已存在、allowed paths 覆盖其改动的 active 任务
  (如 `TASK-BER-002`/`TASK-DHA-001` 覆盖 `Packages/ArkDeckKit/**` 与 `docs/adr/**`)即可,
  该声明不触发被声明任务的任何治理连锁义务。真实运行结果(命令、退出码、artifact
  hash、脱敏设备标识)随交付 PR 正文或 run 记录如实提交;simulation/fake 不得记为真实
  设备结果。
- **治理载体适用范围(恰四类 + 安全条件)**:仅新 operation 或对已发布 operation 的
  破坏性修改、新 provider、新 integration/device profile、destructive 自动化准入安全策略变化仍走 OpenSpec
  change + PR 审批,且与对应 Golden Journey 交付同车;此外仅 `PRODUCT-LOOP.md` §3 所列
  安全条件允许优先治理工作,处理方式仍是 Runtime 安全代码优先。change 级 `verified`
  翻转与 archive 独立 PR、批次协作(digest 队列、D1/D2 门序)与设备窗口约定,仅在上述
  安全内核治理范围内保留;**历史 change 的批量归档整理冻结**(§20)。D2 窗口授权仍须
  独立载体(其本身是 D2 决策),Runtime-owned destructive safety gate 语义不变。
- **新任务强制自检**(§17 五问 + §5 重复搜索):创建任何新任务前先搜索现有 Backlog、
  打开 PR、最近提交、`Catalog/operations/`、DeviceProviders、旧 OpenSpec Task 与既有
  测试;能并入现有任务的不得新建;判断重复以产品结果为准,不以任务名称为准。
- **治理循环即刻退出**(§18):命中任一信号(连续两个 PR 无生产代码、准备创建
  readiness/archive-only PR、因 schema 不足停止真机修复等)时,立即停止治理工作,
  选择最高优先级产品缺陷直接修复。
- **旧 OpenSpec Task = 历史设计记录**(§16):不重启、不刷新 readiness、不补
  verification、不因旧任务 blocked 而停止当前实现;其中真正未完成的产品能力以垂直
  产品任务重做。
- Windows/Linux 是同一产品的未来平台端口(现状 not started):平台实现不得改变 HDC server 保护、device binding 边界、Job 状态机/journal/recovery 语义、typed step 与 effect 等级、Artifact/隐私规则。

安全内核治理的详细流程见 `openspec/verification/policy.md` 与 `openspec/changes/README.md`(二者适用范围注记见各自文件头)。

## 工具环境约定

- 本项目的 GitHub CLI(`gh`)凭据在 filesystem sandbox 外可用。若 sandbox 内的
  `gh auth status` 报告未登录或 token 无效,Agent SHALL 使用受控的
  `require_escalated` 在 sandbox 外重新检查并执行必要的 `gh` 操作,不得据此要求
  维护者重复登录。

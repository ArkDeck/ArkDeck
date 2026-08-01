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

1. Constitution 的 Safety invariants 与 POL-*(设备安全边界、E0/E1/E2 授权、
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
  integration/device profile;E2 安全策略变化。
- **Device Agent Runtime Plane(设备运行面)**:执行已发布(已合入 main 的
  catalog 所定义)的 typed operation,维护 runtime job/session/artifact。
  **已发布 operation 的每次执行只产生 runtime job 记录,不产生 Git task、
  不开 PR、不要求 `changeId`/`taskId`**;运行时授权凭据是 Runtime
  Capability(E0 默认只读策略;E1 standing capability;E2 一次性
  exact-plan capability,其创建/修改/吊销仍走维护者 merged PR,见下方禁令)。
- 风险分级 D0/D1/D2(决策维度,见 enforcement"决策分级")与执行分级
  E0/E1/E2(设备效果维度)正交;Runtime Plane 的日常 E0 与已授权 E1 执行
  不构成 D* 决策点。
- `scripts/host_loop` 属 Repo Plane:仅领取仓库开发任务;其既有硬件门
  (`Hardware required` 任务拒领、仅 D0 可派发)即设备执行禁令的机械承载,
  host_loop 不得执行 HDC、刷机、日志/trace 采集或任何设备 runtime job。
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
- 对真实设备的 destructive 操作(Flash、erase、format、unlock、真实 update)只能在持有维护者经 merged PR 预先批准、与待执行计划逐项精确一致的 standing authorization 时执行(POL-AGENT-002 执行分级 E2);授权缺失、过期或任一项不匹配时执行门必须 fail closed(零 dispatch)。只读采集与 host 侧分析(E0)在 approved change 的 ready 任务范围内可无人值守执行;可逆 deviceMutation(E1)另需 per-device typed capability evidence。evidence 必须如实记录 executor 身份(human|agent)、按实际 effect 匹配的 authority reference（Agent E0 = default read-only policy，E1 = RuntimeCapability，E2 = standing authorization）、目标确认与时间。Agent 不得自行创建、修改或批准 standing authorization。
- 不得把 simulation、fake、plan-only 结果记为真实设备或硬件验收;evidence 必须如实分类。
- 不得在设备身份、外部副作用结果或 destructive step 状态不确定时猜测继续(fail closed)。
- 不得使用 host shell 字符串拼接外部命令。
- 不得静默扩展任务范围;范围或 AC 需要变化时,停止并在 change 中显式修订 tasks.md(经 PR review 合入)。
- 平台不能满足 Core 时标记 `blocked` 或 `nonConformant`,不得把平台限制写成 Core 豁免。

## 执行规则(产品闭环阶段)

- **进度唯一指标 = Golden Journey**(`PRODUCT-LOOP.md` §6):每轮工作必须映射到
  GJ-1~GJ-5 之一;状态只能取 `NOT_STARTED`/`IMPLEMENTING`/`BLOCKED_BY_PRODUCT_DEFECT`/
  `REAL_DEVICE_PASS`,文档完成、schema 完成或 fake test 通过不构成 `REAL_DEVICE_PASS`。
  每轮结束按 §19 汇报格式汇报。
- **一个问题 = 一个垂直产品任务 = 一个 PR**(§4):根因说明 + 产品代码修复 + 必要测试 +
  真实设备验证(适用时)+ 最小必要文档更新 + 完成结论同车交付;PR 标题与描述必须如实
  覆盖其全部内容。**不再创建 readiness-only、status-only、done-only、verified-only、
  archive-only PR**;不为同一问题追加 readiness/verification/archive 载体。
- **Agent PR 声明必须在 push 前闭合**:`agent/**` 分支的最终 commit subject 必须包含
  一个 base 上已存在的完整 Task ID,例如
  `fix(TASK-DHA-001): close GJ-2 debug loop`;禁止只写 `GJ-*`/`CHG-*` 而省略
  Task ID。最终 commit 完成后、push 前必须运行
  `python3 scripts/check_pr_paths.py --repo-root . --preflight
  --base-revision origin/main --head-revision HEAD`;该命令只接受 Allowed paths 覆盖完整
  diff 的 base-tree active Task。不得声明仅由当前 head 新建/恢复的 Task,不得为通过门禁
  扩张 Allowed paths。`agent-pr` workflow 使用同一 preflight 结果创建初始 PR 正文,
  Agent 不得先 push 再依赖编辑 PR 正文补 `Task:`。
- **本地闸是四条命令,不是一条**。改动触及 `Catalog/**`、`openspec/contracts/**` 或
  生成物时尤其如此——新增一个 action/字段类型要在 schema、生成器词表、生成器 pin、
  Swift 校验器与合约测试**多处 lockstep**,而只有后两处会被 `swift test` 发现:

  ```bash
  sh scripts/check-sdd.sh
  .venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"
  .venv-sdd/bin/python scripts/catalog_gen/generate.py --check
  ```

  三条全绿后还必须执行本地并行全量 Swift 门(`--num-workers` 控制测试执行并发;
  `--filter`/`--skip-build` 只用于开发反馈,不得替代本门):

  ```bash
  swift test --package-path Packages/ArkDeckKit --parallel --num-workers 8
  ```

  四条全绿再加上面的 preflight,才等价于 CI 的门。
- **产品工作不需要治理载体**:修复 Golden Journey 产品缺陷不要求 ready 任务包、不创建新
  OpenSpec change、不刷新旧任务状态。CI 的任务声明(`scripts/check_pr_paths.py`)仅是
  路径护栏:产品 PR 声明一个 base 上已存在、allowed paths 覆盖其改动的 active 任务
  (如 `TASK-BER-002`/`TASK-DHA-001` 覆盖 `Packages/ArkDeckKit/**` 与 `docs/adr/**`)即可,
  该声明不触发被声明任务的任何治理连锁义务。真实运行结果(命令、退出码、artifact
  hash、脱敏设备标识)随交付 PR 正文或 run 记录如实提交;simulation/fake 不得记为真实
  设备结果。
- **治理载体适用范围(恰四类 + 安全条件)**:仅新 operation 或对已发布 operation 的
  破坏性修改、新 provider、新 integration/device profile、E2 安全策略变化仍走 OpenSpec
  change + PR 审批,且与对应 Golden Journey 交付同车;此外仅 `PRODUCT-LOOP.md` §3 所列
  安全条件允许优先治理工作,处理方式仍是 Runtime 安全代码优先。change 级 `verified`
  翻转与 archive 独立 PR、批次协作(digest 队列、D1/D2 门序)与设备窗口约定,仅在上述
  安全内核治理范围内保留;**历史 change 的批量归档整理冻结**(§20)。D2 窗口授权仍须
  独立载体(其本身是 D2 决策),E2 授权语义不变。
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

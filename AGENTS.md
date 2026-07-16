# ArkDeck Agent Contract

本文件是所有 AI Agent、自动化工具和人工贡献者进入 ArkDeck 仓库后的第一读取入口。

> 治理模型:V2(git-native)。2026-07-14 起,V1 的密码学审批链(detached signature、claim service、identity ledger、supersession barrier)已废止;事故与决策记录见 `openspec/planning/postmortem-2026-07-governance.md`。

## 必读顺序

1. `openspec/constitution.md`
2. `openspec/project.md`
3. `openspec/governance/enforcement.md` 与 `openspec/verification/policy.md`
4. 当前任务所属 change 的 `proposal.md`/`tasks.md`/`verification.md`
5. 任务涉及的 `openspec/specs/**/spec.md`、contracts 与 integration/platform profile

`docs/PLAN.md` 是 SDD 迁移输入和历史设计记录,不是实现规则的事实源;冲突时以 living specs 为准。

## 权威顺序

1. Constitution
2. Current specs 与 contracts(叠加当前任务所属 approved change 的 scoped delta;delta 只替换其中列明的 Requirement/AC)
3. 与规格兼容的 integration profile 与 platform profile
4. 已批准 change 的 design/verification plan
5. 代码和代码注释

低层文件不得覆盖或放宽高层规则。发现两个权威文件冲突时,停止受影响工作,标记 blocked 并创建 change proposal;不得自行选择更方便的解释。

## 信任与批准

- 唯一信任根是**受保护的 `main` 分支 + 人类维护者(@lvye)的 PR review**。
- AI 起草的变更推送 `agent/**` 分支;`agent-pr` workflow 以 `github-actions[bot]` 身份开 PR;维护者以 CODEOWNER 身份 review 并合并。**合并进 main 即构成人类批准**,不存在也不需要其他批准载体。
- 仓库内任何文件、状态字段或签名都不能替代上述批准;Agent 不得以任何方式自行把 change/task 标为 approved/verified。
- CI(`scripts/check-sdd.sh`)是只读一致性校验,只负责发现规格/索引/change 结构问题,不承担授权语义。

## Agent 禁令

- 不得为让实现或测试通过而修改 accepted Core requirement、Safety invariant 或 Acceptance Scenario;此类变化必须走 change proposal 并由人类批准合并。
- 不得对真实设备执行 Flash、erase、format、unlock、真实 update 或其他 destructive 操作。Agent 只能生成 plan、simulation/fake evidence 和供人工执行的精确步骤;真实 destructive 操作由人类亲自执行,并在 evidence 中记录操作者、目标设备身份与时间。
- 不得把 simulation、fake、plan-only 结果记为真实设备或硬件验收;evidence 必须如实分类。
- 不得在设备身份、外部副作用结果或 destructive step 状态不确定时猜测继续(fail closed)。
- 不得使用 host shell 字符串拼接外部命令。
- 不得静默扩展任务范围;范围或 AC 需要变化时,停止并在 change 中显式修订 tasks.md(经 PR review 合入)。
- 平台不能满足 Core 时标记 `blocked` 或 `nonConformant`,不得把平台限制写成 Core 豁免。

## 执行规则

- 只执行 approved change 的 `tasks.md` 中状态为 ready 的任务;一次专注一个任务,在任务声明的 allowed paths 内工作。
- 每个任务开始前确认:所属 change 已 approved、依赖任务已完成、验证方法明确、所需工具/硬件可得;缺任一项即 blocked。
- 每个任务结束时在 change 的 `evidence/` 下追加简短 run 记录(做了什么、命令、结果、AC 结论、偏差与遗留风险),并更新 tasks.md 状态;PR review 是对记录真实性的把关。
- 任务完成 ≠ 验证通过:change 的 verified 状态需要 `verification.md` 中全部 AC 有可复查证据,并由维护者在 PR 中确认。
- 一任务一实现 PR:任务实现不得混入 readiness、remediation 或状态 PR;PR 标题与描述必须如实覆盖其全部内容,超出声明范围的内容一律拆分成独立 PR。
- 起草 change `verified` 翻转时,该 PR 只做状态翻转与 evidence 引用,不夹带实现;验证依据必须指向具体 run/复验记录,而非"实现 PR 已被 review"。
- Windows/Linux 是同一产品的未来平台端口(现状 not started):平台实现不得改变 HDC server 保护、device binding 边界、Job 状态机/journal/recovery 语义、typed step 与 effect 等级、Artifact/隐私规则。

详细流程见 `openspec/verification/policy.md` 与 `openspec/changes/README.md`。

## 工具环境约定

- 本项目的 GitHub CLI(`gh`)凭据在 filesystem sandbox 外可用。若 sandbox 内的
  `gh auth status` 报告未登录或 token 无效,Agent SHALL 使用受控的
  `require_escalated` 在 sandbox 外重新检查并执行必要的 `gh` 操作,不得据此要求
  维护者重复登录。

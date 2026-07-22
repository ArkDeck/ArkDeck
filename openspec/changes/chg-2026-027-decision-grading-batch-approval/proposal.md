---
id: CHG-2026-027-decision-grading-batch-approval
revision: 1
status: approved # 2026-07-22 本 approval-only PR(先例 #226/#253/#254/#281);r1 proposal 经 #315 合入 main `7a58b02`;批准由维护者 review/merge 本 PR 构成
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# 决策分级与批次审批:无人值守 host 闭环的人类介入粒度

## Why

维护者(owner)于 2026-07-22 明确目标:**AI 无人值守闭环所有机器可判定的
host-only 任务;遇到审批、产品决策、硬件授权时暂停,汇总成人类批次审批;
批准后自动继续**。

现行 V2 治理与该目标不冲突——信任根不需要动,需要动的是**人类介入的粒度与
节奏**:

1. **人类是每一步的串行瓶颈,而不只是判断门**:PR 链
   (propose→approval→readiness→实现→done→verify→archive)的每一步都等维护者
   实时逐个 review/merge,其中大量是机器可判定的机械推进(done 翻转对 merged
   OID 复核、verify 翻转、archive 引用扫描、evidence rerun 记录、pins 无漂移
   复核)——它们消耗的是判断带宽,换回的判断价值趋近于零。
2. **同构先例已在设备执行维度落地**:CHG-2026-025 把设备操作按风险分级
   (E0/E1/E2),让 E0 只读采集在 ready 任务内无人值守执行,把人类上移为规则
   与计划的批准者。本 change 把同一思想推广到 **PR/决策维度**。
3. **批次实践已存在但未成文**:归档批(#242-#246)、晚间集中合并场已是维护者
   的真实工作形态;但 AI 不围绕批次组织工作,lane 在每个 PR 处空转等待,
   并行度受维护者在线时间限制。

不变的前提:威胁模型仍是"自主 Agent 可能伪造证据、静默扩权、绕过验收"。
本 change **只改变人类介入的粒度与节奏,不移动批准权**——合并进受保护 main
仍是唯一批准载体,不引入任何形式的 auto-merge,`POL-AGENT-001`/
`POL-AGENT-002` 零改动。

## What changes

- **enforcement.md 2.0.0 → 2.1.0**(TASK-BAP-001;直接编辑正本,先例 =
  CHG-2026-025 TASK-AIN-001 对 enforcement"真实硬件与 destructive 操作"节的
  直接改写):"批准语义"节 ADDED 两小节——**决策分级**(D0 机器可判定状态推进 /
  D1 人类判断 / D2 物理与授权;判定标准见 design §1)与**批次审批协议**
  (digest、按序逐 PR 合并语义、入队门;见 design §2)。
- **AGENTS.md 执行规则同步**(同 TASK-BAP-001):补充批次协作约定与
  "判断门后零投机堆叠"约束(design §3)。
- **批次运营载体**(TASK-BAP-002):`openspec/templates/batch-digest.md`
  (digest 模板)+ `openspec/governance/host-loop-runbook.md`(守望循环
  runbook:推进→入队→全阻塞汇总→检测合并→rebase 续跑);交付后执行**首次
  批次演练**——≥2 个真实 D0 项走完整 digest→批次合并→自动续跑流程,产出
  evidence。
- **凭据分离落实**(TASK-BAP-003,human 执行项):enforcement.md"V1 遗留清理"
  中悬置至今的收权项升级为本 change 硬任务——Agent 运行环境仅持能推送
  `agent/**` 的受限凭据,正向+负向双向验证记 evidence。无人值守吞吐扩大前,
  "Agent 无法自批"不能仍是软约束(design §5)。

Out of scope / Non-goals:

- **auto-merge 显式排除**:任何等级(含 D0)都不引入自动合并;merge 永远是
  维护者动作;"CI 绿 ≠ 批准"不变。
- **guard/CI 机械化四项另立伴随 change**(macOS Swift build+test CI job、三方
  revision 同步校验、全 OID 引用格式校验、allowed-paths diff 校验):与本
  change 无先后硬依赖,本 change 的 D0 定义不以其存在为前提(design §6)。
- Core spec/contract/schema 零改动;constitution 零改动(POL-* 全部原文不动);
  CORE baseline 不升版(enforcement.md 与 AGENTS.md 均不在 baseline scope;
  class implementation-only 先例 CHG-2026-014/017)。
- 设备执行分级 E0/E1/E2(CHG-2026-025)不动——D* 作用于 PR/决策维度,与 E*
  正交(一个 E2 执行的 standing authorization 载体 PR,在 D* 维度是 D2)。
- V2 PR 链步骤本身不变(propose→approval→readiness→实现→done→verify→archive
  一步不少);批次只改变合并的节奏与组织,不改变任何一步的载体与内容要求。

Observable behavior before/after:

- Before:维护者逐 PR 实时 review/merge,人类介入次数 = PR 数;AI lane 在每个
  PR 处阻塞等待。
- After:AI 各 lane 推进到人类门(D1/D2)即生成 digest 入批次队列并转入其他
  lane;D0 翻转 PR 同样入队不催合;维护者按批次按 digest 声明顺序逐 PR
  review/merge——**每次合并仍是逐 PR 批准,review 深度不因批次降低,digest
  只是导航不是批准依据**;合并后守望循环检测 main 前进,rebase 续跑。信任根、
  批准载体、权威顺序与 before 完全一致。

## Scope(涉及的 Requirement/AC)

- Requirements:无(canonical Core AC 零认领;constitution/specs/contracts 零
  改动)
- Acceptance:三条 change-local(`BAP-GOV-001`/`BAP-DRILL-001`/`BAP-CRED-001`,
  见 acceptance-cases.yaml)
- Core baseline bump:不需要

## Safety, privacy, and compatibility

- Failure modes:批次内某 PR 被维护者拒绝或要求修改 → 该项回炉走正常修复流程,
  digest 中声明依赖它的后续项本轮跳过(按序合并遇拒即停该依赖链,不跳合);
  守望循环无法确认合并状态(poll 失败/网络不可用)→ 保持暂停,不猜测续跑
  (POL-SAFETY-001 同构);digest 与 PR 实际内容漂移 → 合并前逐 PR review 仍是
  唯一把关,digest 无批准语义,漂移发现后按 enforcement"PR 载体与内容一致"
  条款记录。
- 隐私:digest 模板与 runbook 零敏感数据;本 change host-only,演练 evidence
  遵守现行脱敏规则。
- 兼容:零产品代码、零 schema 变更,Swift 全量基线不动;既有 open PR 与在途
  lane 不受影响(批次协议生效后按 runbook 组织新工作)。
- Rollback:revert enforcement 2.1.0 两小节与 AGENTS.md 补充即回到逐 PR 实时
  模式;批次协议不产生持久运行时状态,队列载体只是导航物,审计正本永远是
  git 历史中的逐 PR 合并记录。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR(先例
#55/#89/#171/#195/#226/#253/#254/#281);三任务各自独立 readiness/实现(或
执行)/done PR。TASK-BAP-001 与 TASK-BAP-003 可并行,TASK-BAP-002 blocked 于
两者 done。change verified = 三 AC 有可复查证据 + 首次批次演练 evidence 在案
(另行 verify PR)。

## Approval

- r1 proposal 经 PR #315 合入 main(squash
  `7a58b026646a3b1ed543cc5e941ddb1d1e02206f`,status:proposed,merged by
  维护者 @lvye,2026-07-22)。owner 方向确认:2026-07-22 维护者亲自提出
  "AI 无人值守闭环所有机器可判定的 host-only 任务;遇审批/产品决策/硬件授权
  暂停并汇总成人类批次审批;批准后自动继续"并指示起草本 change 与批准 PR。
- 正式批准:2026-07-22 由本 approval-only PR(先例 #55/#89/#171/#195/#226/
  #253/#254/#281)将本 change 置为 `approved`;批准由维护者 review/merge 本
  PR 构成。merge 即批准:
  - **决策分级**:D0/D1/D2 定义与 D0 三条件判定标准(design §1),门类封闭
    列举、拿不准升级;与 E0/E1/E2 设备执行分级正交;
  - **批次审批协议**:GitHub issue 队列载体、digest 字段面、入队三门(CI 绿/
    独立 AI 合前 review APPROVE/digest 完整)、按 digest 声明顺序逐 PR 合并、
    遇拒停依赖链(design §2);**digest 无批准语义、任何等级无 auto-merge**;
  - **宽度并行原则**:判断门(D1/D2)后零投机堆叠,吞吐来自多 lane 并行
    (design §3);
  - **三任务 scope 与边界**:TASK-BAP-001(enforcement 2.0.0→2.1.0 决策分级+
    批次协议两小节 + AGENTS.md 同步)、TASK-BAP-002(digest 模板 + 守望循环
    runbook + 首次批次演练;blocked 于 001+003 done)、TASK-BAP-003(Agent
    凭据分离落实,human 执行项)的 objective/allowed-paths/验证方式;
  - **不动面**:唯一信任根(受保护 main + CODEOWNER review)、POL-* 全部
    原文、V2 PR 链步骤、"CI 绿 ≠ 批准"、E0/E1/E2、CORE baseline(不升版)。
- 本批准不产生任务执行:三任务保持 `blocked`,各须独立 readiness PR 转
  `ready`。**本批准亦不构成任何具体批次的预先批准**——批次内每次合并仍是
  维护者逐 PR 批准,本 change 的协议只组织其节奏。

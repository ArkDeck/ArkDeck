---
id: CHG-2026-010-dayu200-recovery-playbook
revision: 1
status: approved # r1 proposal 经 #72 合入;批准由本 approval-only PR 的维护者 review/merge 构成
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Route-B ②:DAYU200 恢复/救砖预案(文档研究,零设备)

## Why

CHG-2026-007 route-b-plan.md 批准的立项顺序第②步,也是全链条的先行闸门:
`GAP-DAYU200-RECOVERY-PATH` 的关闭事实要求"恢复路径被确证并由人类操作者在
真机上演练成功至少一次";演练(第③步,首个写设备操作)的**前置 gate 是书面
恢复预案**。本 change 产出该预案——纯文档研究(S2/S3 来源分级引用),零设备
操作、零工具执行。预案完成后,设备窗口一到即可立项演练;在演练成功前,硬顺序
规则继续禁止一切写设备操作。

## What changes

### In scope(纯文档)

- 起草 `evidence/recovery-playbook.md`,必备七节:
  1. 强制进入方式:RK3568/DAYU200 的 maskrom 与 loader 模式进入方法(硬件
     按键/短接点位,以板卡文档为准),含各模式的判别特征(USB 枚举形态);
  2. 恢复工具:候选工具(rkdeveloptool/upgrade_tool/RKDevTool 等)及 macOS
     可用性结论,版本与来源;
  3. 恢复物料:所需镜像/loader 文件清单,与 CHG-2026-003 pinned 镜像成员的
     对应关系(引用 hash,不复制字节);
  4. 恢复步骤序列:从"不可启动"回到可启动的完整步骤,逐步标注前提与判别点;
  5. 风险点与中止准则:每步可能的失败形态、何时必须停手、升级路径;
  6. 演练前置检查单:演练 change 立项前必须本地就绪的全部条件(物料、工具、
     维护者风险确认、时间窗);
  7. 来源引用:逐条 S2/S3 分级;S3 仅线索,预案中依赖 S3 的步骤显式标注
     "待演练确证"。
- 预案显式边界:未经演练,本预案不关闭 gap、不构成演练执行授权。

### Out of scope

- 任何设备操作(含只读)、任何演练/烧写/模式切换;
- 恢复工具的安装/运行(工具可用性结论仅来自文档研究);
- `GAP-DAYU200-RECOVERY-PATH` 状态变更(关闭需第③步演练成功 evidence);
- specs/contracts/hardware-matrix/integration lock 修改;支持声明。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Platform Profile / Integration lock / hardware matrix:unchanged

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no revalidation trigger | 纯文档,无产品代码变更 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- plan/doc-only:零设备命令、零工具执行;网络仅用于文档检索(S2/S3 来源),
  检索结果只进预案引用,不下载执行任何二进制;
- 预案内容不得被解释为执行授权;演练 change(第③步)须独立立项、approve,
  且以本预案 + 维护者风险明示确认为前置 gate;
- 依赖 S3 的任何步骤显式标注不确定性,不得伪装成已确证事实。

## Approval

- Proposal 经 PR #72 合入 main(`eabe8f6`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由本 approval-only PR(先例 #14/#40/#55)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。本批准不产生任务执行:
  TASK-RP-001 另需独立 readiness/status PR 转 ready;doc-only 边界不因批准改变。

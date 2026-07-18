---
id: CHG-2026-010-dayu200-recovery-playbook
revision: 1
status: archived
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
- 正式批准:2026-07-18 由 approval-only PR #73 合入 main(`d70f741`)将本 change
  置为 `approved`(先例 #14/#40/#55);TASK-RP-001 经 readiness PR #74(`4a58a7c`)
  转 ready。

## Verification closure(2026-07-18)

- 交付物 `evidence/recovery-playbook.md` + `evidence/runs/TASK-RP-001/run.md`
  经 PR #75 合入 main(`a1572d0`);TASK-RP-001 经状态 PR #76 合入 main
  (`6d8859f`)翻转 done。两个 change-local AC
  (`TEST-RECOVERY-DAYU200-PLAYBOOK-001`、`TEST-RECOVERY-DAYU200-READINESS-001`)
  在 run.md 以 document review 二值 PASS;doc-only gate 自证(#75 仅新增两个
  markdown,零命令执行)。
- 上述 PR 的维护者 review/merge 构成 `verification.md` acceptance matrix 所
  要求的 verification confirmation。本文件的 `status: verified` 仅在包含本状态
  变更的 verification closure PR 经维护者 review 并合入 `main` 后生效;verified
  不改变 evidence 的边界——预案仍未经演练,不关闭 `GAP-DAYU200-RECOVERY-PATH`
  (关闭需第③步真机演练成功),不构成执行授权;§6 检查单是未来演练 change 的
  前置 gate 而非授权;DEC-002 保持 open。archive 由后续独立 archive PR 完成
  (先例 #21/#49),归档不改变演练 change 必须原文引用 §6 检查单的义务(先例:
  recovery-playbook 引用 archived CHG-2026-003 evidence)。

## Archive

本 change 于 2026-07-18 verified(PR #83,main `5c1337d`)后经本独立 archive PR
归档:目录整体移入
`openspec/changes/archive/2026-07-18-chg-2026-010-dayu200-recovery-playbook/`,
`status: archived` 仅在维护者 review/merge 本 PR 后生效(先例 #21/#49)。本
change class 为 platform、`core_change_level: none`:归档不涉及任何 spec/
contract/baseline/conformance 变更,无 ratification 成分。
`evidence/recovery-playbook.md` 自归档位置继续作为 Route-B 第③步演练 change
的前置输入——**演练 change 立项时必须自归档路径原文引用其 §6 检查单作前置
gate,该义务不因归档改变**(先例:本预案自身即引用 archived CHG-2026-003
evidence);预案未经演练、不关闭 `GAP-DAYU200-RECOVERY-PATH`、非执行授权的
边界与全部【待演练确证】标注不变;DEC-002 保持 open。

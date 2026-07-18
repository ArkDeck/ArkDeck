---
id: CHG-2026-011-dayu200-flash-protocol-research
revision: 1
status: archived
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Route-B ④a:DAYU200 烧写协议只读文档研究(GAP-FLASH-PROTOCOL 第一阶段)

## Why

CHG-2026-007 route-b-plan.md 的 `GAP-DAYU200-FLASH-PROTOCOL` 关闭分两阶段:
第一阶段**只读**(厂商/官方文档与源码研读 + 未来工具 help/list 输出受控采集),
第二阶段真机模式确认(写设备,受硬顺序规则约束、须 RECOVERY 演练先行)。本
change 是第一阶段的**文档研究部分**:确证 DAYU200 实际可用的烧写通道、进入
方式、传输层与工具链版本约束的**文档级事实**,产出协议事实清单供后续真机确认
change 与 DEC-002 决策使用。与 TASK-PD-001(分区语义)零耦合——协议不依赖分区
偏移。

## What changes

### In scope(纯文档研究)

- 起草 `evidence/flash-protocol-facts.md`,必备五节:
  1. 通道枚举:候选烧写通道(RockUSB/MaskRom-loader、OpenHarmony flashd/hdc
     升级路径、其它)各自的文档级定义与适用态;
  2. 进入方式与传输层:各通道的进入条件(MaskRom/Loader/系统内)、传输层
     (USB;TCP/UART 明确列为 out of scope,本 change 不研究)、USB 识别形态
     (VID/PID 文档值);
  3. 工具映射:各通道对应的 host 工具(rkdeveloptool/upgrade_tool/RKDevTool/
     hdc)、macOS 可用性、版本约束;
  4. 只读观察面草案:未来第一阶段可受控采集的**只读**命令清单(如
     `rkdeveloptool ld`、工具 `--help`/version、`hdc` 只读子命令),逐条标注
     只读性;凡涉及模式切换/写设备的候选一律标注【第二阶段·写设备·RECOVERY
     先行】,不纳入本 change 执行面;
  5. 来源引用:逐条 S2/S3 分级;S3 依赖结论标注【待真机确证】。
- 事实清单显式边界:文档级结论,非兼容性/支持声明,不解除 gap。

### Out of scope

- 任何设备操作(含只读命令的实际执行)、任何写设备/模式切换/烧写;
- TCP/UART transport 研究(route-b/M0B 已推迟);
- 烧写地址推导(属 GAP-FLASH-ADDRESSES,建议在 TASK-PD-001 evidence 后立项);
- specs/contracts/hardware-matrix/integration lock 修改;gap 状态变更;支持声明。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Platform Profile / Integration lock / hardware matrix:unchanged

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no revalidation trigger | 纯文档研究,无产品代码变更 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- doc-only:零设备命令、零工具执行;网络仅用于文档检索,不下载执行二进制;
- 只读观察面仅为设计草案,其执行属后续阶段/change,须独立立项;涉及写设备的
  候选受 RECOVERY 先行硬序约束;
- 依赖 S3 的任何结论标注【待真机确证】,不得伪装成已确证事实。

## Approval

- Proposal 经 PR #77 合入 main(`24fedad`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由 approval-only PR #78 合入 main(`9e88065`)将本 change
  置为 `approved`(先例 #14/#40/#55);TASK-FP-001 经 readiness PR #79(`751bc00`)
  转 ready。

## Verification closure(2026-07-18)

- 交付物 `evidence/flash-protocol-facts.md` + `evidence/runs/TASK-FP-001/run.md`
  经 PR #80 合入 main(`67bfa01`);TASK-FP-001 经状态 PR #81 合入 main
  (`eeebf02`)翻转 done。两个 change-local AC
  (`TEST-PROTOCOL-DAYU200-CHANNELS-001`、
  `TEST-PROTOCOL-DAYU200-OBSERVATION-PLAN-001`)在 run.md 以 document review
  二值 PASS;doc-only gate 自证(#80 仅新增两个 markdown,零命令执行)。
- 上述 PR 的维护者 review/merge 构成 `verification.md` acceptance matrix 所
  要求的 verification confirmation。本文件的 `status: verified` 仅在包含本状态
  变更的 verification closure PR 经维护者 review 并合入 `main` 后生效;verified
  不改变 evidence 的边界——事实清单仍为文档级结论、非兼容性/支持声明,不解除
  `GAP-DAYU200-FLASH-PROTOCOL`,不构成任何执行授权,DEC-002 保持 open。archive
  由后续独立 archive PR 完成(先例 #21/#49)。

## Archive

本 change 于 2026-07-18 verified(PR #82,main `527e61b`)后经本独立 archive PR
归档:目录整体移入
`openspec/changes/archive/2026-07-18-chg-2026-011-dayu200-flash-protocol-research/`,
`status: archived` 仅在维护者 review/merge 本 PR 后生效(先例 #21/#49)。本
change class 为 platform、`core_change_level: none`:归档不涉及任何 spec/
contract/baseline/conformance 变更,无 ratification 成分。
`evidence/flash-protocol-facts.md` 自归档位置继续作为 DEC-002 决策、Route-B
第二阶段真机确认 change 与 CHG-2026-012(④b 地址研究)的只读输入;其文档级
结论、非兼容性/支持声明、非执行授权边界与全部【待真机确证】标注不因归档改变;
`GAP-DAYU200-FLASH-PROTOCOL` 保持 unknown。

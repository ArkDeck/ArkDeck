---
id: CHG-2026-012-dayu200-flash-addresses-research
revision: 1
status: approved # r1 proposal 经 #86 合入;批准由本 approval-only PR 的维护者 review/merge 构成
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Route-B ④b:DAYU200 烧写地址映射只读文档研究(GAP-FLASH-ADDRESSES 第一阶段)

## Why

CHG-2026-007 route-b-plan.md 的 `GAP-DAYU200-FLASH-ADDRESSES` 关闭分两阶段:
第一阶段**只读**(工具文档/源码的寻址语义研读 + 未来工具 help/list 输出受控
采集),第二阶段(若必要)写设备验证(仅在 RECOVERY-PATH 关闭后可立项)。本
change 是第一阶段的**文档研究部分**:确证各 host 工具写入寻址方式的文档级
语义(按分区名还是按地址/扇区偏移),并把逐分区目标地址映射表**锚定到
TASK-PD-001(CHG-2026-009)分区解码 evidence**——该 evidence 是地址数值的唯一
权威来源,本 change 不自行推导、不从镜像成员字节推导(CHG-2026-003 非目标的
延续)。与 CHG-2026-011 协议事实清单互补:协议答"走哪条通道",本 change 答
"写到哪里、按什么寻址"。因地址与分区语义强耦合,TASK-FA-001 在 approve 之外
另以 PD-001 evidence 合入 main 为硬前置。

## What changes

### In scope(纯文档研究)

- 起草 `evidence/flash-address-facts.md`,必备五节:
  1. 寻址方式语义:各工具写入寻址的文档级语义——`rkdeveloptool`
     `wl <BeginSec>`(按 LBA 扇区偏移)/`wlx <PartName>`(按分区名,依赖设备侧
     分区表存在)/`gpt`/`prm`(写分区表本体)、`upgrade_tool` 与
     RKDevTool(config.cfg 地址列与写序)各自的寻址前提与适用态;
  2. 地址映射表:逐可烧写分区的目标偏移/寻址键,**逐行标注 TASK-PD-001 解码
     evidence 锚点**(唯一权威来源);PD-001 未覆盖的分区显式列 unknown,不得
     以其它来源填补数值;
  3. 对账方法设计:映射表与 parameter.txt/GPT 语义的对账口径(与 PD-001
     evidence 的一致性检查项清单,供未来受控采集/演练 change 使用);
  4. 只读观察面草案:未来第一阶段可受控采集的**只读**命令清单(如工具
     `--help`/version、`rkdeveloptool ld`,以及需设备已处特定态的 `ppt` 类读
     分区表输出),逐条标注只读性与前提;凡涉及模式切换/写设备的候选一律标注
     【第二阶段·写设备·RECOVERY 先行】,不纳入本 change 执行面;白名单扩展
     本身须由未来执行 change 的 design 审定,本 change 不扩白名单;
  5. 来源引用:逐条 S2/S3 分级;凡仅 S3 支撑或推断的结论标注【待真机确证】。
- 事实清单显式边界:文档级结论,非兼容性/支持声明,不解除 gap。

### Out of scope

- 任何设备操作(含只读命令的实际执行)、任何写设备/模式切换/烧写;
- **从镜像成员字节推导地址**(CHG-2026-003 非目标延续;PD-001 evidence 是唯一
  数值来源);
- m0b_capture 白名单的实际扩展或任何采集执行;
- TCP/UART transport 研究(route-b/M0B 已推迟);
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
- 地址权威性硬约束:映射表任何数值必须逐行锚定 PD-001 解码 evidence;PD-001
  evidence 未合入 main 前 TASK-FA-001 保持 blocked,不得以草稿/未合入产物为锚;
- 只读观察面仅为设计草案,其执行属后续阶段/change,须独立立项;涉及写设备的
  候选受 RECOVERY 先行硬序约束(route-b-plan 全局规则);
- 依赖 S3 或推断的任何结论标注【待真机确证】,不得伪装成已确证事实。

## Approval

- Proposal 经 PR #86 合入 main(`0f96616`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由本 approval-only PR(先例 #14/#40/#55)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。本批准不产生任务执行:
  TASK-FA-001 的第②前置(TASK-PD-001 分区解码 evidence 合入 main)未满足,
  任务保持 blocked(先例:CHG-2026-008 approve 后 TASK-UD-001 继续 blocked 等
  M1-006);两前置齐备后另需独立 readiness/status PR 转 ready;doc-only 边界
  不因批准改变。

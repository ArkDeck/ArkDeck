---
id: CHG-2026-012-dayu200-flash-addresses-research
revision: 2
status: archived # 2026-07-20 archive PR;verified 于同日 verification closure PR
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
TASK-PD-002(CHG-2026-009)同一次 fresh signed-broker platform run 的 mapping/
reconciliation evidence**——该 evidence 绑定已合入 TASK-PD-001 codec implementation，
且是地址数值的唯一权威来源；TASK-PD-001 自 r4 起只拥有 headless codec contract，明确
不读取 pinned archive 或产生 mapping。本 change 不自行推导、不从镜像成员字节推导
(CHG-2026-003 非目标的延续)。与 CHG-2026-011 协议事实清单互补:协议答"走哪条通道",
本 change 答"写到哪里、按什么寻址"。因地址与分区语义强耦合,TASK-FA-001 在 approve
之外另以 TASK-PD-002 done 与其 fresh platform evidence 合入 main 为硬前置。

## What changes

### In scope(纯文档研究)

- 起草 `evidence/flash-address-facts.md`,必备五节:
  1. 寻址方式语义:各工具写入寻址的文档级语义——`rkdeveloptool`
     `wl <BeginSec>`(按 LBA 扇区偏移)/`wlx <PartName>`(按分区名,依赖设备侧
     分区表存在)/`gpt`/`prm`(写分区表本体)、`upgrade_tool` 与
     RKDevTool(config.cfg 地址列与写序)各自的寻址前提与适用态;
  2. 地址映射表:逐可烧写分区的目标偏移/寻址键,**逐行标注 TASK-PD-002 fresh
     platform mapping evidence 锚点**(唯一权威来源);PD-002 未覆盖的分区显式列 unknown,不得
     以其它来源填补数值;
  3. 对账方法设计:映射表与 parameter.txt/GPT 语义的对账口径(与 PD-002 platform
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
- **从镜像成员字节推导地址**(CHG-2026-003 非目标延续;PD-002 platform evidence 是唯一
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
- 地址权威性硬约束:映射表任何数值必须逐行锚定 TASK-PD-002 同一次 fresh run 的
  mapping evidence；TASK-PD-002 `done` 状态及其 evidence 未全部合入 main 前
  TASK-FA-001 保持 blocked,不得以 TASK-PD-001 headless receipt、草稿或未合入产物为锚;
- 只读观察面仅为设计草案,其执行属后续阶段/change,须独立立项;涉及写设备的
  候选受 RECOVERY 先行硬序约束(route-b-plan 全局规则);
- 依赖 S3 或推断的任何结论标注【待真机确证】,不得伪装成已确证事实。

## Approval

- Proposal 经 PR #86 合入 main
  (`0f9661656f698b8481afbf00f651afd84a6c6bb3`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由 approval-only PR #89(先例 #14/#40/#55)将本 change 置为
  `approved`;维护者 review/merge commit
  `44557376992fff509ea6ebbbbe0160277afbf804` 构成批准。本批准不产生任务执行:
  TASK-FA-001 的第②前置(TASK-PD-002 done + fresh platform evidence 合入 main)未满足,
  任务保持 blocked(先例:CHG-2026-008 approve 后 TASK-UD-001 继续 blocked 等
  M1-006);两前置齐备后另需独立 readiness/status PR 转 ready;doc-only 边界
  不因批准改变。
- Revision r2(2026-07-19):CHG-2026-009@r4 已由维护者经 PR #116 合入 `main`
  `7585603d459ae26ad566b9aaeecc953f9c26bd98`，把 codec remediation 与 fresh platform
  mapping/reconciliation 分别交给 TASK-PD-001/TASK-PD-002。r2 只把本 change 的上游
  evidence owner、逐行锚点与 readiness dependency 对齐到 TASK-PD-002；不改变两项 AC 的
  method/minimum evidence、任何地址数值或未知项处理，不执行 TASK-FA-001、不生成/rejudge
  evidence、不改变 gap/DEC-002/compatibility/support/hardware/release 状态，也不使任务 ready。
  r2 仅在维护者 review/merge 本 revision PR 后生效。

## Verification closure(2026-07-20)

- 两项 change-local AC 全 `passed`:`ADDR-DAYU200-MAPPING-001` 与
  `ADDR-DAYU200-OBSERVATION-PLAN-001`——TASK-FA-001 done(research/evidence PR #167
  `f9b74cc`、状态 PR #168 `03e975b`),`flash-address-facts.md` 五节 document review
  二值 PASS(§2 15 数值行逐行锚定 TASK-PD-002 partition-mapping.json,PD-002 未覆盖项
  显式 unknown,S2/S3 分级,§4 写设备候选标第二阶段 RECOVERY 先行)。
- 上述 PR 的维护者 review/merge 构成 verification.md acceptance matrix 所要求的
  confirmation。本文件的 `status: verified` 仅在包含本状态变更的 verification closure
  PR 经维护者 review/merge 后生效;verified 不改变 evidence 边界——事实清单为 doc-only
  结论、non-authoritative,不解除 `GAP-DAYU200-FLASH-ADDRESSES`、不改变 DEC-002,
  不构成兼容性/支持/release 声明或执行授权。archive 由后续独立 archive PR 完成
  (先例 #49)。

## Archive

本 change 于 2026-07-20 verified(verification closure PR,#176)后经本独立 archive
PR 归档:目录整体移入
`openspec/changes/archive/2026-07-20-chg-2026-012-dayu200-flash-addresses-research/`,
`status: archived` 仅在维护者 review/merge 本 PR 后生效(先例 #49/#88)。本 change
class 为 platform、`core_change_level: none`:归档不涉及任何 spec/contract/baseline/
conformance 变更,无 ratification 成分。`evidence/flash-address-facts.md` 自归档位置
继续作为 DEC-002 决策与 Route-B 地址研究的只读输入;non-authoritative 边界与
`GAP-DAYU200-FLASH-ADDRESSES`(保持 open)不变。

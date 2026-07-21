---
id: CHG-2026-016-dayu200-recovery-rehearsal
revision: 4
status: archived # 2026-07-21 archive PR(先例 #178;目录外零精确路径引用,DEC-002/chg-020 均名称引用不断链);verified 于 #224。原注: 2026-07-21 本 verification-closure PR(先例 #175/#176/#201/#208);r1-r4 批准链 #170/#171/#177/#214/#216;须在 RH-001 done #221 与 gap-closure #223 之后合入;archive 另行
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# DAYU200 恢复演练:首次授权的写设备活动(关闭 RECOVERY gap 的载体)

## Why

route-b-plan(CHG-2026-007)的全局硬序是 **RECOVERY 先行**:任何写设备活动(含使
设备进入 Maskrom/Loader 态)都要求 `GAP-DAYU200-RECOVERY-PATH` 先关闭;而唯一能
关闭它的就是恢复演练本身——由维护者亲手把 pinned 镜像经 `rkdeveloptool` 烧回
DAYU200,证明"设备不可启动 → 可恢复"的路径真实可行。CHG-2026-010 恢复预案
(archived)第 6 节明文要求:演练 change 立项时须自归档路径**原文引用检查单并逐项
打勾**(本文件下节照办)。

演练的全部准备件已就绪:CHG-2026-013 TASK-RR-001 done(rkdeveloptool 1.32 构建,
产物 SHA-256 `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`;
pinned 归档 17/17 成员 hash MATCH;记录模板就绪)、TASK-PD-002 done(#164/#165,
分区映射唯一权威 evidence)、TASK-FA-001 done(#167/#168,寻址语义与地址表)、
RISK-001 风险接受在案(open-questions.md,#97/r2)。

本 change 同时**搭载两组免费只读观察**(设备已处 Maskrom/Loader 态窗口内):模式
判别观察(`ld` 输出形态、USB PID)与分区表读回(`ppt` vs FA-001 §2 基线逐行比对)
——它们正是 DEC-002 尚缺的"第二阶段真机模式确认"输入,一个设备窗口同时喂
RECOVERY gap 与 DEC-002。

## What changes

### In scope

- `TASK-RH-001`:人类维护者按 CHG-2026-010 预案 §4 步骤序列在具名设备窗口内执行
  恢复演练(进 Maskrom → `db` loader → 写分区表与分区镜像 → 复位验证正常启动),
  全程逐命令记录;搭载 Maskrom/Loader 模式观察与 `ppt` 分区表读回比对。
- **封闭写命令面**(design.md 硬门,唯一授权面):`rkdeveloptool` 的
  `-v`/`ld`/`ppt`(读)与 `db`/`gpt`/`prm`/`wlx`/`wl`/`rd`(写,argv 形态与写序见
  design.md);postcheck 只读验证沿 `scripts/m0b_capture` 既有白名单。超出此面的
  任何设备命令一律禁止。
- Evidence:`hardware-evidence.json`(schema 2.0.0,provider none,先例 M0B)+
  run.md + 脱敏 transcript + §6 检查单打勾页 + 逐命令 argv/输出记录;序列号字节
  只入 hardware-evidence device identity 字段;raw 全量留仓库外。

### Out of scope

- ArkDeck 产品 `flash` 能力/真实 FlashProvider 实现(属 DEC-002 决策后的独立
  integration change);DEC-002 决策本身;任何 Core/spec/contract/产品代码变更;
  gap 关闭与 DEC-002 input 的正式登记(演练 evidence 合入后另行 governance PR,
  先例 #146);hardware matrix 支持声明(演练只产生 observed 行事实)。

## CHG-2026-010 §6 演练前置检查单(原文引用;立项时点打勾状态)

> 引自 `openspec/changes/archive/2026-07-18-chg-2026-010-dayu200-recovery-playbook/evidence/recovery-playbook.md` §6:

- [x] 恢复物料本地就绪,且逐文件全量 SHA-256 与 member-inventory.json 一致
  (TASK-RR-001:17/17 MATCH,物料在维护者本机仓库外受控目录;readiness 时复核);
- [x] `rkdeveloptool` 已在演练主机构建完成,`ld` 对无设备场景输出正常
  (TASK-RR-001:ver 1.32,无设备 `ld` = `not found any devices!` byte-exact 在案);
- [x] TASK-PD-001 分区解码 evidence 已合入 main(分区偏移权威来源)
  (经 CHG-2026-009 r4 拆分重锚定:数值权威=TASK-PD-002 fresh platform mapping,
  #164/#165 done;绑定 PD-001 r4/r5 implementation identity);
- [ ] 维护者书面确认:接受演练期间设备变砖乃至不可恢复的残余风险
  (载体=readiness PR 的维护者 review/merge + readiness 文本中的确认句);
- [ ] 维护者时间窗明确,窗口内无其他设备操作并行(readiness 时具名);
- [x] 中止预案(第 5 节)已读并同意;演练记录模板就绪(逐命令 argv/输出)
  (模板=TASK-RR-001 交付物,含 §5 中止准则原文与打勾页;"已读并同意"随
  approve/readiness 的维护者 review/merge 生效);
- [x] 若需 Windows/RKDevTool 备选路径:备选主机与工具就绪(可选项)
  (本演练不启用备选路径;如中止后需要,另行 revision——该可选项显式记为不启用)。

## Approval

- r1 proposal 经 PR #170 合入 main(status:proposed)。
- 正式批准:2026-07-20 由本 approval-only PR(先例 #55/#89)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。本批准不产生任务执行:
  `TASK-RH-001` 保持 `blocked`,须独立 readiness PR(§6 第 4/5 项打勾——书面风险
  确认+具名时间窗——与执行时 pins 复核)转 `ready`,执行仍需在具名设备窗口内由
  维护者亲手进行。

## Revision r2(2026-07-20)

RH-001 首窗口 blocked-attempt(#173)真机推翻 r1 的进态假设:按键得 `2207:5000`
(updater-hdc),rkdeveloptool RockUSB 不通。经 Oniro/HiHope 官方文档研究确认
**RockUSB Maskrom(`2207:350a`)可达**——r1 进态序列/时序不精确 + 脚本缺 sudo 是根因,
**非恢复路线错误**。r2 修正 design:§0 精确进态序列(权威原文)+ mode-gate(写前
`ld` 必须 `0x350a`,`0x5000` 即 STOP 重进)、§2 全部 rkdeveloptool 命令加 sudo。恢复
路线仍 rkdeveloptool RockUSB。TASK-RH-001 保持 `ready`(approve/readiness 与风险确认/
窗口不变),下一窗口按 r2 修正后的脚本重执行;#173 blocked-attempt 保持 immutable。
仅在维护者 review/merge 本 revision PR 后生效;不含实现/evidence/设备命令。

## Risk and boundary

- 最高风险=写错分区/偏移与中途断写:由封闭命令面、优先按名写入(`wlx` 靠设备侧
  分区表解析,fail-closed)、offset 回退路径零手算(仅取 FA-001 §2 的 PD-002 扇区
  列)、物料 hash 前置复核、§5 中止准则(连续 2 次失败即停等)覆盖;残余风险=设备
  变砖乃至不可恢复,已由 RISK-001 接受并须 readiness 书面确认。
- "MaskRom 是芯片固化态理论上始终可重入"(预案 §5,S2 Firefly)是演练风险可控的
  核心依据,**该论断本身待本演练确证**——如实记录,不预设结论。
- 版本后果(显式接受):演练完成后设备将运行 pinned 归档的 OpenHarmony
  7.0.0.33-20260713 build(现设备为 7.0.0.34);pinned build 自此成为设备参考态。
  `userdata` 写入会清用户数据,仅在演练现场显式确认后执行。
- 本 change 不构成兼容性/支持/release 声明;不解除除 RECOVERY 外的任何 gap;
  gap 关闭登记与 DEC-002 input 登记均属后续独立 governance PR。

## Verification closure(2026-07-21)

依 verification.md Gate 逐项复核(V2:整体结论由维护者 review/merge 本 PR 确认;须在
RH-001 done PR #221 与 gap-closure PR #223 之后合入):

- **任务面**:TASK-RH-001 done(独立状态 PR #221,依据 success evidence PR #220
  `3feacc3`)。演练经 #173/#213/#215/#217 四次 blocked-attempt + #218 研究,于 #220
  attempt #5 成功。
- **四 realHardware AC**(acceptance-cases.yaml 二值):
  - `RH-DAYU200-RECOVERY-001` **PASS(首次)**——进态→W1/W2 条件跳过→九个 PD-002
    mapped 分区经 Loader 态 `wlx` 全成功→`rd` OK→重启进系统→postcheck 58B
    `USB Connected localhost`;逐命令 argv/输出/判定在案。
  - `RH-DAYU200-MODE-001` observed——进态序列五窗口稳定(`0x5000 Maskrom`→`0x350a
    Loader`)。
  - `RH-DAYU200-TABLE-001`——写前 `ppt` 五窗口 15/15 精确 match FA-001 §2(逐字节
    一致);`wlx` 写分区数据不改分区表。
  - `RH-DAYU200-SAFETY-001` **PASS**——全部命令属 design §2 封闭面、pinned hash 复核、
    零现场手算、`userdata` 经显式 `ERASE-USERDATA` 确认、orphan/无成员分区/空洞零写入、
    序列号零入仓。
- **写设备唯一授权面**:全程未超出 design.md §2 命令白名单 + §3 写序;§5 中止准则在
  前四窗口正确执行。crib 脚本层缺陷(W2 heredoc 比对、postcheck 参数)如实入档且不
  触及命令面。
- **gap 关闭**:`GAP-DAYU200-RECOVERY-PATH` 经 PR #223 关闭并登记 DEC-002 input(真机
  纠正 #173 的 hdc/flashd 推测——rkdeveloptool RockUSB Loader 态 `wlx` 可行)。
- **边界**:本 `verified` 由维护者 review/merge 本 PR 构成。不构成 ArkDeck 产品 flash
  能力、兼容性、hardware support 或 release 声明;hardware matrix 只可新增 observed 行;
  正向全量烧写的 Provider 待 real-flash integration change 立项。archive 另行独立 PR。

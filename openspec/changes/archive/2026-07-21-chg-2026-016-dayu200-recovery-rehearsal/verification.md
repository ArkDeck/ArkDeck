# CHG-2026-016 Verification Plan

> Status:passed;maintainer confirmation 见 proposal.md Verification closure(2026-07-21)
> Change:CHG-2026-016-dayu200-recovery-rehearsal@r4
> Core baseline:CORE-2.0.0

本 change 是首次授权的写设备活动:唯一授权面 = design.md 封闭命令面,唯一执行者 =
维护者本人,唯一窗口 = readiness 具名的时间窗。任何超出命令面的设备命令、任何现场
手算地址、任何未复核 hash 的写入,出现即整体 fail。中止(§5 准则)如实记录为
blocked-attempt,不是 fail(先例 #104)。

> Revision r2(2026-07-20):RH-001 blocked-attempt(#173)后修正 design 进态序列
> (Oniro 权威原文)+ mode-gate(写前 `ld` 须 `0x350a`,`0x5000` STOP)+ sudo;恢复
> 路线仍 rkdeveloptool RockUSB。四 AC 的 expected result 不变;TASK-RH-001 保持
> `ready` 待下一窗口按 r2 脚本重执行。

> Status update(2026-07-20,随 r1-attempt #173 + r2 #177):approve(#171)/readiness
> (#172)已合入,TASK-RH-001 为 `ready`;首窗口 attempt(#173)blocked-attempt 记录在案
> (RockUSB 未达成,MODE partial/SAFETY pass);r2(#177)修正进态序列+mode-gate+sudo。
> 下表 Status 据此同步。本更新只同步账本,不构成新验证结论;change 级仍 `planned`。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| RH-DAYU200-RECOVERY-001 | maintainer-executed rehearsal(archived playbook §4 序列) | 一个具名窗口内完成 进态→db→gpt/prm→九个 PD-002 mapped 分区按序写入→复位;设备回正常系统,postcheck(m0b_capture 既有白名单)重现 Connected;逐命令 argv/输出/判定在案;§5 中止=诚实 blocked-attempt | **PASS(attempt #5 SUCCESS,#220 `3feacc3`)** — 进态→W1/W2 条件跳过→九分区 Loader 态 `wlx` 全成功(`Write LBA from file (100%)`/exit 0)→`rd` OK→重启进系统→postcheck 58B `USB Connected localhost`;逐命令 argv/输出/判定在案。前序 blocked-attempt #173/#213/#215/#217 如实在案 |
| RH-DAYU200-MODE-001 | 同窗口只读模式观察 | 进 Maskrom 前/态中/db 后各记 `ld` 输出形态与 USB VID:PID;CHG-2026-011 待确证项(RK3568 PID、Maskrom/Loader 判别字样)落为 observed 事实;只记录不改流程 | observed — 进态序列五窗口稳定(`0x5000 Maskrom`→`0x350a Loader`);attempt#5 印证板上 U-Boot Loader 升级态支持 wlx 写数据、拒 db/gpt(#220/#218) |
| RH-DAYU200-TABLE-001 | `ppt` 读回 vs FA-001 §2 基线逐行比对 | Loader 态 `ppt`(表写入前可读则读、写入后必读)逐行 match/mismatch/absent/extra 分类,原始值保留;差异不现场解释,标待后续分析;基线零改写 | PASS — 写前 `ppt` 五窗口 15/15 精确 match FA-001 §2(逐字节一致);attempt#5 W2 跳过 gpt(表已正确)、wlx 写分区数据不改分区表,故表最终态 = 写前 15/15 |
| RH-DAYU200-SAFETY-001 | 封闭面与隐私合规审计(全窗口) | 全部设备命令属封闭面且计数在案;首写前物料/工具 hash 全部复核;零现场手算地址(wl 回退逐值引 FA-001 PD-002 扇区列并记原因);userdata 显式确认或如实记跳过;orphan 镜像与无成员分区零写入;序列号仅入 hardware-evidence identity,raw 留仓库外;中止准则触发即遵守 | PASS(attempt #5 全流程,#220)— 全部命令属封闭面、pinned hash 复核、零现场手算、userdata 经显式 `ERASE-USERDATA` 确认、orphan/无成员分区/空洞零写入、`rd` 后正常启动、序列号零入仓 |

## Gate

- **写设备唯一授权面**:design.md §2 命令白名单+§3 写序;§5 中止准则对操作者有
  约束力。第 4/5 项检查单(书面风险确认、具名窗口)在 readiness PR 打勾后任务才
  `ready`。
- **RECOVERY 硬序的自指说明**:本演练即关闭 `GAP-DAYU200-RECOVERY-PATH` 的载体——
  它自身是该 gap 关闭前唯一被授权的写设备活动;gap 关闭登记与 DEC-002 input 登记
  在演练 evidence 合入后走独立 governance PR(先例 #146),本 change 不自行登记。
- 不构成 ArkDeck 产品 flash 能力、兼容性、hardware support 或 release 声明;
  hardware matrix 只可新增 observed 行(M0B 先例)。
- 版本后果显式在案:演练后设备运行 pinned 7.0.0.33 参考态;`userdata` 清数据须
  现场显式确认。

> Revision r3(2026-07-21):基于 attempt #2(#213)真机事实——r2 进态序列实证有效但
> 设备直接落 Loader 态,W1 `db` 按协议被拒。r3 仅 ① W1 条件化(写前 `ld` 显
> `0x350a`+`Loader` 即判定点满足、跳过并记录;`Maskrom` 才必须 db)② W2 确认 `gpt`
> 主路径(GPT 分支经 ppt 15/15 实锤)。四 AC 的 expected result 不变;上表 Status 依
> #213 同步;TASK-RH-001 保持 `ready` 待下窗口按 r3 执行(从 W2 起)。

> Revision r4(2026-07-21):基于 attempt #3(#215)——loader 命令子集拒 `gpt`(与 db
> 同族),而写前 `ppt` 两窗口均 15/15 精确 match FA-001 §2。r4 仅 W2 条件化(写前表
> 精确 match 即判定点满足、跳过并记录;不 match 才必须 gpt)。四 AC expected result
> 不变;已知风险:`wlx`/`wl` 或同在子集外,两者均被拒则 Loader 路线不可行、Maskrom
> 裸态进态另立 revision。TASK-RH-001 保持 `ready`,下窗口从 W3 起。

> Status update(2026-07-21,随 TASK-RH-001 `ready→done` 独立状态 PR):上表四行依
> attempt #5 SUCCESS evidence(#220 `3feacc3`)同步——RECOVERY-001 `PASS`(首次)、
> MODE-001 observed、TABLE-001 写前 15/15、SAFETY-001 PASS。本更新只同步账本;gap 关闭
> 登记与 DEC-002 input 登记走独立 governance PR(Gate 明确,先例 #146),change 级
> verify 另行;不构成 conformance/hardware support/release claim。

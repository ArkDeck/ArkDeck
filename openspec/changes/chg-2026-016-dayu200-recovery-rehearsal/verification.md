# CHG-2026-016 Verification Plan

> Status:planned
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
| RH-DAYU200-RECOVERY-001 | maintainer-executed rehearsal(archived playbook §4 序列) | 一个具名窗口内完成 进态→db→gpt/prm→九个 PD-002 mapped 分区按序写入→复位;设备回正常系统,postcheck(m0b_capture 既有白名单)重现 Connected;逐命令 argv/输出/判定在案;§5 中止=诚实 blocked-attempt | attempt#1 blocked(#173:RockUSB 未达成);attempt#2 blocked(#213:W1 db 按态被拒);attempt#3 blocked(#215:W1 条件跳过生效,W2 gpt 按 loader 命令子集被拒,零写入,§5 自动中止);TASK-RH-001 ready,待下窗口按 r4(W1+W2 条件化)从 W3 wlx 起执行 |
| RH-DAYU200-MODE-001 | 同窗口只读模式观察 | 进 Maskrom 前/态中/db 后各记 `ld` 输出形态与 USB VID:PID;CHG-2026-011 待确证项(RK3568 PID、Maskrom/Loader 判别字样)落为 observed 事实;只记录不改流程 | observed 实质补全(#173:2207:5000 updater-hdc;#213:r2 序列→2207:350a Loader 稳定达成,进态路径实证);写序中 post-db 观察点随 r3 W1 条件化顺延 |
| RH-DAYU200-TABLE-001 | `ppt` 读回 vs FA-001 §2 基线逐行比对 | Loader 态 `ppt`(表写入前可读则读、写入后必读)逐行 match/mismatch/absent/extra 分类,原始值保留;差异不现场解释,标待后续分析;基线零改写 | 写前读回达成(#213:Loader 态 ppt 读出 GPT 表,15 match/0 mismatch/0 absent/0 extra vs FA-001 §2,GPT 分支实锤);写后读回待下窗口 |
| RH-DAYU200-SAFETY-001 | 封闭面与隐私合规审计(全窗口) | 全部设备命令属封闭面且计数在案;首写前物料/工具 hash 全部复核;零现场手算地址(wl 回退逐值引 FA-001 PD-002 扇区列并记原因);userdata 显式确认或如实记跳过;orphan 镜像与无成员分区零写入;序列号仅入 hardware-evidence identity,raw 留仓库外;中止准则触发即遵守 | attempt#1/#2 均 PASS(#173;#213:db/ld/ppt 全属封闭面、pinned hash 复核、零手算、零写入、§5 正确中止、序列号零入仓);待写入窗口全流程复评 |

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

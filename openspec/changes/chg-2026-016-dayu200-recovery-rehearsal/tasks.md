# Tasks — CHG-2026-016 DAYU200 恢复演练

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后生效。
> 全部设备操作由人类维护者亲手执行;Agent 零设备命令(脚本起草/核验/evidence
> 起草,M0B 先例)。写设备唯一授权面 = design.md 封闭命令面。

## TASK-RH-001 — 恢复演练执行(首次授权写设备;含模式/分区表观察搭载)

- Status:blocked(双前置:①本 change 经 approval-only PR 置为 `approved`(未满足);
  ②独立 readiness PR 完成 §6 检查单第 4/5 项打勾(书面风险确认+具名时间窗)并复核
  执行时 pins(未满足)。两前置齐备后任务转 `ready`;执行仍须在具名设备窗口内由
  维护者亲手进行,窗口外任何写设备 dispatch 均为 `0`)
- Requirements/AC:`RH-DAYU200-RECOVERY-001`、`RH-DAYU200-MODE-001`、
  `RH-DAYU200-TABLE-001`、`RH-DAYU200-SAFETY-001`(见 acceptance-cases.yaml)
- Depends on:CHG-2026-010 恢复预案 archived(§4 步骤/§5 中止/§6 检查单,已满足);
  CHG-2026-013 TASK-RR-001 done(工具构建+物料 17/17,已满足);TASK-PD-002 done
  (#164/#165,分区映射权威,已满足);TASK-FA-001 done(#167/#168,寻址语义与
  地址基线,已满足);RISK-001 风险接受在案(#97/r2,已满足);approval-only PR 与
  独立 readiness PR(未满足)。
- Allowed paths:
  - `openspec/changes/chg-2026-016-dayu200-recovery-rehearsal/evidence/**`
  - 本 `tasks.md`(仅本任务状态与 completion evidence)
  - `openspec/verification/hardware-matrix.md`(仅新增 observed 行,M0B 先例)
- Forbidden paths:产品代码、`Packages/**`、`scripts/**`(m0b_capture 只读使用不
  改写)、`openspec/specs/**`、`openspec/contracts/**`、其他 change/task evidence、
  integration registry/profile/lock;设备侧=design.md 命令面之外的一切命令。
- Risk:high(写设备;残余风险=设备变砖乃至不可恢复,RISK-001 已接受+readiness
  书面确认;版本后果=设备转入 pinned 7.0.0.33 参考态;userdata 清数据须现场显式
  确认)。
- Hardware required:yes(物理 DAYU200 + USB;操作者=维护者本人)。
- Deliverables:`evidence/runs/TASK-RH-001/run.md`(逐命令 argv/输出/判定、§6 打勾
  终态、观察搭载记录、偏差与残余风险)+ `hardware-evidence.json`(schema 2.0.0,
  provider none)+ 脱敏 transcript + `ppt` vs FA-001 §2 逐行比对表;raw 全量留
  仓库外;序列号仅入 hardware-evidence device identity。
- Verification:四个 Test ID 按 acceptance-cases.yaml 二值判定;任何写命令超出
  design.md 命令面、任何数值现场手算、任何 hash 未复核即写入,均整体 fail;中止
  即如实记录为 blocked-attempt(非 fail,先例 #104)。
- Evidence gate:四个 Test ID 同一次窗口 run 全部可判定后,evidence PR 合入 main;
  `ready→done` 另用独立状态 PR。done 后 `GAP-DAYU200-RECOVERY-PATH` 关闭登记与
  DEC-002 input 登记走后续独立 governance PR(先例 #146)。
- PR boundary:一个 evidence-only PR(维护者亲手执行,Agent 核验/起草);
  `blocked→ready`、`ready→done` 各用独立 PR;中止后修订走独立 revision PR。

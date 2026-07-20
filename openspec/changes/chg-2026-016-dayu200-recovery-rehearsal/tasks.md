# Tasks — CHG-2026-016 DAYU200 恢复演练

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后生效。
> 全部设备操作由人类维护者亲手执行;Agent 零设备命令(脚本起草/核验/evidence
> 起草,M0B 先例)。写设备唯一授权面 = design.md 封闭命令面。

## TASK-RH-001 — 恢复演练执行(首次授权写设备;含模式/分区表观察搭载)

- Status:ready(readiness candidate;仅在维护者 review/merge 本独立 readiness PR
  后生效。本 PR 不执行演练、零设备命令、零 evidence)
- Readiness review(2026-07-20;host-only,零设备/写命令 dispatch;§6 检查单双前置
  与执行时 pins 逐项复核):
  - Approve gate:satisfied。CHG-2026-016 approved(approval-only PR #171 合入
    main `cfb2040`);design.md 封闭命令面/写序/中止准则、版本后果与 4 个
    realHardware AC 均随批准生效。
  - §6 检查单第 4 项(书面风险确认):**satisfied**。维护者 2026-07-20 书面确认,
    逐字记录:「我确认接受演练期间设备变砖乃至不可恢复的残余风险」(RISK-001
    风险接受在案之上的本演练具体确认;载体=本 readiness PR 的维护者 review/merge)。
  - §6 检查单第 5 项(具名时间窗):satisfied。维护者授权时间窗 = 「随时」——即
    approve 后由维护者自选的首个连续设备窗口,窗口内无其他设备操作并行(design §5
    同型规则);执行前在 run.md 记录实际日期/时段。
  - Execution-time pins(本 readiness 于 main `cfb2040` 实测复核):
    - `rkdeveloptool`:`~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool` SHA-256
      `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`(与
      TASK-RR-001 pinned 值一致)、`-v` = `rkdeveloptool ver 1.32`;
    - 物料:`~/dayu200-rehearsal/materials/` 17/17 成员逐文件全量 SHA-256 vs
      archived `member-inventory.json` = **17 MATCH / 0 FAIL / 0 MISSING**;
    - Developer Mode:`DevToolsSecurity -status` = enabled(M1-006 线已启用,演练
      不依赖但如实记录环境);
    - 分区地址基线:FA-001 §2 表(15 行锚定 PD-002 `partition-mapping.json`
      `965e3bf3…`)于 main 在案,不改写。
    执行时须在首写前对上述工具/物料 hash **再复核一次**(design §1);任一漂移即停。
  - Review boundary:本 readiness 只翻转状态并打勾 §6 第 4/5 项、记录 pins;实现
    仍须满足全部 AC/verification gate(封闭命令面、写序、§5 中止、隐私、observed 行
    边界);`ready→done` 另用独立状态 PR;执行由维护者亲手进行,Agent 零设备命令。
- r1 attempt + r2 correction(2026-07-20):首窗口执行(#173)为 blocked-attempt——
  按键得 `2207:5000`(updater-hdc),rkdeveloptool RockUSB `db` 建 comm 失败;设备零
  字节写入、经重启完整恢复。经 Oniro/HiHope 官方文档确认 RockUSB Maskrom(`0x350a`)
  可达,r2 修正 design 进态序列+mode-gate+sudo(见 design §0/§2 与 proposal r2)。
  TASK-RH-001 保持 `ready`(approve #171/readiness #172 的风险确认与窗口不变),下一
  窗口按 r2 修正后脚本重执行;#173 blocked-attempt record 保持 immutable。
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

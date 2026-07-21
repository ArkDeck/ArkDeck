# TASK-RF-002 真机验收 — `arkdeck flash` 产品路径 SUCCESS(2026-07-21)

- Change:CHG-2026-020-dayu200-real-flash / Task:TASK-RF-002
- Class:realHardware(人类维护者亲手执行,REQ-FLASH-015;Agent 零设备命令、零
  destructive dispatch,只起草 crib/事后核验/起草本 evidence)
- 窗口:2026-07-21 16:48–17:03(单一连续窗口,无其他设备操作并行);operator = lvye
- 实现基线:main `32908a9`(PR #236 squash;crib P0 以 merge-base gate 强制)
- 脱敏 transcript:`transcript-accept-2026-07-21.txt`;原始产物(含设备序列号)留仓库外
  `<HOME>/dayu200-rehearsal/run-rf002-20260721-164851/`(先例:RF-001 part 2)

## 执行形态

维护者亲手运行验收 crib `accept-rf002.sh`(窗口时 sha `a8fa173e…`,窗口后修 observation
聚合缺陷 → `18c09ee4…`,见 §3),完整走 arkdeck 产品路径:

P0 身份门 → P1 非 TTY execute 负样 → P2 planOnly → P3 §0 进态 + `ld` mode-gate →
P4 交互 execute(prerequisites 问询 + 双重 destructive 确认 → authorizedForHumanExecution
+ handoff)→ P5 handoff 逐条亲手执行(ppt 15/15 → wlx×9 → rd)→ P6 postcheck +
`arkdeck flash postflight` 语义判定。

Pins 全部复核通过:rkdeveloptool 1.32(`038a8a0e…3611`)、pinned `images.tar.gz`
(`fc7637f3…5280`/732948803,整包 + materials/ 17 成员双重复验)、arkdeck release
二进制(`95c25873…`,构建自 `32908a9`)。

## 1. 判定:RF-ACCEPT(realHardware)= **PASS**

产品链路端到端:validate(732MB 流式全量)→ exact plan(execute digest
`c85be3b3…cff`)→ prerequisites → `FLASH c85be3b34ae6` + `ERASE-USERDATA` →
authorizedForHumanExecution → handoff → 人工九分区 wlx 全 `Write LBA from file (100%)`/
exit 0 → `Reset Device OK.` → 重启进系统 → postcheck 58B `USB Connected localhost` →
`arkdeck flash postflight` = **succeeded / confirmed / exit 0**。

## 2. 认领 AC 的真机面结论(canonical method 均为 contract,#236 已全绿;本节为
realHardware 补充面)

| AC | 真机面观察 | 结论 |
| --- | --- | --- |
| AC-FLASH-001-01 | `ld` mode-gate 先行:`0x2207:0x350a Loader` 实测 PASS 后才进任何写;命令面全程封闭(`ld/ppt/wlx/rd`,零相似命令) | PASS(正样面) |
| AC-FLASH-002-01 | prerequisites 三问(loader/recoveryPath/unlocked)在 destructive 确认之前逐项问询并有实据(loader=ld 行) | PASS(正样面) |
| AC-FLASH-004-01 | planOnly 与 execute 两次运行的 plan 文档均落盘且 executionMode/digest 可辨识(69c30d21… vs c85be3b3…) | PASS |
| AC-FLASH-007-01 | destructive 确认在 exact plan 完整展示后逐字输入(计划 digest 短语 + ERASE-USERDATA);拒绝路径为 contract 已证(可选真机拒绝演示未执行) | PASS(正样面) |
| AC-FLASH-008-01 | 9 步 `criticalNonInterruptible` 写全程连续无中断(退出注入为 contract fault-injection 已证,真机不重演) | PASS(正样面) |
| AC-FLASH-012-01 | postflight #1 实测:仅凭全 exit 0 不判 succeeded——observation 缺语义 marker 时产品判 waitingForRecovery(见 §3,意外获得一次真机侧 fail-closed 正确性验证);marker 齐备才 succeeded | PASS(双向) |
| AC-FLASH-013-01 | postflight #1 non-succeeded 时 RecoveryGuide(CHG-016 Loader wlx 路径 + unknown 状态 + honest disclosures)完整呈现 | PASS |
| AC-FLASH-015-01 | P1 实测:非 TTY execute → `policyBlocked`/exit 3/受控 handoff、destructive dispatch 0 | PASS(产品面) |
| AC-FLASH-015-02 | 人工确认由产品在 TTY+operator 下逐字段构造并精确匹配后才 `authorizedForHumanExecution`;全程 Agent 零 dispatch | PASS(正样面;mismatch 面 contract 已证) |

## 3. 偏差与如实记录

1. **postflight #1 = waitingForRecovery(exit 5),#2 = succeeded(exit 0)**。根因是
   crib 的 observation 聚合缺陷(非设备、非产品):postcheck 目录按字母序全文件拼接后取
   尾 4000 字符,两个 manifest(6356B)把含 `Connected` 的探针 stdout 挤出窗口。修正 =
   聚合只取 `*.stdout` 探针流;`observation-corrected.json` 由**同一批真实 postcheck
   产物**重新聚合(设备侧数据零改动),两次判定与根因均在 transcript。产品语义门在
   #1 中的拒绝行为本身是 REQ-FLASH-012 的正确 fail-closed。
2. `--target-location-id` 操作者输入 `0x350a`(以 PID 值作位置标识);物理目标由
   mode-gate 行 `DevNo=1 Vid=0x2207,Pid=0x350a,LocationID=2 Loader` 佐证(本机本窗口
   唯一 RockUSB 设备)。binding digest 由该输入一致构造,gate 语义不受影响。
3. 可选的真机拒绝演示(AC-007)未执行(操作者选 no)——该 AC canonical method 为
   contract,已在 #236 全绿;真机面取正样。
4. crib 首版两处 heredoc/占位残写在窗口前自查修复;窗口后仅改 observation 聚合段。

## 4. 边界

- 本 evidence 不改 tasks.md 状态;`ready → done` 按流程另用独立状态 PR。
- 不构成 DAYU200 以外设备、其他固件/工具版本的支持声明;hardware-matrix 行升级见同
  PR 的 `hardware-matrix.md` 变更(`EVD-RF002-DAYU200-20260721-001`,verified)。
- Agent/CI destructive dispatch 全程 0(结构性 + 仪表化 + 本窗口实测)。

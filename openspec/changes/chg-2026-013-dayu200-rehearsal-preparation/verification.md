# CHG-2026-013 Verification Plan

> Status:passed;maintainer confirmation 见文末,candidate `verified` 在
> verification closure PR 合入后生效
> Change:CHG-2026-013-dayu200-rehearsal-preparation@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录
(acceptance matrix 的 Status 列保持起草期 `pending` 不改写,两项实际二值结论
以 `evidence/runs/TASK-RR-001/run.md` 为准:全部 PASS)。本
change host-only:执行期间 DAYU200 不得连接主机,任何设备交互的出现即整体
fail;命令面仅限 proposal「Execution boundary」封闭白名单。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| PREP-DAYU200-TOOLING-001 | evidence review + record audit | `rkdeveloptool` 自官方仓库源码在演练主机构建完成:源 URL+commit hash+产物 SHA-256 记录在案;`-v` 版本串 ≥1.32 如实记录;无设备 `ld` 输出 byte-exact 采集且为"无设备"形态(零设备枚举行);全部命令在封闭白名单内且逐命令记录 argv/输出/exit;成败判定基于输出标记非退出码 | pending |
| PREP-DAYU200-MATERIALS-001 | evidence review + hash audit | pinned 归档身份(732948803 bytes/SHA-256 `fc7637…5280`)全量重算一致;恢复物料成员逐文件全量 SHA-256 与 archived member-inventory.json 逐项比对制表(任何不一致如实记录并判 FAIL);物料字节不入仓;rehearsal-record-template.md 含逐命令 argv/stdout/stderr/exit/时间戳/判别点栏位、预案 §5 中止准则原文节与检查单七项打勾页 | pending |

## Gate

- 设备不在场硬前提:任何命令执行时 DAYU200 不连接;`ld` 输出出现任何设备
  枚举行即整体 fail 并中止本次执行。
- 封闭白名单硬边界:白名单外命令出现在记录中即整体 fail;网络仅限 Homebrew
  依赖与官方源码获取,逐下载记录 URL+hash。
- 本 change 不勾检查单第 3/4/5 项、不立项演练、不构成演练执行授权;打勾动作
  属未来演练 change 立项时(自归档路径原文引用检查单);不解除任何 gap、
  DEC-002 不变。

## Maintainer confirmation(2026-07-18)

- Approval:PR #91,维护者 `lvye` merge,merge commit `cfb86e7`;readiness:
  PR #92,merge commit `5eb8062`。
- Deliverable + evidence:PR #93,维护者 `lvye` merge,merge commit `30cca61`。
- Task `ready→done`:PR #94,维护者 `lvye` merge,merge commit `b71f7b0`。
- Confirmation scope:`TASK-RR-001` 交付物(prep-record + 演练记录模板)、两个
  `TEST-PREP-DAYU200-*` 的 run.md 二值结论(全部 PASS)、设备不在场
  attestation、封闭白名单遵守与输出标记判定,以及"仅提供检查单第 1/2/6模板
  项打勾 evidence、非演练授权"的边界;构建期发现 F1(PATH 上 SDK toolchains
  非 POSIX diff)已固化为模板前置检查 P4。
- 本 confirmation 满足 verified gate;不构成 archive,archive 由后续独立 PR
  完成(先例 #21/#49)。

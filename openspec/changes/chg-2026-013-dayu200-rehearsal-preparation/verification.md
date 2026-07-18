# CHG-2026-013 Verification Plan

> Status:planned
> Change:CHG-2026-013-dayu200-rehearsal-preparation@r1
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。本
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

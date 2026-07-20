# CHG-2026-014 evidence

CHG-2026-014 已 `verified`（PR #114）；TASK-RLC-001 implementation 经 PR #110 合入、
source-task dispositions 经 PR #112 记录、`done` 经 PR #113 翻转。
（2026-07-20 对齐：本段原文写于 implementation 之后、dispositions 之前，曾称"任务保持
`in_progress`"；时序以 git 历史为准。）

当前产物：

- `legacy-import-manifest.md`：三个固定 OID、34 个路径/blob disposition、未关闭 AC、
  runtime reachability 与 rollback；
- `runs/TASK-RLC-001/run.md`：四个 change-local Test ID 的二值结果与 headless 命令；
- 仅包含 headless fake/loopback/contract 结果，不包含真实 HDC、设备、GUI、硬件或 release
  evidence。

本目录不得复制或改写 M1-006/PD-001 既有 run；只使用完整 commit OID 与相对路径引用。

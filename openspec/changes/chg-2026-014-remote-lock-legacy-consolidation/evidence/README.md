# CHG-2026-014 evidence

CHG-2026-014 已 approved，TASK-RLC-001 的 headless consolidation implementation 已执行；
任务保持 `in_progress`，等待独立 source-task disposition governance PR 与维护者 review。

当前产物：

- `legacy-import-manifest.md`：三个固定 OID、34 个路径/blob disposition、未关闭 AC、
  runtime reachability 与 rollback；
- `runs/TASK-RLC-001/run.md`：四个 change-local Test ID 的二值结果与 headless 命令；
- 仅包含 headless fake/loopback/contract 结果，不包含真实 HDC、设备、GUI、硬件或 release
  evidence。

本目录不得复制或改写 M1-006/PD-001 既有 run；只使用完整 commit OID 与相对路径引用。

# Tasks — CHG-2026-003 DAYU200 image characterization

> V2 治理:本文件是任务的唯一事实源。change 尚为 proposed;approved 前任务不可执行。

## TASK-DAYU200-CHAR-001 — 只读流式扫描器与 DAYU200 镜像特征化

- Status:ready(待 change approved)
- Requirements/AC:CHAR-M0-DAYU200-IMAGE-001…(见 acceptance-cases.yaml,ARC001..ARC009)
- Depends on:none
- Allowed paths:`scripts/archive_characterization/**`、本 change `evidence/`(archive-identity.json、member-inventory.json、package-classification.json、process-audit.json、gaps 列表)
- Forbidden paths:产品代码、openspec/specs、contracts、governance 等(只读研究任务)
- Risk:low(纯本地只读;不解包落盘、不执行成员、无 shell/子进程)
- Hardware required:no(镜像文件为仓库外固定输入,记录 size+SHA-256)
- Deliverables:Python stdlib-only 的 `scan.py` + 四个封闭结果 schema + hazard fixtures + 分支完备的 `test_scan.py`;四份 evidence JSON 与 gaps 清单(`deviceFlashProvider: unknown`、`targetCompatibility: unknown` 为合法输出)。
- Verification:对 pinned 归档的流式只读扫描 + hazard 拒绝套件;身份等于 pinned size/SHA-256;物理序成员清单逐项含验证路径、regular kind、size、per-member SHA-256。

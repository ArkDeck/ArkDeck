# Tasks — CHG-2026-003 DAYU200 image characterization

> V2 治理:本文件是任务的唯一事实源。change 已于 2026-07-18 经维护者 merge
> approved(先例 #14/#40,批准由维护者 review/merge 构成;approval commit 与实现
> commit 经 PR #44 squash 合入 main `6c1ba7b`,手工堆叠 PR #45/#46 因与 #44 重复
> 已关闭);任务状态变更仅在维护者 review/merge 后生效。

## TASK-DAYU200-CHAR-001 — 只读流式扫描器与 DAYU200 镜像特征化

- Status:done
- Completion evidence:`evidence/runs/TASK-DAYU200-CHAR-001/run.md`(实现与全部
  evidence 已由维护者经 PR #44 合入 main `6c1ba7b`,2026-07-18。pinned identity
  二值命中;17 成员物理序 inventory 全 root-level regular 含逐成员 SHA-256;
  16 个 hazard 向量实测全部在分类前拒绝;六条件全真 →
  `imagePackageFamily: rockchipRawImageSet`,固定轴保持
  `fixedArchiveOnly`/`authoritative: false`/Provider 与 compatibility `unknown`/
  `candidateNonExecutable`;四个 gap(分区语义、烧写地址、协议、恢复路径)全
  `unknown` 已登记为 DEC-002 与 Route-B CLI 输入;tests 36/36、check-sdd 0 error。
  三个 AC(`TEST-CHAR-M0-DAYU200-IMAGE-001`、`TEST-CHAR-M0-DAYU200-CLASSIFICATION-001`、
  `TEST-CHAR-M0-DAYU200-NODISPATCH-001`)二值 passed。`ready→done` 由本独立状态 PR
  起草,仅在维护者 review/merge 后生效,不改变实现或 evidence 正文,不构成
  change verified、DEC-001/DEC-002 结论、M0B、硬件支持或任何 platform
  conformance/release claim)
- Requirements/AC:CHAR-M0-DAYU200-IMAGE-001…(见 acceptance-cases.yaml,ARC001..ARC009)
- Depends on:none
- Allowed paths:`scripts/archive_characterization/**`、本 change `evidence/`(archive-identity.json、member-inventory.json、package-classification.json、process-audit.json、gaps 列表)
- Forbidden paths:产品代码、openspec/specs、contracts、governance 等(只读研究任务)
- Risk:low(纯本地只读;不解包落盘、不执行成员、无 shell/子进程)
- Hardware required:no(镜像文件为仓库外固定输入,记录 size+SHA-256)
- Deliverables:Python stdlib-only 的 `scan.py` + 四个封闭结果 schema + hazard fixtures + 分支完备的 `test_scan.py`;四份 evidence JSON 与 gaps 清单(`deviceFlashProvider: unknown`、`targetCompatibility: unknown` 为合法输出)。
- Verification:对 pinned 归档的流式只读扫描 + hazard 拒绝套件;身份等于 pinned size/SHA-256;物理序成员清单逐项含验证路径、regular kind、size、per-member SHA-256。

# CHG-2026-018 Verification Plan

> Status:passed;maintainer confirmation 见 proposal.md Verification closure(2026-07-21)
> Change:CHG-2026-018-hdc-acceptance-applicability@r1
> Core baseline:CORE-2.0.0(目标 CORE-2.1.0)

本 change 零代码、零 spec 原文变更;验证面 = conformance manifest delta 的文档级二值核对 +
既有只读 guard。任何超出 design.md normative 草案的 delta、任何 canonical 111 条目变动、
任何以「缺 registry/缺 family」构成的排除,出现即整体 fail。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| CA-HDC-APPLICABILITY-001 | documentReview(manifest delta 逐项对照) | core-conformance.yaml 与 design.md 草案逐项一致:suite=CORE-CONFORMANCE-2.1.0;integration_conditional 恰含 AC-HDC-006-01/AC-HDC-009-01 两条且各自绑定 family、registry 路径、excluded_while、reactivation;rule 追加沉默不构成排除的 fail-closed 句;shared_inputs 补记 0.3.0 profile/registry/0.4.0 lock 且 0.2.0 条目保留;排除条件与 registry unsupported reason 及 provenance(#141/#155/#156/#159/#163)可逐字追溯 | passed(TASK-CA-001 done,实现 PR #197 squash `3e85073`;`evidence/runs/TASK-CA-001/run.md`) |
| CA-HDC-APPLICABILITY-002 | documentReview + guard(不弱化不变量) | acceptance-index.txt 与 canonical acceptance-cases.yaml 的 111 计数及全部条目字节不变;specs/** 零改动;两个 AC 仍在 index 中(未删除);REQ-HDC-006/009 义务原文未触碰;`./scripts/check-sdd.sh` 0 error/0 warning/111;git diff 改动面 ⊆ TASK-CA-001 allowed paths | passed(同上;guard 于合入版复跑 0/0/111) |

> Status update(2026-07-21,随 TASK-CA-001 `ready→done` 独立状态 PR):上表两行依
> merged 实现 PR #197(squash `3e85073`,与 review head 零树差)与
> `evidence/runs/TASK-CA-001/run.md` 翻转 `passed`。本更新只同步账本,不构成 change
> `verified`(另行独立 PR)或 ratification(archive PR)。

## Gate

本 change 成为 `verified` 的前提:两个 Evidence ID 均 PASS 且有 run 记录;CORE-2.1.0
baseline 草案在案;archive PR(=ratification)由维护者 review/merge。本 change 不翻转
TASK-M1-006 状态(缺口 ① 仍在),不构成 CHG-2026-002 verified、platform conformance、
hardware/support 或 release claim;macOS `conformance_status` 保持 `notStarted`。

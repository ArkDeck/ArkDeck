# CHG-2026-035 Verification Plan

> Change:CHG-2026-035-macos-rockchip-tool-architecture@r1
> Status:passed # 2026-07-25；证据与完整 OID 链见 proposal.md「Verification closure」；仅在维护者 review/merge 本 verification-closure PR 后生效
> Core baseline:CORE-2.1.0（零 Core delta）

## Environment

- protected `main` Git objects 与 GitHub exact review/merge metadata；
- #525 合入版 `TASK-RKFUI-001G` blocked run、sanitized receipt/hash；
- current ADR-0002、DEC-004/007、macOS profile、CHG-2026-026 r9 与适用
  Core specs/contracts；
- current Rockchip tool registry/provenance；
- 决策时最新的一手 Apple platform/distribution/helper 文档与 tool upstream、
  license/dependency/build 文档，记录 URL、版本/commit 与 retrieval date；
- host-only document review；不要求 App build、external process、USB 或硬件。

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| `RKTA-OPTIONS-001` | `documentReview` candidate matrix | 五类完整 end-state 对全部 mandatory criteria 有枚举结论、引用与事实/推断标记；unknown 不被猜成 pass | `TASK-RKTA-001` run + matrix |
| `RKTA-DECISION-001` | `documentReview` cross-file consistency | 恰选一个完整架构或明确 no-viable；ADR、DEC inventory、macOS profile 无冲突，rejected alternatives/risk/rollback/reopen 完整 | `TASK-RKTA-001` run + ADR diff |
| `RKTA-BOUNDARY-001` | `documentReview` authority/effect trace | 推荐路径明确 App root、authority minting、component、fixed tool/argv/file leases、process/device dispatch 与 durable outcome；plan-only/no-viable 明确零 dispatch | `TASK-RKTA-001` run + ADR diagram |
| `RKTA-HANDOFF-001` | `documentReview` scope/traceability | 后续 change 与 prerequisites 精确；Core/HDC/001G evidence/CHG-2026-026 状态不被静默修改；本任务 product/external/device effect = 0 | `TASK-RKTA-001` run + diff audit |
| `AC-FLASH-001-01` | applicability review | 未来 typed discovery/probe 所需的 tool execution seam 被明确，不把 unsupported/unknown tool 当空列表 | ADR requirement map |
| `AC-FLASH-005-01` | mode semantics review | plan-only 候选保留完整 non-executed plan 与零 mutation，不冒充 execute/success | ADR candidate row |
| `AC-FLASH-015-01` | zero-effect audit | 本 change 的真实 binding、device、destructive dispatch 与 hardware evidence 均为 0 | `TASK-RKTA-001` run |
| `AC-JOB-005-01` | process contract review | 所选 process path 只允许 exact executable identity + typed argv，无 shell/PATH/caller environment；no-process 结论明确不适用 | ADR boundary |
| `AC-UX-007-01` | permission/lifecycle review | helper/install/elevation/system-rule 权限不被静默扩张；需要变化时只形成后续 change gate | matrix + ADR |

## Negative and recovery tests

- 删除任一候选、criteria、source pin、rejected alternative、rollback 或 revalidation
  trigger，review 必须失败；
- 将 `unknown`/二手推断改成 `pass`、把 001F/001G metadata 结果外推为 child/USB
  capability、把 App 可访问文件外推为 child 可访问，review 必须失败；
- 让 bundled Rockchip component 改写 DEC-007 HDC bundling、让 plan-only 冒充 execute、
  或让非 Sandbox 方案绕过 DEC-004 reopen，review 必须失败；
- ADR/DEC/profile 任两处结论不一致，或后续 handoff 没有独立 approval/readiness，
  review 必须失败；
- diff 出现 App/package/entitlement/Xcode/script/spec/contract/CHG-2026-026/evidence
  改写，或 run 出现 process/network/USB/device/helper/install/system mutation，
  verdict 必须为 blocked/failed；
- evidence 做 secret/privacy scan；bookmark bytes、用户绝对路径、raw Sandbox log、
  device identifier、credential 与外部 binary 不得入仓。

## Evidence classification

- option matrix、ADR 与 cross-file review：`documentReview`；
- existing #525 sanitized run：只作为已合入 `platform/host-only blocked` 输入，不重分类；
- simulation、real hardware、real external tool：`not run`；
- proposal/approval/readiness 自身不构成任何 `RKTA-*` PASS。

## Deviations

任何 candidate 实现、probe 重试、真实工具/设备操作、entitlement/distribution 变更、
Core/spec/contract 修改或 CHG-2026-026 状态推进都不是允许的 deviation；发现后立即
blocked，并以独立 change/revision 处理。

## Accepted decision/evidence result

decision/evidence #530 exact reviewed head
`91a9cc3fa29303d78e1079b0e7f1f4210f51cd46` 已由 `lvye` APPROVED，并以
`94704827e541cc13c34da9395f5d9810b78cca17` 合入 protected `main`；下列
`documentReview` result 已成为 accepted evidence：

- outcome = `selected:bundledRockchipComponent`；
- matrix = `evidence/runs/TASK-RKTA-001/candidate-matrix.md`；
- run = `evidence/runs/TASK-RKTA-001/run.md`；
- ADR-0003、DEC-011、macOS profile、design/tasks/verification outcome 一致；
- 四条 `RKTA-*` 与五条适用 canonical AC 的 documentReview verdict = PASS；
- product/process/network/USB/device/helper/install/privilege/destructive effect = 0；
- Core/spec/contracts/registry、HDC external-first、CHG-2026-026 task/evidence/status
  零变化。

该 result 不证明 bundled component 已实现、可分发、可访问 USB 或可刷设备。
TASK-RKTA-001 已由独立 D0 status #532 exact reviewed head
`692e3e93ac340f585fb3de9e2a9aef958e9cd07b` 经 `lvye` APPROVED，并以
`d80027c5c766803b867cecdba7f558f7895da28c` 合入后确认 `done`。

## Result gate

- [x] `TASK-RKTA-001` 经独立 approval、readiness、decision/evidence 与 done PR 完成
- [x] 四条 change-local AC 与五条适用 canonical AC 均有可复查 documentReview 结论
- [x] ADR、DEC inventory、macOS profile 与后续 handoff 一致
- [x] Core/spec/contracts/registry、HDC 决策、CHG-2026-026 与 001G evidence 零未声明变化
- [x] product/process/network/USB/device/helper/install/destructive effect = 0
- [x] SDD、allowed-path、diff、secret/privacy checks 全绿
- [x] 本独立 verification PR 只翻状态并引用具体 merged run/decision evidence；
  整体通过结论仅在维护者对 exact head review/merge 后生效

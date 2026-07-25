# CHG-2026-035 Tasks

> r1 proposal PR 只登记 change package。它不批准任何候选、不创建 ADR、不修改
> platform/decision inventory，也不产生 execution evidence。正式 approval、D1
> readiness、decision/evidence 与 `ready → done` 分别使用独立 PR。

## TASK-RKTA-001 — 评估并决定 macOS Rockchip 工具执行架构

- Status:blocked（前置：r1 proposal 登记、独立 approval-only PR、独立 D1 readiness；
  proposal/approval merge 均不自动使本任务 ready）
- Platform:macos
- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-015`、`REQ-JOB-005`、`REQ-UX-007`
- Acceptance：`AC-FLASH-001-01`、`AC-FLASH-005-01`、
  `AC-FLASH-015-01`、`AC-JOB-005-01`、`AC-UX-007-01`、
  `RKTA-OPTIONS-001`、`RKTA-DECISION-001`、`RKTA-BOUNDARY-001`、
  `RKTA-HANDOFF-001`
- Depends on：CHG-2026-035 approval、independent readiness、PR #525 merge
  `2b15a53986054f0984a71a0f113a5a2b807c3914`
- Readiness input pins：由独立 readiness PR 从届时 protected `main` 固定；不得在
  proposal 中预填未来 blob/OID
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-007`、`AF-009`、
  `AF-010`、`AF-017`
- Production reachability：not applicable；本任务只做 host-side document review，
  不构造 App/CLI/fixture production route，不产生 authority 或 effect dispatch
- Trusted fact sources：protected-main Git objects 与 exact PR review/merge metadata；
  #525 sanitized receipt/hash；current specs/contracts、ADR/decision/profile、tool
  registry/provenance；带版本/URL/检索日期的平台与供应链一手文档。candidate 自报、
  未合入 branch、二手文章与聊天描述不能自证事实
- Allowed paths:
  - `docs/adr/0003-macos-rockchip-tool-execution.md`
  - `openspec/planning/open-questions.md`
  - `openspec/platforms/macos/profile.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/design.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/tasks.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/verification.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/evidence/**`
- Forbidden paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/verification/acceptance-index.txt`
  - `openspec/verification/acceptance-cases.yaml`
  - `openspec/changes/archive/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/**`
  - `.github/**`
  - `scripts/**`
- Risk:low（文档判断本身无 effect；错误结论会决定后续高风险产品边界，因此必须 D1）
- Hardware required:no

### Deliverables

- 一份 source-pinned candidate matrix，完整覆盖 selected external、bundled Rockchip
  component、XPC/broker/helper、plan-only handoff 与 distribution revisit；
- `ADR-0003`：唯一推荐 end-state 或明确 no-viable 结论、rejected alternatives、
  residual risks、revalidation triggers 与 rollback；
- 同步后的 DEC inventory 与 macOS profile，不与 ADR/Core/CHG-2026-026 互相矛盾；
- 一个后续 change handoff：精确列出必须先批准的 spec/ADR/entitlement/distribution/
  supply-chain/readiness gates、允许实现范围和仍禁止的真实 effect；
- `evidence/runs/TASK-RKTA-001/run.md`，记录输入 pins、资料版本、矩阵结论、diff、
  命令、AC verdict、偏差与全部 effect counter = 0。

### Verification

- `RKTA-OPTIONS-001`：五类 candidate envelope 与全部 mandatory criteria 均有
  `pass|fail|unknown|requires-new-change`、一手来源和事实/推断标记；
- `RKTA-DECISION-001`：结论恰为一个完整 end-state 或 no-viable；ADR、DEC inventory
  与 profile 一致，所有 rejected/unknown/reopen 条件显式；
- `RKTA-BOUNDARY-001`：结论给出 root→authority→component→process/device effect 与
  file/tool/provenance boundary；plan-only/no-viable 明确零 dispatch；
- `RKTA-HANDOFF-001`：后续实现/change 依赖封闭，HDC external-first、Core、
  CHG-2026-026 状态与 001G evidence 未被静默改变；
- `scripts/check-sdd.sh`、`python3 scripts/test_check_pr_paths.py`、
  `git diff --check` 全绿；allowed/forbidden path 与 secret/privacy scan 通过。

### Notes / handoff

- decision/evidence PR 不翻 `ready → done`；合入后使用独立 D0 状态 PR。
- 评估中不得 build/run probe、fixture、App 或外部 tool，也不得触碰 USB/设备/用户文件。
- 任一来源不完整、候选需要超出 allowed paths 的现行规则修改、或 concurrent PR
  overlap 时，任务回到 blocked 并先修订 change/readiness。
- TASK-RKTA-001 done 只完成架构选择，不授权实现。后续产品工作必须使用独立 approved
  change；CHG-2026-026 是否以及如何修订由该 handoff 再决定。

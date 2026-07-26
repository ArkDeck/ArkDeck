# CHG-2026-038 Tasks

## TASK-MPF-001 — 施加三项 protection delta 并双向取证

- Status:blocked（前置：① 本 change approval-only PR merge；② 独立 readiness PR
  钉定 before 状态的两个 SHA-256、after 期望 projection SHA-256、逐步命令与
  rollback。**执行者恒为 `lvye`，在 Agent 不可达的会话内亲手执行；Agent 零
  protection 写入。**）
- Platform:macos（GitHub 设置面；零产品/设备声明）
- Requirements/AC:change-local `MPF-DELTA-001`、`MPF-FLOW-001`
- Depends on:none
- In scope:`main` branch protection 的恰好三项 delta（`dismiss_stale_reviews`
  →false、`required_status_checks.strict`→false、`allow_force_pushes`→false）；
  执行前后 authenticated 全量 GET 与两类 SHA-256 比对；单命令合并流与 strict
  关闭后补偿控制的 evidence 记录。
- Out of scope:任何信任根开关（review count/CODEOWNER/enforce_admins/push
  restrictions/linear/required `guard`）；ruleset `19595282`；Deploy Key/App/
  凭据/任何其他 repository setting；`allow_deletions`/`block_creations`/
  `required_conversation_resolution`；auto-merge；governance 正文；
  Agent 执行 protection 写入。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/
  evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.github/**`、`scripts/**`、产品 source/tests、
  其他 change。
- Risk:low-medium（见 proposal「Risk」；只放宽两项摩擦开关、只收紧一项漂移，
  信任根零改动）。
- Hardware required:no。

### Deliverables

- 一次由 `lvye` 亲手执行的 protection 窗口，产出 before/after 双向 authenticated
  取证（full-GET 与 canonical projection 各两个 SHA-256）与逐字段 delta 证明；
- 单命令合并流（`gh pr review --approve && gh pr merge --squash`）在真实 PR 上
  的一次实证；
- strict 关闭后的补偿控制条款如实入档（Agent 请求 merge 前 rebase + 合成树
  全量套件，已实证 25 次）。

### Verification

- `MPF-DELTA-001`：after projection 与 readiness 钉定的期望 projection SHA-256
  逐字节相等；逐字段比对显示**恰好三项**变化，信任根七项（review count 1、
  CODEOWNER true、enforce_admins true、push users `[lvye]`、linear true、
  required check `guard`、allow_deletions false）前后完全一致；ruleset
  `19595282` 未被触碰（独立 GET 比对）。
- `MPF-FLOW-001`：一个真实 PR 以单命令流完成 approve+merge，且其审计记录完整
  （`lvye` APPROVED @ exact head、`mergedBy=lvye`、`auto_merge=null`、squash
  subject 携 `(#N)`）；main 前进后另一个 in-flight PR **无需** `Update branch`
  即可合入，approval 未被作废。

### Notes / handoff

- rollback = 以 before 值反向 PUT 三项并 read-back 复验 before projection
  SHA-256；PEM/App/Deploy Key/ruleset/其他 setting 一律不动。
- 本任务不携带 `Decision-Grade` 行：该行由维护者亲手撰写。**注意等级判定**：
  protection 写入属 D2（凭据/设置面、人类执行），不是 D0——即使标了 grade 也不
  应进入循环派发面，`Hardware required:no` 不代表机器可判定。
- 若执行期发现 before 状态与 readiness 钉定值不符（例如又有第三方改动），
  **零写入并重新 readiness**。

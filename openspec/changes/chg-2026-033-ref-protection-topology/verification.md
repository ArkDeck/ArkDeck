# CHG-2026-033 Verification Plan

> Change:CHG-2026-033-ref-protection-topology@r3
> Status:planned
> Core baseline:CORE-2.1.0（零 Core/Product behavior change）

## Environment

- fresh protected-main full OID；无 unresolved overlapping PR/control operation；
- 人类控制的 isolated Administration read/write session，只在 approved D2 window
  使用，完成后退出；session/credential 对 Agent 不可达；
- Agent runtime 仅持 repository Deploy Key 与 non-human read-only metadata access；
- legacy ordinary-PR creator 使用 `GITHUB_TOKEN`，repository default workflow
  permission 为 `read`，`.github/workflows/agent-pr.yml` 单独声明 Pull requests
  write；GitHub create+approve 组合 setting 为 true 时，endpoint category coverage
  与有效批准权威必须分开验证；
- 以下对象均有 canonical full before、exact after/rollback JSON 与 SHA-256：
  - ruleset `19595282`；
  - main branch protection；
  - repository merge/auto-merge settings；
  - actor/installation/deploy-key permission inventory；
- 无真实设备、HDC、Flash 或产品副作用。

## Acceptance matrix

| AC ID | Method | Expected result | Evidence |
| --- | --- | --- | --- |
| `RPT-BOUNDARY-001` | live ref matrix + authenticated read-back | Deploy Key 可 create/update/delete 单层与多层 `agent/**`；ordinary 与 `agentx/**` 拒绝；ruleset 保留 `~ALL`、creation/update/deletion 与仅人类 bypass | D2 receipt + ref transcripts |
| `RPT-MAIN-001` | protection read-back + PR/merge pilot + negatives | main 强制 PR、1 approval、CODEOWNER、`guard` 与 admin enforcement；push users 仅 `lvye`、teams/apps 空；force/delete/direct push 拒绝；合规 PR 正常无 bypass merge | before/after JSON + PR/check/review/merge/UI record |
| `RPT-IDENTITY-001` | credential/permission/route/authority inventory + live negatives | 无 Agent 可达 `lvye`；Deploy Key、Actions、integration 均 non-admin/non-CODEOWNER/non-bypass/non-main-push；共享 PR write category 如实登记，但 self-approval、有效 CODEOWNER approval、merge/auto-merge/admin 均拒绝或不可构造 | actor manifests + author/review/CODEOWNER facts + negative responses |
| `RPT-MIGRATION-001` | ordered execution/rollback review | branch protection 先于 ruleset main exclusion；每次 read-back/hash 通过；无双层同时缺失时刻；failure 以安全顺序恢复 | timestamped execution log |
| `RPT-AUDIT-001` | document review | 历史 evidence 不改写、current mechanism 明确 supersede；旧 HLR readiness 不可执行；enforcement/AGENTS 高层语义不变 | addendum + current-pointer diff |

### RPT-BOUNDARY-001

Deploy Key 能 create、update、delete 单层 `agent/<uuid>` 与多层
`agent/<segment>/<segment>/<uuid>`；ordinary ref、已有 ordinary ref 与
`agentx/**` 操作均拒绝。authenticated ruleset after 固定 active、`~ALL`、
creation/update/deletion、三项 exact exclusions 与仅 `lvye` bypass；不存在其他 actor。

### RPT-MAIN-001

main authenticated protection after 同时要求 PR、至少一项 approval、CODEOWNER review、
`guard` app ID `15368`、`enforce_admins=true`；push restriction users 恰为 `lvye`，
teams/apps 为空，force/delete false。未审批或 guard 非绿不能 merge；`lvye` direct push
拒绝；合规 PR 可正常 Squash and merge 且没有选择 bypass。

### RPT-IDENTITY-001

所有 Agent runtime、connector、browser、CLI、process、credential helper、keychain 与
secret store 中均无 `lvye` credential/session。每个 Agent identity 有稳定 ID、scope、
permission 与 route inventory。GitHub 的 Pull requests write category 可同时覆盖 create
与 review，不能伪称 category 不存在；必须证明普通 Agent PR 作者固定为
`github-actions[bot]`、作者 self-approval 被拒、任何 automation review 不满足
`@lvye` CODEOWNER、merge/auto-merge、main/ref update 与
repository/ruleset/branch admin route 不可构造或被 GitHub 拒绝。

### RPT-MIGRATION-001

完整 before/after/rollback canonical bytes/hash 可复现。旧 ruleset 覆盖 main 时先强化
branch protection；overlap negative 通过后才 exclusion main；read-back 后重复 negative
明确由 branch protection 拒绝。failure recovery 先分类 main 与两层保护：已知 exact
branch-protection after 且 main 未变时，先清理会被 old ruleset 阻断的 controlled Agent
refs，再恢复 ruleset coverage；main/protection 不确定时优先恢复或保留更严格 main
保护。全流程没有 main 同时失去两层保护的区间。

Ref mutation read-back uses an exact bounded convergence gate: successful Git
server receipt, two stable `ls-remote` observations and authenticated REST
must agree before advancing. A single immediate stale REST value is recorded,
not silently converted to success or immediate drift. Probe tip commits carry
`[skip actions]`; pinned workflow/event scans and live run/PR inventory prove
that temporary probes create no governance PR. When main protection is known
exact after and main is unchanged, controlled Agent refs are cleaned before
ruleset rollback; otherwise main recovery takes priority and residual cleanup
remains blocked.

### RPT-AUDIT-001

CHG-2026-027 历史 BAP evidence 原文不变，以 append-only note 指向新 current mechanism；
CHG-2026-030 与 runbook 不再把 ruleset 描述为 main 的 current enforcement。#435 的
OID/window/payload/hash/ref/UUID/script 明确不可执行。AGENTS.md 与 enforcement.md
高层不变量逐字不变。

## Mandatory verification matrix

- Deploy Key create/update/delete 单层 `agent/**`：成功。
- Deploy Key create/update/delete 多层 `agent/**/*`：成功。
- Deploy Key create ordinary ref：拒绝。
- Deploy Key update 已有 ordinary ref：拒绝。
- Deploy Key 操作 `agentx/**`：拒绝。
- Deploy Key direct-main，在双层 overlap 时：拒绝；仅作 safety gate。
- ruleset exclude main 后重复 direct-main：branch protection 明确拒绝。
- Agent/API identity 对自身 authored PR 的 review、有效 CODEOWNER approval、merge、
  enable-auto-merge、branch update、repository/ruleset/branch admin：全部拒绝或
  不可构造。共享 PR write category 的存在必须如实记录，不得升级为批准权威。
- 未审批 PR：不能 merge。
- `guard` pending/red：不能 merge。
- CODEOWNER approval + `guard` success：`lvye` 正常 Squash and merge，无 bypass。
- `lvye` arbitrary direct push main：拒绝，必须走 PR。
- 手工构造 merge commit、无 exact approved PR facts：拒绝。
- main force-push/delete：拒绝。
- merge 后 commit subject `(#N)`、review、mergedBy、merge OID 可审计。
- before/after/rollback JSON canonical bytes 与 SHA-256 全部复现。
- 每个 positive ref mutation 的 Git receipt、bounded `ls-remote`/REST convergence
  与 cleanup absence 可复查；没有 probe-triggered workflow/PR。
- #470 residual deeper ref 在 exact after-ruleset 下由 Deploy Key 删除；#471 保持
  closed/unmerged，且不会被复用。

## Negative and recovery tests

- bypass/push actor、team、app、custom role 缺失或多出；
- `guard` 未固定 app ID `15368`；
- after 中 `enforce_admins=false` 或公开投影仍为 `non_admins`；
- repository `allow_auto_merge=true` 或 merge queue enabled；
- Actions create+approve setting 为 false 却声称 legacy bot PR transport 可用；
- Actions create+approve setting 为 true 时，PR 作者不是预期
  `github-actions[bot]`、bot self-approval 成功、automation review 被计为
  `@lvye` CODEOWNER approval，或 workflow/default permission 超出 pin；
- 任一 Agent connector 报告 login `lvye`、`admin=true` 或 `push=true`；
- main、pinned blob/ref/PR/ruleset timestamp 在 exact subwindow 漂移；
- ruleset after 除 approved exclusions 外出现其他差异；
- branch protection full PUT 漏字段或放宽 unrelated stricter setting；
- negative probe unexpected success；
- API timeout/ambiguous outcome 后发生 blind retry；
- 单次 immediate REST stale value 被直接判成 drift，或在 bounded Git/REST
  convergence 未闭合时继续；
- positive probe tip 缺少 `[skip actions]`、workflow route/pin 漂移，或 probe
  产生 Actions run/PR；
- rollback 在已知 exact main protection 下先恢复会阻断 controlled ref cleanup 的旧
  ruleset，却未记录 residual；或为了 cleanup 延迟未知 main state 的 recovery；
- rollback 无法 authenticated read-back/hash；
- #449/r6 Agent-operated gateway 未由 CHG-2026-030 r7 supersede，或其他 PR 修改
  相同 ruleset/topology/credential authority 而未阻断。

任一 case 立即停止。ruleset 已改时先恢复 main coverage 并验证，再恢复其他 before；
failed response 与 unknown outcome 原样保存，不在同一 window 换 target name 继续。

## Evidence separation

1. Bootstrap recovery receipt/evidence PR：只记录 Actions transport setting
   read-back 与 bot-authored PR creation 恢复，不把它算作 topology PASS。
2. 从该 evidence merge 后的最新 protected main 起草独立 topology D2 readiness。
3. #470 fail-closed receipt/evidence #472：只记录历史事实；不构成 AC PASS。
4. r3 proposal revision → 独立 approval-only → fresh authenticated discovery →
   全新 topology D2 readiness；各门合入前下一成 PR 工作为 0。
5. Human topology D2 execution receipt/evidence PR：只记录事实，不改 task 状态。
6. 该 PR 在新 topology 下由 `lvye` approval、`guard` success 后正常 merge。
7. 第二个 operability-evidence PR 记录上一 PR 的 review/check/mergedBy/merge OID 与
   人类 no-bypass UI evidence。
8. 独立 task done PR。
9. BAP/HLR supersession 由 TASK-RPT-002 独立 readiness/implementation/done PR。

## Repository checks

- `scripts/check-sdd.sh`；
- `git diff --check`；
- change-local acceptance registry consistency；
- allowed/forbidden path audit；
- secret/private-path scan；
- canonical JSON/hash reproduction。

## Deviations

任何 deviation 必须写入 evidence 并由维护者在 PR review 中判断；不得用“更严格看起来
没问题”掩盖未按 exact readiness 执行。保留更严格状态用于 fail-closed recovery 时，
仍须把差异登记为 deviation，并保持任务 blocked 直至新 readiness。

## Result gate

- [ ] 五条 RPT acceptance 均有 merged、可复查 evidence
- [ ] 无 Agent surface 可以 `lvye` 身份行动
- [ ] hidden actor/完整 protection 不再由 public projection 推断
- [ ] CHG-2026-027 有 append-only current-mechanism addendum
- [ ] CHG-2026-030 有 fresh compatible HLR-002A readiness 或保持 blocked
- [ ] simulation/fake 未计入 live GitHub protection evidence
- [ ] 独立 verification PR 由维护者确认

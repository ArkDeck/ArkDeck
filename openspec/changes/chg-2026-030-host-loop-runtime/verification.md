# CHG-2026-030 Verification Plan

> Status:planned
> Change:CHG-2026-030-host-loop-runtime@r3
> Core baseline:CORE-2.1.0（零 Core/Product behavior change）

## Environment

- Protected `main`、受限 `agent/**` Deploy Key、
  `agent/host-loop/**` exclusive creator namespace、经维护者 D2 设置的非
  `GITHUB_TOKEN` PR/Issue identity，以及 macOS host 的 staging/scheduler receipts；
- GitHub PR/Issue/ref API 的 fixture double 与真实隔离 probe；无真实设备、HDC、
  destructive step、secret 或 raw API payload；
- 每次 live run 钉完整 base/head/lease/merge OID、PR/Issue URL、runtime/reviewer run
  ID 与 checks result。无法取得其中任一事实时该 lane 为 `blocked`。

## Acceptance matrix

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| HLR-ENVELOPE-001 | HLR-001, HLR-005 | contract + live | task-bound PR 在创建时含独立 `Task: TASK-*`、完整 base/head OID、grade、dependency、evidence、配置 attribution；每类缺失/歧义失败；proposal 用 `Task: none`；无固定厂商 attribution；首个 PR event 能供 MECH-004 读取 |
| HLR-LEASE-001 | HLR-002A, HLR-002, HLR-003, HLR-005 | D2 review + fault integration | legacy bootstrap 对 `agent/host-loop/**` 零 creator；PR/Issue identity 只有 Metadata read、Contents read、Pull requests write、Issues write，非 CODEOWNER/bypass；ref 只由 BAP-003 Deploy Key + ruleset 写；self-approval、main write、merge、admin probe 均拒绝；runtime typed adapter 无 generic/review/merge/admin route；remote lease acquire/renew/takeover 使用 exact OID fence；两个 owner、stale owner、heartbeat loss、cursor corruption 和 API timeout 全部停 lane/重协调，零 duplicate dispatch |
| HLR-WORKER-001 | HLR-002A, HLR-003, HLR-005 | contract + live | worker 只处理 approved+ready host-only task，在 `agent/host-loop/tasks/**` 创建/更新唯一 stable identity PR；reserved branch 零 legacy creator，首个 `pull_request` checks 实测存在且 metadata 已完整；legacy creator 仅在 live proof 后退出，rollback 可复查 |
| HLR-REVIEW-001 | HLR-004, HLR-005 | contract + live | reviewer run/worktree/session 独立且只读；missing/failed checks、`REQUEST_CHANGES` 或 `BLOCKED` 不入 batch；`APPROVE` 是独立 AI 预审记录而非 GitHub/human approval；零 auto-merge |
| HLR-RECOVERY-001 | HLR-004, HLR-005 | fault injection + live recovery | acquire、create、update、heartbeat、review、merge observation 各 crash window 可重启；仅 GitHub merge metadata 与 protected-main full OID 同时匹配才 advance/release；branch缺失、Issue声称 merged、CI绿、时间流逝均不通过 |

## Negative and recovery tests

- 短 OID、unknown D grade、multiple `Task:`、空 evidence without reason、硬编码 provider
  attribution、shell command interpolation → envelope validator failure；
- 双 worker/旧 fence/API timeout/lease ref 不存在或被篡改/Issue cursor 不能解析 →
  `reconcile-required`，不创建第二 PR、不开新 task；
- `GITHUB_TOKEN` creator、首个 check 缺失、legacy/new creator 同存、PR lookup 0 或 >1 →
  migration failure/rollback，不用人工编辑 body 掩盖；
- `agent/host-loop/**` 仍触发 legacy creator、普通 `agent/**` 被意外排除、reserved
  head 出现 0/2 PR、head guard 或 pull-request allowed-paths 缺失 → partition/activation
  failure；不以 branch cleanup 或 elapsed time 伪造零 creator；
- identity 成为 CODEOWNER/bypass、permission category/scope 超 pin、protected-main
  direct write / integration-authored PR self-approval / merge / admin same-value mutation
  任一成功、typed adapter 可构造 generic request 或 review/merge/admin route →
  撤销 identity、停 scheduler、overall failure；cleanup 不改变失败结论；
- reviewer 与 implementer 同 run/session/worktree、reviewer 尝试写 GitHub approval 或
  merge、checks pending/red、batch digest 不完整 → 不入队；
- merge OID 单源、branch delete、PR closed without mergedAt、network/clock uncertainty →
  不 release lease，不继续下游 D1/D2/实现；
- secret/private key/token、用户绝对路径、device identifier、raw API body 或 archive/
  canonical-governance/Core diff → overall failure。

## Repository checks

- runtime fixture/contract/fault suite；
- `agent-pr.yml` branch-filter contract test + implementation 合入后的普通 control /
  reserved canary live evidence；`sdd-guard.yml` byte-for-byte 零 diff；
- `scripts/check-sdd.sh`：0 errors / 0 warnings，acceptance count 以执行时 protected
  main 重新记录，禁止沿用陈旧数字；
- `git diff --check`、allowed/forbidden path audit、no-shell-string static scan；
- live PR body + first `pull_request` run + independent review + merge-OID cross-check；
- `changes/archive/**`、Core specs/contracts/governance canonical files、产品代码与设备
  evidence 的 diff 均为零。

## Result gate

本 change 仅在 HLR-001、HLR-002A、HLR-002、HLR-003、HLR-004、HLR-005 均由独立
implementation/evidence 与 done PR 合入，五条 acceptance 具备可复查正反证据，并且
D2 identity staging receipt 明示 `workerDisabled=true`、HLR-003 scheduler activation
receipt 绑定 exact source、first-check live proof、independent reviewer proof、
merge-OID recovery proof 全部在案后，才可起草单独的 `verified` PR。任何 CI green、
Issue cursor、lease、runtime log、AI review 或 batch digest 本身都不构成维护者批准
或自动 merge 授权。

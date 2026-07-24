# CHG-2026-030 Verification Plan

> Status:planned
> Change:CHG-2026-030-host-loop-runtime@r10
> Core baseline:CORE-2.1.0（零 Core/Product behavior change）

## Environment

- Protected `main`、受限 `agent/**` Deploy Key、
  `agent/host-loop/**` exclusive creator namespace、经维护者 D2 设置的非
  `GITHUB_TOKEN` PR/Issue identity，以及 macOS host 的 staging/scheduler receipts；
- CHG-2026-033 TASK-RPT-001 merged evidence 中 active ordinary ruleset 与 exact-main
  branch protection 的完整 authenticated before/after/rollback read-back、actor
  inventory、human-isolated execution receipt 与正负矩阵；raw human credential 对
  Agent/Deploy Key/App/Actions/integration identity 不可达；
- TASK-HLR-002B/#454 只作 superseded historical record；`scripts/host_loop/d2_gateway/**`
  absent，standing authorization/gateway/privileged dispatch 数为 0；
- GitHub PR/Issue/ref API 的 fixture double 与真实隔离 probe；无真实设备、HDC、
  destructive step、secret 或 raw API payload；
- 每次 live run 钉完整 base/head/lease/merge OID、PR/Issue URL、runtime/reviewer run
  ID 与 checks result。无法取得其中任一事实时该 lane 为 `blocked`。

## Acceptance matrix

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| HLR-ENVELOPE-001 | HLR-001, HLR-005 | contract + live | task-bound PR 在创建时含独立 `Task: TASK-*`、完整 base/head OID、grade、dependency、evidence、配置 attribution；每类缺失/歧义失败；proposal 用 `Task: none`；无固定厂商 attribution；首个 PR event 能供 MECH-004 读取 |
| HLR-AUTOCI-001 | HLR-001A | contract + live | routine `agent/**` push 以现有 `GITHUB_TOKEN` create-or-find 唯一 bot PR 后，exact-head `guard`、Swift、open-pr、PR-metadata/allowed-paths 全部自动完成，不需要 workflow approval；existing PR push 与 human metadata edit/reopen 均复验；零新 credential/secret/admin/review/merge route |
| HLR-LEASE-001 | HLR-002A, HLR-002, HLR-003, HLR-005 | D2 review + fault integration | legacy bootstrap 对 `agent/host-loop/**` 零 creator；消费 TASK-RPT-001 evidence 证明 ordinary ruleset 精确排除 single/multi-level Agent namespace 与 exact main、main branch protection 独立强制 PR/CODEOWNER/`guard`/admin enforcement/human-only push allowlist，Deploy Key 单层/多层成功而 non-agent/main 拒绝；PR/Issue identity 只有 Metadata read、Contents read、Pull requests write、Issues write，非 CODEOWNER/bypass；self-approval、main write、merge、admin probe 均拒绝；runtime typed adapter 无 generic/review/merge/admin route；task lease 使用 exact fence/CAS；两个 owner、stale owner、heartbeat loss、cursor corruption 和 API timeout 全部停 lane/重协调，零 duplicate dispatch |
| HLR-WORKER-001 | HLR-002A, HLR-003, HLR-005 | contract + live | MECH-004 title/body token 接受 active task-header grammar 的单字母 suffix 且 malformed/ambiguous token 失败；worker 只处理 approved+ready host-only task，在 `agent/host-loop/tasks/**` 创建/更新唯一 stable identity PR；reserved branch 零 legacy creator，首个 `pull_request` checks 实测存在且 metadata 已完整；legacy creator 仅在 live proof 后退出，rollback 可复查 |
| HLR-REVIEW-001 | HLR-004, HLR-005 | contract + live | reviewer run/worktree/session 独立且只读；missing/failed checks、`REQUEST_CHANGES` 或 `BLOCKED` 不入 batch；`APPROVE` 是独立 AI 预审记录而非 GitHub/human approval；零 auto-merge |
| HLR-RECOVERY-001 | HLR-004, HLR-005 | fault injection + live recovery | acquire、create、update、heartbeat、review、merge observation 各 crash window 可重启；仅 GitHub merge metadata 与 protected-main full OID 同时匹配才 advance/release；branch缺失、Issue声称 merged、CI绿、时间流逝均不通过 |

## HLR-001A r9 automatic-CI readiness

- Audit base:
  `0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07`。
- Trigger evidence:#480 initial bot head pull-request Swift/SDD runs
  `30096501384`/`30096501389` = `action_required`; final reviewed head after
  human branch update runs `30096750425`/`30096750430` = success.
- Source gate:exact pinned workflow/parser/test blobs from tasks.md;
  implementation uses no new credential and no GitHub setting.
- Expected implementation result:the implementation head receives successful
  push `guard`, Swift, open-pr and new allowed-paths without approving its
  duplicate old-base pull-request runs; create-or-find, exact PR metadata and
  permission/event contracts pass all offline negative fixtures.
- Expected post-merge live result:a fresh ordinary Agent evidence PR has no
  routine approval gate required for its checks; all four exact-head checks
  complete automatically, while human edit/reopen still revalidates.

## HLR-002A r10 canary readiness（current）

- Audit base:
  `47cec786315e79e0aad8a3209c6a7c600e6cfc60`。
- Dependency evidence:TASK-HLR-001A implementation #485 merge
  `cae9a4c378b75409a4d7a31205583560f17d73aa`、fresh live evidence #490
  merge `89ce135c109871c5428022ad0620a383430635dc` 与 done #495 merge
  `1815105971b5ec9bee58cb7be04cd759dc01a32b`。
- Current topology authority:CHG-2026-033 TASK-RPT-001 #476/#477/#478
  merged evidence；branch-protection projection/full SHA-256 =
  `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a` /
  `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`，
  ruleset projection/full SHA-256 =
  `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163` /
  `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`。
- Exact fresh refs:
  `agent/host-loop/probes/7e9bc001-c515-4aef-b3dc-c71d7f0124ee` and
  `agent/hlr-002a-control/4a2314d2-72c3-44f8-b579-606735e279b8`；
  evidence branch =
  `agent/task-hlr-002a-canary-evidence-r10`。
- Expected reserved result:exact-head push SDD Guard and Swift success;
  Agent PR run count = 0 and all-state exact-head PR count = 0, each queried
  twice using complete workflow-path/event/branch/head and PR pagination.
- Expected ordinary result:exact-head push SDD Guard and Swift success;
  exactly one successful Agent PR push run whose `open-pr` and
  `allowed-paths` jobs succeed; exactly one open/unmerged base-main
  exact-head PR authored by `github-actions[bot]`; no workflow approval or
  `action_required` run is needed.
- Cleanup result:after pre-cleanup double read-back, Deploy Key deletes
  ordinary then reserved; both are stably absent and the ordinary PR is
  closed/unmerged. A residual open PR requires independent human close and
  blocks evidence closure.
- Forbidden dispatch in this carrier:apart from its existing Agent branch/PR
  submission transport, any target-canary/ref or extra PR-state write;
  ruleset, branch-protection, repository-setting or credential writes;
  integration/scheduler/review/merge/auto-merge/admin routes; any reuse of r8
  or #421/#435/#454 refs, UUIDs, pins, payloads, windows or runs.
- Evidence separation:r10 readiness merge authorizes the exact plan but is
  not live PASS. Canary evidence and D0 `ready→done` remain two later,
  separately reviewed PRs.

## HLR-002A r8 canary readiness（historical；r9 superseded）

- Audit base:
  `d869f9a36ec95e30bc1fba3c649ed414ca36bf0a`。
- Current topology authority:CHG-2026-033 TASK-RPT-001 #476/#477/#478
  merged evidence；branch-protection projection/full SHA-256 =
  `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a` /
  `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`，
  ruleset projection/full SHA-256 =
  `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163` /
  `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`。
- Exact fresh refs:
  `agent/host-loop/probes/8bd61cc3-d7c7-41ff-bfc8-0c62952afba3` and
  `agent/hlr-002a-control/5a2570ed-5916-4cc8-ac84-4afa294e4b9e`。
- Expected live result:reserved ref has exact-head SDD Guard success and zero
  legacy `agent-pr` run/PR；ordinary ref has exact-head SDD Guard success,
  exactly one successful legacy creator run and exactly one
  `github-actions[bot]` PR. Both refs are deleted after the facts are fixed,
  and the ordinary PR is closed/unmerged.
- Forbidden dispatch:ruleset/branch-protection/repository-setting/credential/
  gateway/authorization/integration/scheduler writes, review, merge,
  auto-merge, old #435/#454 payload/ref/UUID reuse, or any canary before the r8
  readiness carrier is merged.
- Evidence separation:r8 carrier never produced canary dispatch or live PASS.
  Its refs/pins/UUID are permanently superseded by r9; HLR-001A done and a
  new independent HLR-002A readiness are required before any canary.

## Negative and recovery tests

- 短 OID、unknown D grade、multiple `Task:`、空 evidence without reason、硬编码 provider
  attribution、shell command interpolation → envelope validator failure；
- 双 worker/旧 fence/API timeout/lease ref 不存在或被篡改/Issue cursor 不能解析 →
  `reconcile-required`，不创建第二 PR、不开新 task；
- `GITHUB_TOKEN` creator、首个 check 缺失、legacy/new creator 同存、PR lookup 0 或 >1 →
  migration failure/rollback，不用人工编辑 body 掩盖；
- routine Agent PR 仍须人工 approve workflows 才能取得任一治理所需 check、
  create-or-find 遇到 existing PR 后跳过 validation、0/2 PR、wrong
  main/head/author/merged state、PR JSON/number 未 fail closed、validation job
  取得 write permission、新 PAT/App/private key/secret/OIDC/
  `pull_request_target`、bot opened/synchronize approval gate 被重新引入或 human
  edit/reopen 不复验 → `HLR-AUTOCI-001` failure；
- `agent/host-loop/**` 仍触发 legacy creator、普通 `agent/**` 被意外排除、reserved
  head 出现 0/2 PR、head guard 或 pull-request allowed-paths 缺失 → partition/activation
  failure；不以 branch cleanup 或 elapsed time 伪造零 creator；
- r10 readiness merge 未由 exact-head human review/`guard`/`mergedBy`/git
  history 共同确认、fresh ref/evidence branch 预存在、open PR files 查询不完整或
  discovery 后出现 overlap，仍 push canary → failure；零下一步 dispatch；
- canary commit 包含 Actions skip instruction、reserved/ordinary 未使用同一
  protected-main parent/tree、两次 push 之间 main/sensitive blob 漂移、cleanup
  前未重复固定 run/PR facts，或把 head deletion 当作此前零 creator 证明 →
  failure；cleanup 不改变结论；
- TASK-RPT-001 evidence/done merge 缺失，或 ruleset/main protection after/hash/actor
  inventory 漂移，仍进入 HLR-002A readiness/canary → failure；HLR-002A blocked；
  #421 的零 run/PR 不得充作 isolation PASS；
- ordinary ruleset 未同时排除 single/multi-level Agent namespace 与 exact main，
  `~ALL`/creation/update/deletion 被移除，Deploy Key/App/Actions/integration actor 获得
  bypass/main push allowlist，main protection 缺 PR/CODEOWNER/`guard`/admin
  enforcement/force-delete-auto-merge 禁令，或任一 negative write/review/merge/admin
  意外成功 → CHG-2026-033 failure/rollback，HLR lane dispatch = 0；
- #449 gateway、#454 readiness/implementation branch、#435 OID/window/payload/hash/
  UUID 被复用，TASK-HLR-002B 进入 implementation/done，或 Agent runtime 可构造
  ruleset/protection/repository-setting/credential route → overall failure；
- human credential/App private key 出现在 repository、Agent process/environment、
  gateway 或 Agent 可达 storage；raw credential/generic REST/GraphQL/arbitrary
  method/body/ref/review/merge/admin route 可达 → revoke/contain credential、overall
  failure；cleanup 不改变结论；
- canonical suffix task（如 `TASK-HLR-002A`）不能被 title/body 唯一声明、描述性
  branch slug 被升级为 task、错误 alias task 能绕过 allowed-paths、multi-suffix/
  lowercase/adjacent token 被接受 → parser/partition failure；不手工改 body 掩盖；
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
- TASK-HLR-002B tombstone check：status `blocked`，#454 superseded，
  `scripts/host_loop/d2_gateway/**` absent，零 gateway/authorization implementation；
- `agent-pr.yml` branch-filter/automatic-check contract；HLR-001A 对
  `sdd-guard.yml`/`swift-ci.yml` event partition 的 exact reviewed delta；
  HLR-002A fresh readiness 之后的普通 control / reserved canary live evidence
  对该新 baseline byte-for-byte 零额外 workflow diff；
- HLR-001A workflow event/permission/job-dependency fixtures、raw PR JSON
  正反解析、create-or-find 0/1/2 matrix、implementation exact-head push checks、
  post-merge ordinary PR no-approval pilot 与 human edited/reopened revalidation；
- TASK-RPT-001 evidence merge OID、ruleset ID `19595282` 与 main branch protection
  的完整 before/after/rollback JSON/hash、actor inventory、active-rule evaluation，
  以及单层/多层正向 + non-agent/main/agentx/review/merge/admin 负向 transcript；
- r8 exact reserved/ordinary refs、pins 与 UUID 只能作为 zero-dispatch
  superseded history；只有 r10 exact fresh refs 可用于 current canary；
- `check_pr_paths` task-token suffix 正反 fixtures + fresh implementation PR 的真实
  pull-request `guard`/`allowed-paths` terminal success；#412 红灯不得复用；
- `scripts/check-sdd.sh`：0 errors / 0 warnings，acceptance count 以执行时 protected
  main 重新记录，禁止沿用陈旧数字；
- `git diff --check`、allowed/forbidden path audit、no-shell-string static scan；
- live PR body + first `pull_request` run + independent review + merge-OID cross-check；
- `changes/archive/**`、Core specs/contracts/governance canonical files、产品代码与设备
  evidence 的 diff 均为零。

## Result gate

本 change 仅在 HLR-001、HLR-001A、HLR-002A、HLR-002、HLR-003、HLR-004、
HLR-005 均由独立 implementation/evidence 与 done PR 合入，六条 active
acceptance 具备可复查
正反证据，并且 TASK-HLR-002B 仍为 superseded `blocked` tombstone，
D2 identity staging receipt 明示 `workerDisabled=true`、HLR-003 scheduler activation
receipt 绑定 exact source、first-check live proof、independent reviewer proof、
CHG-2026-033 TASK-RPT-001 human-only ref-protection evidence/done merge、
merge-OID recovery proof 全部在案后，才可起草
单独的 `verified` PR。任何 CI green、
Issue cursor、lease、runtime log、AI review 或 batch digest 本身都不构成维护者批准
或自动 merge 授权。

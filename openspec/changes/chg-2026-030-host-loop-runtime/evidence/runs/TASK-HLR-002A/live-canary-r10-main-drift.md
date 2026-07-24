# TASK-HLR-002A Live Canary r10 — main-drift stop

- Date:2026-07-25（Asia/Shanghai）。
- Executor:`agent` for the approved Deploy Key canary and evidence drafting；
  `github-actions[bot]` for push workflows。
- Classification:真实 GitHub repository ref/workflow canary；host-only，零设备、
  ruleset、branch protection、repository setting、credential、review、merge、
  auto-merge 或 PR-state mutation。
- Canonical machine-readable receipt:
  `live-canary-r10-main-drift.json`，SHA-256
  `f649774c02cdd114d50912b1f00fc8bc4efeae3540e9c540d0101b9429448ba0`。
- Task state boundary:本 PR 只追加 r10 failure evidence，不修改 workflow/test/
  proposal/design/tasks/verification，不翻 `TASK-HLR-002A ready→done`。

## Readiness and preflight

- Readiness PR #498 reviewed head
  `c3a35e31b16c17234ba667de56c359eb39af9e0f` 由 `lvye` 于
  `2026-07-24T23:08:15Z` APPROVED，并于 `23:08:21Z` 由 `lvye`
  squash merge 为
  `53b4924227bc3931523357e68ee2cb61b5814646`。
- Merge parent =
  `47cec786315e79e0aad8a3209c6a7c600e6cfc60`，merge/reviewed-head tree
  均为 `19a13d2e01d42aa63825603cdc4f1455037d1a3c`，subject 携
  `(#498)`；`auto_merge=null`。
- Canary 前 current protected main 精确等于 #498 merge；r10 pinned workflow、
  parser、AGENTS/enforcement、HLR-001A/HLR-002A evidence blobs 均匹配。
- all-open #497/#499 的完整 files 已分页审计。#497 只改
  CHG-2026-033 proposal/verification，#499 只改 CHG-2026-026 evidence，
  均不触碰本 task、workflow/parser、pinned topology evidence 或 target refs。
- Exact reserved/ordinary/evidence refs 均 absent。Agent 使用
  `github-arkdeck-agent` Deploy Key remote；`gh auth status` 保持 zero
  logged-in hosts。

## Reserved result

Exact reserved ref:
`agent/host-loop/probes/7e9bc001-c515-4aef-b3dc-c71d7f0124ee`。

唯一 pushed commit:

- OID:`dbccd1f2da9c5831b4d2345339c354e468598027`；
- parent:`53b4924227bc3931523357e68ee2cb61b5814646`；
- tree:`19a13d2e01d42aa63825603cdc4f1455037d1a3c`，与 parent 相同；
- author/committer:`ArkDeck Agent
  <arkdeck-agent@users.noreply.github.com>`；
- subject:`test(TASK-HLR-002A): reserved creator canary r10`，无 Actions
  skip instruction；
- Deploy Key create push attempts = 1，exit code = 0。

Exact workflow facts:

- SDD Guard push run `30133093487` = success；
  `guard` job `89611466997` = success，
  `allowed-paths` job `89611467546` = skipped（push event expected）。
- Swift CI push run `30133093488` = success；
  `swift` job `89611467217` = success，
  completed at `2026-07-24T23:12:44Z`。
- Agent PR workflow query used exact workflow path + `event=push` + full
  branch + full head SHA + `per_page=100&page=1`；two read-backs both returned
  `total_count=0` with no pagination link。
- All-state PR query used exact same-repository head + `base=main` +
  `per_page=100&page=1`；two pre-cleanup read-backs and one post-cleanup
  read-back all returned count = 0 with no pagination link。

Therefore the reserved half independently proves the current legacy creator
does not run for this exact `agent/host-loop/**` head while normal push
delivery remains live. It does not prove ordinary creator liveness or the
combined canary.

## Exact-main drift and fail-closed stop

While reserved Swift was running, #497 advanced protected main:

- reviewed head:
  `076e3bf516c96ccd81e93da4c7a3f4366333ea2a`；
- `lvye` approval:`2026-07-24T23:08:52Z`；
- merge:
  `ce4a11c3d7cb59686024be9cbd51939c084041d1` at
  `2026-07-24T23:12:30Z` by `lvye`；
- parent:
  `53b4924227bc3931523357e68ee2cb61b5814646`；
- subject:
  `governance(CHG-2026-033): verify ref protection topology (#497)`；
- changed paths:only CHG-2026-033 `proposal.md` and `verification.md`。

The change was already classified as non-overlap, but r10 explicitly required
the readiness merge to remain current main between reserved completion and
ordinary dispatch. The post-reserved read-back observed
`ce4a11c3d7cb59686024be9cbd51939c084041d1` instead of
`53b4924227bc3931523357e68ee2cb61b5814646`。That exact stop condition takes
precedence over the non-overlap classification:

- ordinary commit created = false；
- ordinary push/ref/run/PR count = 0；
- no alternate parent, UUID or branch was substituted；
- no setting, credential or PR state was changed。

## Cleanup

- Reserved ref delete attempts = 1，Deploy Key push exit code = 0。
- Two later `git ls-remote --heads` read-backs returned both reserved and
  ordinary exact refs absent。
- Post-cleanup reserved all-state PR count = 0。
- Ordinary delete attempts = 0 because it was never created。

Cleanup only restored the target namespace; it does not turn the incomplete
matrix into PASS.

## Conclusion and remediation boundary

TASK-HLR-002A r10 creator canary = **INCOMPLETE / FAIL CLOSED**：

- reserved exclusion + push liveness:PASS；
- ordinary legacy creator liveness:not run；
- combined creator partition:not established；
- cleanup:complete；
- `ready→done`:not authorized；
- TASK-HLR-002 D2 readiness:not authorized。

The immediate cause is a governance timing race:an already-audited,
non-overlapping PR merged during the required reserved Swift wait, while r10
still treated every main advancement as fatal. A later, separately reviewed
D1 readiness must use fresh refs/UUIDs and explicitly choose a safe drift
policy. It may retain exact-main serialization, or replace it with a
sensitive-input/overlap rule that also specifies how reserved and ordinary
commit parents/trees remain comparable. This evidence PR makes neither
choice and authorizes no retry.

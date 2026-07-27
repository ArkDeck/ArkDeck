# TASK-HLR-002A Live Canary r11 — success

- Date:2026-07-25（Asia/Shanghai）。
- Executor:`agent` for the approved Deploy Key canary and evidence drafting；
  `github-actions[bot]` for push workflows and ordinary PR creation。
- Classification:真实 GitHub repository ref/workflow canary；host-only，零设备、
  ruleset、branch protection、repository setting、credential、review、merge、
  auto-merge 或 Agent direct PR-state mutation。
- Canonical machine-readable receipt:
  `live-canary-r11-success.json`，SHA-256
  `8965c39a06a8d68c33dea30215f82299e9e67c4b542f1a2e12bddd61529b1bb3`。
- Task state boundary:本 PR 只追加 r11 success evidence，不修改 workflow/test/
  proposal/design/tasks/verification，不翻 `TASK-HLR-002A ready→done`。

## Readiness and common source

- Readiness PR #504 reviewed head
  `e304f1f2e70a78652accdceea502eda92e2b8519` 由 `lvye` 于
  `2026-07-24T23:58:43Z` APPROVED，并于 `23:59:20Z` 由 `lvye`
  squash merge 为
  `f1ebdf0b67014cbb921db4ae55f2400448f620ce`。
- Merge parent =
  `1c1ae70a869d03e50a3a012e53d2a1b47a9f311d`，merge/reviewed-head tree
  均为 `9385dde9ce6efb9bad3d960f2e38d894daa009d7`，subject 携
  `(#504)`；`auto_merge=null`。
- Reserved 与 ordinary commit 均以该 merge 为 parent、以该 tree 为 tree，
  author/committer 均为
  `ArkDeck Agent <arkdeck-agent@users.noreply.github.com>`。两者都是 empty
  canary commit，不含 Actions skip instruction。
- Canary 全程未使用 r11 已批准的 scoped post-dispatch drift 规则：
  pre-cleanup 与 post-cleanup protected main 均仍为上述 #504 merge。

## Reserved partition

Exact reserved ref:
`agent/host-loop/probes/0f803ee1-332e-4bf3-a58c-32af75ce8579`。

唯一 pushed commit:

- OID:`31e490996d0acf095e59b2d5100354da5019087c`；
- subject:`test(TASK-HLR-002A): reserved creator canary r11`；
- Deploy Key create push attempts = 1，exit code = 0。

Exact workflow and PR facts:

- SDD Guard push run `30135271767` = success；
  `guard` job `89617752951` = success，
  `allowed-paths` push job `89617753419` = skipped（push event expected）。
- Swift CI push run `30135271761` = success；
  `swift` job `89617753013` = success，
  completed at `2026-07-25T00:03:39Z`。
- Agent PR workflow query used exact workflow path + `event=push` + full
  branch + full head SHA + `per_page=100&page=1`；dispatch-barrier and
  pre-cleanup read-backs both returned run count = 0。
- All-state PR query used exact same-repository head + `base=main` +
  `per_page=100&page=1`；the same two read-backs both returned PR count = 0。
- All exact workflow/PR queries had no pagination link。

The r11 shortened dispatch barrier closed only after reserved `guard`
succeeded, the unique reserved Swift run had been delivered and was running,
and both legacy creator surfaces had returned zero. Swift later completed
successfully. This proves the reserved partition suppresses legacy PR
creation without suppressing normal push workflow delivery。

## Ordinary creator control

Exact ordinary ref:
`agent/hlr-002a-control/5dab2542-ec7b-4561-b3d0-ad41046affb6`。

唯一 pushed commit:

- OID:`d1da93ebadbaa3b591dbec4776bcda12e3cd16e3`；
- subject:`test(TASK-HLR-002A): ordinary creator control r11`；
- Deploy Key create push attempts = 1，exit code = 0；
- ordinary dispatch barrier closed before `2026-07-25T00:02:19Z`。

Exact workflow facts:

- SDD Guard push run `30135308323` = success；
  `guard` job `89617862390` = success，
  `allowed-paths` push job `89617862748` = skipped（push event expected）。
- Swift CI push run `30135308065` = success；
  `swift` job `89617861786` = success，
  completed at `2026-07-25T00:04:00Z`。
- Agent PR push run `30135308064` = success；
  `open-pr` job `89617862335` = success，
  `allowed-paths` job `89617903654` = success。
- Two exact Agent PR run read-backs returned exactly one run；two exact
  all-state PR read-backs returned exactly one PR；both query surfaces had no
  pagination link。
- No reserved or ordinary workflow run concluded `action_required`。

The unique ordinary PR was #505:

- title:`test(TASK-HLR-002A): ordinary creator control r11`；
- author:`github-actions[bot]`；
- head OID:`d1da93ebadbaa3b591dbec4776bcda12e3cd16e3`；
- base OID:`f1ebdf0b67014cbb921db4ae55f2400448f620ce`；
- created at `2026-07-25T00:02:14Z`；
- before cleanup:open，`merged_at=null`，`auto_merge=null`。

This establishes ordinary legacy creator liveness on the same parent/tree
source used by the reserved half。

## Cleanup and observation boundary

- Ordinary ref delete attempts = 1，Deploy Key push exit code = 0。
- Reserved ref delete attempts = 1，Deploy Key push exit code = 0。
- Two stable `git ls-remote` read-backs returned both exact refs absent。
- GitHub closed #505 after its head deletion at
  `2026-07-25T00:05:36Z`；final state = closed，merged = false，
  `merged_at=null`，`auto_merge=null`。
- Post-cleanup exact all-state queries returned reserved PR count = 0 and
  ordinary PR count = 1（the closed #505）。
- Agent directly changed no PR state；the only PR creation came from the
  expected Actions workflow and the only closure came from head deletion。

All required workflow/job/PR queries and cleanup read-backs had completed
before an optional Issue-events query and a redundant REST main query reached
the anonymous API rate limit (`HTTP 403`)。No result is inferred from those
optional calls：exact post-cleanup main and ref absence were independently
confirmed through Git。

## Conclusion

TASK-HLR-002A r11 creator canary = **PASS**：

- reserved creator exclusion:PASS；
- reserved normal workflow delivery:PASS；
- ordinary legacy creator liveness:PASS；
- same-source comparison:PASS；
- protected-main stability:PASS，scoped drift exception unused；
- ref/PR cleanup:PASS；
- GitHub settings and credentials mutation count:0。

This receipt supports a later, separate D0 `TASK-HLR-002A ready→done` PR。
It does not itself change task state, approve TASK-HLR-002 D2 readiness, or
authorize any additional GitHub control-plane mutation。

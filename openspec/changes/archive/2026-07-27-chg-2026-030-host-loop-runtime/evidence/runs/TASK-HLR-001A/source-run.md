# TASK-HLR-001A Source Run — automatic Agent PR checks

- Date:2026-07-24（Asia/Shanghai）；live read-back captured at
  `2026-07-24T14:12:48Z`。
- Executor:`agent` for source/local verification and Deploy Key branch push；
  `github-actions[bot]` for PR creation and workflow execution。
- Approved readiness:#483 exact reviewed head
  `83f508aa6d64ba26789edd6e82ce0c2f8dff5fb3`，由 `lvye` APPROVED，
  merge/main `c2fd6d1dff71717f8a8dd3137c68b4a06cf569cf`。
- Implementation base:protected `main`
  `048ce16b017db701f88a1eee1349de2b46595db7`；#482 只修改
  CHG-2026-026/rockchip-loader-transition paths，与本 task 零 overlap。
- Classification:`contract + live GitHub repository workflow`，host-only；
  零真实设备/HDC、零 GitHub setting/branch-protection/ruleset/credential
  mutation、零 review/merge/auto-merge。
- Task state boundary:本 source/evidence PR 不翻 `ready→done`；post-merge
  ordinary-PR evidence 与 done 使用后续独立 PR。

## Deliverables

- `agent-pr.yml`：workflow-scope deny-all；`open-pr` 仅有
  `contents:read`/`pull-requests:write`，分页 create-or-find 后 fixed-endpoint
  read-back，验证 number/repository/base/exact head/author/open/unmerged。
- 同一 push run 的 dependent `allowed-paths` job 仅有
  `contents:read`/`pull-requests:read`；再次验证唯一 PR 与 fixed PR JSON，
  运行 MECH-004 exact base/head diff。
- `sdd-guard.yml`：push `guard` 保持；routine bot `opened/synchronize`
  不再订阅，human `reopened/edited` 保留 base-defined revalidation。
- `swift-ci.yml`：`main`/`agent/**` push-only；新分支无可靠 `before`
  时仍 fail closed 跑全量。
- `check_pr_paths.py` 与两份 tests：raw API PR parser、0/1/2 paginated
  selection、identity/event/permission/dependency negative matrix。

## Offline commands and results

| Command | Result |
| --- | --- |
| `python3 scripts/test_agent_pr_workflow.py` | PASS，8 tests |
| `python3 scripts/test_check_pr_paths.py` | PASS，24 tests |
| `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'` | PASS，17 tests |
| `python3 scripts/test_check_sdd.py`（approved SDD interpreter） | PASS，19 tests |
| `ARKDECK_PYTHON=<approved-sdd-python> ./scripts/check-sdd.sh` | PASS，0 errors / 0 warnings / 111 acceptance IDs |
| Ruby standard-library YAML parse（3 workflows） | PASS |
| `python3 -m py_compile`（3 modified Python files） | PASS |
| `git diff --check` | PASS |
| public open PR #484 API shape → new `--identity-only` CLI | PASS，stdout exact `484` |

Negative fixtures cover zero/two PRs, malformed pagination/number, wrong
repository/base/head/ref/author/state/merged flag, missing job dependency,
write permission on validation, secret/PAT-like input, bot
`opened/synchronize` reintroduction, Swift pull-request subscription and
`.gitignore` scope expansion。

## First-source-head live result

- Source head:
  `e4e94afe52e059c4bfba56ed8897bb5db0006a76`。
- PR:#485，`author=github-actions[bot]`，`state=open`，`merged=false`，
  base `048ce16b017db701f88a1eee1349de2b46595db7`，head/ref exact
  `e4e94afe52e059c4bfba56ed8897bb5db0006a76` /
  `agent/task-hlr-001a-auto-ci`。
- SDD Guard push run `30099824259` = `success`。
- Swift CI push run `30099824254` = `success`；new-branch zero-before
  fail-closed path ran the full ArkDeckKit suite。
- Agent PR push run `30099824234` = `success`：
  - `open-pr` job `89502780709` = `success`；
  - `allowed-paths` job `89502823482` = `success`，包括 contract tests 与
    exact PR/task-path validation。
- Exact-head Actions read-back returned `total_count=3`，all three events were
  `push` and successful；`pull_request`/`action_required` run count = 0。
  No maintainer workflow approval was requested or used。

## Scope and residual gate

- Diff is limited to the three workflows, three parser/test files, this run
  record and the TASK-HLR-001A evidence pointer；`.gitignore`、AGENTS.md、
  enforcement、Core/spec/contracts、product/device code = 0 diff。
- This run establishes the source contract and first bot-PR create-path live
  candidate for `HLR-AUTOCI-001`。The evidence-only follow-up commit on the
  same PR must independently pass the existing-PR path and all exact-head push
  checks。After implementation merge, a separate ordinary Agent evidence PR
  must prove the new protected-main base has no routine approval gate；only
  then may a separate D0 PR propose `ready→done`。

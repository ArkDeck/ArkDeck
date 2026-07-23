# TASK-HLR-002A contract run — legacy bootstrap namespace partition

- Date:2026-07-23;executor:agent。
- Classification:host-only offline workflow/branch grammar contract；无设备、HDC、
  credential/secret/scheduler/ruleset 变更，无 probe/ref 写入。
- Implementation base:`31865366f7bdb8e5ca33f0c8d41c15f6daba7933`。
- Readiness merge:`6b40866e18fe33edc5973de5158f494adfdd48d2`（#411）。

## 实现

- `.github/workflows/agent-pr.yml` 的 `on.push.branches` 从单一
  `agent/**` 改为 ordered include/exclude：

  ```yaml
  branches:
    - "agent/**"
    - "!agent/host-loop/**"
  ```

- 新增纯 Python standard-library contract
  `scripts/test_agent_pr_workflow.py`。它以 fail-closed、indentation-aware extractor
  解析上述 event filter，验证 pattern 顺序与 re-include 语义，并固定
  task/lease/probe reserved grammar 的正反矩阵。
- `.github/workflows/sdd-guard.yml` 未修改；本 run 实测 Git blob 仍为
  `809147e462512d970813d1992a3fcdf41f8b4b10`，与 readiness pin 相同。

## 验证结果

使用 `/private/tmp` 隔离 Python 环境执行仓库锁定的 PyYAML 依赖；虚拟环境路径和
依赖缓存不入仓，也不构成产品或 host activation evidence。

```text
python3 scripts/test_agent_pr_workflow.py
PASS — 6/6 tests

python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'
PASS — 17/17 tests

python3 scripts/test_check_pr_paths.py
PASS — 20/20 tests

ARKDECK_PYTHON=<isolated-python> ./scripts/check-sdd.sh
PASS — 0 errors / 0 warnings / 111 acceptance IDs

PyYAML BaseLoader parse of on.push.branches
PASS — ["agent/**", "!agent/host-loop/**"]

git diff --check
PASS

git diff --exit-code <implementation-base> -- .github/workflows/sdd-guard.yml
PASS — zero diff
```

Contract fixtures 包含：

- ordinary `agent/task-*`、control branch、namespace root 与相似
  `agent/host-loopx/**`/`agent/host-loops/**` 保持 legacy dispatch；
- 全部 `agent/host-loop/**`（含 malformed reserved-like branch）不 dispatch；
- canonical uppercase `TASK-*` task/lease branch 与 lowercase UUIDv4 probe branch
  命中 reserved family；
- 空/额外 segment、`.`/`..`、backslash、percent encoding、case drift、
  uppercase/non-v4 UUID、相似 prefix/family 与 `refs/heads/` 输入均不命中；
- missing/duplicate/unknown event/filter、flow list、alias、unquoted scalar、
  reversed/missing pattern、额外 re-include、`branches-ignore` 与 job-level
  substitute 均具名失败。

## Repository gate read-back

首次 implementation source push 的 full head 为
`c330c0ef3245f0b7ea9cc2f63bd960899c9f80cd`（commit time
`2026-07-23T08:36:41Z`）。GitHub 的首次 read-back 在
`2026-07-23T08:39Z`—`08:41Z` 暂时返回 workflow run/check suite/PR 均为 0；
该事件闭合前未重推、未追加 commit、未手工创建 PR。相同 head 后续异步闭合为：

- SDD Guard push run `29992345788`（run `#1314`），terminal success；
- Agent PR push run `29992345574`（run `#387`），terminal success；
- Swift CI push run `29992345865`（run `#268`），terminal success；
- exact-head PR `#412` 于 `2026-07-23T08:47:20Z` 由
  `github-actions[bot]` 唯一创建，base 为 `main`
  `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`，head 与上述 full OID 相同，
  changed files 恰为本任务三个 allowed paths。

只读查询使用 exact `head_sha` workflow-runs/check-suites 与
`state=all&head=ArkDeck:agent/task-hlr-002a-bootstrap-partition` PR filter。
这证明首个 branch guard 与 legacy creator 均来自首次 push；短时零结果仅记录为
GitHub event delivery delay，不以 elapsed time 自行判定 PASS。本节由后续
evidence-only commit 追加，不改变上述 first-source-head 事实。

## Scope 与 AC 结论

- Allowed implementation paths：`agent-pr.yml`、新 contract test 与本 run record；
  `sdd-guard.yml`、runtime、Core/spec/contracts/governance、产品 source/tests 均零 diff。
- `HLR-LEASE-001` / `HLR-WORKER-001` 的 HLR-002A **offline contract slice**：
  PASS；首次 source push 的 branch guard 与唯一 legacy creator gate 同时满足。
- 后续 evidence-only head
  `4d0d5e1a0830158340e98190c856f89862980841` 触发 PR `synchronize` 后，
  SDD Guard pull-request run `29992997396` 的 `allowed-paths` job
  `89159873429` terminal failure。具名错误为：
  `branch task declaration 'agent/task-hlr-002a-bootstrap-partition' normalizes to
  invalid 'TASK-HLR-002A-BOOTSTRAP-PARTITION'`。
- 根因是 pinned `scripts/check_pr_paths.py` 的 `TASK_TOKEN_TEXT`/`TASK_LINE_RE`
  只接受末段三位数字，而 canonical active task 为 `TASK-HLR-002A`。标题/body
  均无法诚实声明该 task；伪填 `TASK-HLR-002` 会绑定错误任务，修改 parser 又超出
  本 readiness allowed paths。故 PR integration gate = **FAIL**，不形成 bootstrap
  PASS，#412 不得合入；须经独立 scope revision/readiness 后重新实现。
- 本 run 不声明 post-merge live control/canary PASS，不创建 integration identity，
  不授权 HLR-002 D2，不翻 TASK-HLR-002A 状态，也不构成 change verification。
  implementation 合入后仍须按 readiness 执行独立 live evidence PR；事实不全即
  fail closed。

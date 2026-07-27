# TASK-HLR-002A Live Canary r1 — reserved ref creation failure

- Date:2026-07-23（Asia/Shanghai）。
- Executor:`agent`。
- Classification:真实 GitHub control-plane/ref write；host-only，零设备、HDC、
  identity/secret/scheduler、Issue、review、merge、ruleset/admin write。
- Task state boundary:本 PR 只追加 live failure evidence，不改 workflow/test/status；
  TASK-HLR-002A 保持 `ready`，且本失败闭合前不得进入 TASK-HLR-002 D2 readiness。

## Implementation merge gate

- Implementation PR:#419。
- Reviewed head:
  `39965af82bcb9a03f07e9501c844e86691b91d88`。
- Maintainer review:`lvye`，`APPROVED`，
  `2026-07-23T10:45:07Z`。
- Squash merge:
  `99ba8aa4b04018918daad2fc8830009c1030f6da`，
  `2026-07-23T10:45:14Z`；parent =
  `e69a0c23b327571327bfce4a87d5e50f406db256`，subject 携 `(#419)`。
- Reviewed head 与 merge 对 #419 五个 changed paths 的 tree 内容完全相同；
  merge 已是当前 protected `main` 的 ancestor。
- Canary 开始时 protected `main` =
  `ac0cfaa2091a4ac2b14bcb0308f8c98388a98d77`；其相对 #419 merge 仅含独立
  CHG-2026-029 archive #418，零本任务/workflow overlap。按 approved plan，两个
  canary 仍以 #419 merge 为共同 parent。

## Preflight

- `2026-07-23T10:48Z` open PR count = 0。
- remote `refs/heads/agent/host-loop/*` 与
  `refs/heads/agent/hlr-002a-control/*` lookup = 0。
- Reserved run id:
  `ba0df001-6e7c-44de-939f-a355bda0a287`。
- Ordinary run id（仅预留，未创建/未推送）:
  `f9b8ca5a-c7e2-481e-8be8-a3918034403b`。

## Reserved probe execution

完整 branch:
`agent/host-loop/probes/ba0df001-6e7c-44de-939f-a355bda0a287`。

本地 empty commit:

- OID:`93ede0415f14cd28bc69c0e593151a06a247afda`；
- parent:`99ba8aa4b04018918daad2fc8830009c1030f6da`；
- tree:`a9b580bf8b9af406f2a11aad24d6f29117a7fd2f`，与 parent tree 相同；
- `git diff <parent> <head>` = empty。

首次且唯一 push：

```text
command: git push origin agent/host-loop/probes/ba0df001-6e7c-44de-939f-a355bda0a287
exit_code: 1
remote: error: GH013: Repository rule violations found for refs/heads/agent/host-loop/probes/ba0df001-6e7c-44de-939f-a355bda0a287.
remote:
remote: - Cannot create ref due to creations being restricted.
remote rejected: push declined due to repository rule violations
```

按 `reserved → ordinary` 固定顺序和 fail-closed 规则，reserved ref 未创建后立即
停止；ordinary commit/ref/push、control PR 与任何 cleanup write 均未执行。

## Failure read-back

`2026-07-23T10:50:58Z` 前完成以下只读回查：

- `git ls-remote --heads` 对 exact reserved ref = 0；
- 同一查询对预留 ordinary ref = 0；
- Actions workflow-runs API filter
  `head_sha=93ede0415f14cd28bc69c0e593151a06a247afda&per_page=100`
  返回 `total_count=0`；
- all-state pulls API filter
  `state=all&head=ArkDeck:agent/host-loop/probes/ba0df001-6e7c-44de-939f-a355bda0a287&per_page=100`
  返回 count = 0。

这些零结果只证明 push 未产生远端对象；由于缺少 reserved exact-head 的
SDD Guard delivery/`guard` success，不得把 Agent PR count = 0 解释为 namespace
partition PASS。

## Root cause and disposition

- TASK-BAP-003 在案 ruleset `agent-ref-boundary`（ID `19595282`）使用 exclude
  `refs/heads/agent/**`，其真实正向 probe 仅覆盖单层
  `agent/cred-probe`。
- GitHub
  [ruleset fnmatch 文档](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository#using-fnmatch-syntax)
  明示使用 `File::FNM_PATHNAME`、`*` 不匹配 `/`，多层示例使用 `qa/**/*`。
  因此既有 exclude 没有覆盖三层 reserved branch，restrict-creations rule 正确地
  返回 GH013。
- 候选修复方向是由维护者经独立 D1/D2 方案审查，把 ref boundary 扩展到经验证的
  多层 `agent` namespace（例如评估 `refs/heads/agent/**/*`），并同时重跑单层/
  多层正向及 ordinary/main 负向 probes。Agent 本 run 未读取或修改 ruleset，
  也未取得 admin/bypass 权限。

## Conclusion

TASK-HLR-002A post-merge live canary r1 = **FAIL**：

- reserved ref creation:FAIL（GH013）；
- reserved head guard:missing；
- ordinary legacy liveness:not run（依序停链）；
- creator-isolation conclusion:not established；
- remote cleanup:not required（目标 refs 从未创建，read-back 均 absent）。

失败不被 cleanup、零 run/PR 或 offline contract test 覆盖。TASK-HLR-002A 不得
`ready→done`，TASK-HLR-002 不得进入 D2 readiness；下一步必须先由独立治理
revision/readiness 修复并实测多层 ref boundary。

# TASK-RWL-001 — run r1（2026-08-19，生产 daemon + 真实存量）

> 血统收养与清扫面在**本机真实 daemon 存量**上的验收记录（Hardware: no，
> 全程宿主侧）。daemon 为携本任务实现的构建（17:51 部署，codesign timestamp
> 为证）；catalog digest 前进为 `2f9d397dcb6a…`（恰增一个 operation）。

## RWL-AC-1 — 血统收养正例（生产实证）

对象 = AND-002 r2 遗留的 `evo-360b54f898e2575df90fcd90`
（manifest base `701c5bd95612…`，allowedPaths 四 glob；durable attempt
`patch-7e08b69f…`：before `701c5bd95612…` → after `aed6966b7d36…`，未 revert）。

- 部署前两次 daemon 启动（16:08/16:13，旧代码）各留一行
  `runtime workspace not adopted for evo-360b54f8…:revision`——全日志恰 2 次；
  **17:51 新 daemon 的启动块零出现**（该行全日志计数不再增长）。
- 进程内探针（对同一生产存量、同一 `waterflow-openharmony@1` profile）：
  `lineageDerivedRevision(base, records) == 测得 revision == aed6966b7d36…`，
  `adoptRuntimeWorkspaces() == []`。
- 树在补丁时刻（06:44Z）后 scope 内零 mtime 变化——链之外无漂移。

## RWL-AC-2 — 篡改仍拒 / 推导矩阵

合约测试：`testAdoptionAcceptsALineageDerivedRevisionAndStillRefusesTampering`
（血统外直接改文件 → `<id>:revision` 具名拒绝、零注册）与
`testLineageDerivationFoldsAppliedAndRevertedAttemptsAndRefusesBrokenChains`
（applied 前进 / reverted 折叠 / 断链、分叉、缺测值 → nil）。

## RWL-AC-3 — 证词不可供给

- 输入 schema 闭合为 {retainLatestCount, minimumQuiescentSeconds, dryRun}；
  含 `testimony` 字段的提交在 admission 具名拒绝
  （`testSweepDestroysOnlyLedgerQuiescentTreesAndItsAuditSurvives` 末段）。
- 证词由 dispatcher 于执行时从两个 runtime 自有事实源合成：manager 库存
  （与收养同一 vouching）× engine durable 台账端口
  （`WorkspaceReferenceLedgerReading`，终态判定复用仓库 activeJobs 过滤）。
  实施勘误：proposal 原文的「物化时冻结」改为「执行时合成」——所有权边界
  （workspace 清单归组合层、job 台账归 engine，二者只在 dispatcher 会合）
  使然，且对竞态方向严格更安全；勘误随本 PR 记入 design.md。

## RWL-AC-4 — 活跃与不可担保者保全（生产 + 合约双证）

- 生产：54 棵 harness 时代遗留树（含两棵 r1 失败制备的空 taskRoot）在
  dry 与 wet 中一律 `unknownTaskRetained`，树字节零变化——移除的任务平面
  留下的东西，谁也不能替它作证，就谁也不能动它。
- 合约：submitted-未-run 的 build job 即活引用，其树 `activeRetained`。

## RWL-AC-5 — dry/wet 一致性（生产实证）

| | dry（job-cf061582…） | wet（job-dcdf0631…） |
| --- | --- | --- |
| findings 总数 | 55 | 55 |
| `evo-360b54f8…` | `wouldDestroy`（reclaimable 18,035,584B，6 个引用 job 全终态，最新终态 06:45:37Z） | `destroyed`（reclaimed 18,035,584B） |
| 其余 54 | `unknownTaskRetained` | `unknownTaskRetained`（逐树一致） |

## RWL-AC-6 — 审计幸存（生产实证）

wet 后 `evo-360b54f8…/` 恰余 `workspace.json`、`attempts/`、`teardown.json`；
`workspace/` 树不存在。两份 findings（`ART-32ac94dd…` dry、`ART-06d55c16…`
wet）经 `arkdeck artifact export` 取回，宿主绝对路径出现次数 **0**
（机械 grep）；`findingsSha256` 由 verify 与 stdout 逐字节钉合。

## RWL-AC-7 — catalog 收敛与门

generator `--write` 后 digest 恰进一个 operation（生产 doctor 读到
`2f9d397dcb6a…`）；generator 自测 OK；check-sdd 0/0；目标合约套件全绿
（Evolution/RuntimeOwnedWorkspace/HostOnlyAdmission/RuntimeArtifact/
WorkspaceProvider 族）；生产链 `job.submit → admission → dispatcher →
manager → findings artifact` 由上表两个真实 job 直接实证。

## 附注

- 请求走 v2 schema（`schemaVersion: "2.0.0"`）+ 既有 `job submit
  --request-file`；未新增 CLI 子命令。
- 部署顺带复核：ArkForge lane 四键经新 CLI 的保全逻辑存续
  （`arkforge lane: composed`），`ARKDECK_HARNESS_*` 保持零。

# TASK-DHA-001 — DHA-HW-001 attempt#2 D2 window plan

> **Decision grade:D2（设备窗口）**
>
> 本文件由 Agent 起草，不自行产生批准语义。只有承载本文件、task
> `ready` 草案与 exact inputs 的 PR 经维护者对 exact head review/merge 后，
> attempt#2 窗口才打开；合入前设备 runtime dispatch 必须为 0。
>
> **Post-run consumption（2026-07-29）**:窗口已由唯一一次
> `arkdeck agent run` 消耗，job
> `job-3db66f2d-f0c0-47c1-8d8a-91d82dd7975d`；剩余 run budget = 0。
> runtime succeeded，但 formal evidence blocker 见
> `window-attempt-2.md`。本窗口不得再次使用。

## 前序事实

- attempt#1 blocked evidence 已由 PR #791 合入 main
  `d037768f5e92850861219cd64edf53bfbb4b56ae`；
- attempt#1 在 job 创建与 operation step dispatch 前因缺失 Catalog 必填
  `durationSeconds` 被拒；没有 diagnostics artifact；
- 已发布 Catalog/implementation/contract tests 不变，本 D2 载体不修改
  `Catalog/**`、`Packages/**`、Core spec、AC 或 Safety policy。

## 草案确定性校验

- inputs JSON 可解析，closed keys 恰为 `durationSeconds`，文件 SHA-256
  `277918e3016edb145aaee46cb33ee1f0d4a31a70a9a2d160e5d5128ed61585ba`；
- `swift test --package-path Packages/ArkDeckKit --filter
  DiagnosticsAndHAPContractTests`：14 tests / 0 failures；其中无 trace
  请求保持 E0、无需 capability，以及有 trace 时升 E1 且缺 capability
  零 dispatch 的配对测试均通过；
- `scripts/check-sdd.sh`：0 error / 0 warning / 111 acceptance IDs。

这些检查只证明窗口计划与已发布 contract 一致，不构成 D2 批准，也不构成
真实硬件 evidence。

## 窗口边界（merge 后生效）

| 项 | Pin |
| --- | --- |
| Acceptance | `DHA-HW-001` only |
| Executor | Device Runtime Agent |
| Operation | `capture.diagnostics@1` |
| Effect / authority | E0 `readOnly` / `default-read-only-policy` |
| Target | DAYU200(RK3568),USB,adopt 后 target `TGT-958780b2ffb7`;binding 必须 confirmed |
| HDC | `Ver: 3.2.0f`;SHA-256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` |
| Runtime source | 合入本 D2 window PR 后的 exact main merge OID |
| Inputs | `dha-hw-001-attempt-2-inputs.json`;SHA-256 `277918e3016edb145aaee46cb33ee1f0d4a31a70a9a2d160e5d5128ed61585ba` |
| State dir | `/private/tmp/adw4`,mode `0700`;UDS 路径保持在平台上限内 |
| Attempt budget | 最多一次 `arkdeck agent run`;失败后零自动重试 |
| Validity | merge 后立即生效，至 `2026-07-30T12:00:00Z`；超时即关闭 |
| Human action | 只允许结构化 `trustDevice` / `selectTarget` / `physicalReconnect` |
| Explicitly forbidden | `traceCategories`、capability、remote-file trace/cleanup、E1/E2、人工 host CLI |

checked-in inputs 的 exact JSON：

```json
{
  "durationSeconds": 5
}
```

`traceCategories` 缺失是本窗口保持 E0 的必要条件；不得把“补齐
durationSeconds”扩大为新增 trace、远端临时文件或 cleanup。

## Agent 执行顺序

1. read-back 本 D2 PR 为 `MERGED`，记录完整 merge OID；
2. fetch 后 checkout 本 D2 PR 的 exact merge OID，确认 HEAD 与该 OID
   完全相等且工作树无漂移；不得悄悄使用更晚 main；
3. 重建 `arkdeck` 与 `arkdeck-agentd` 并记录 SHA-256；
4. 复核 HDC version/hash、inputs SHA-256、inputs closed keys 与有效期；
5. 启动短路径私有 state dir 的 daemon，经 typed `doctor` 确认 provider、
   bootstrap、target store 与 catalog digest；
6. Device Runtime Agent 执行一次 `device-window-plan.md` §2 的 exact
   `agent run`；若出现 structured humanAction，维护者只做对应物理协助；
7. 成功后经 `job status` 与 `artifact.list/inspect/read` 核对 receipt、
   timeline、artifact metadata 和 capture summary；raw artifact 留在 daemon
   私有目录；
8. daemon 干净停止，脱敏记录 evidence。任一步失败立即停，记
   blocked-attempt，不重试、不改输入、不用 fixture 顶替。

## Pass / fail

PASS 必须同时满足：

- receipt 为 `executor=agent`、authority 为 default read-only、终态
  succeeded，且 humanAction 仅来自允许集合；
- operation timeline 有完整 intent/dispatch/verify/finalize，零
  deviceMutation；
- `hilog.txt`、`artifact-index.json`、`capture-summary.json` 可经
  `artifact.*` 查询；UI dump 如实记录实际状态；
- 未请求 trace 时 `trace.htrace` 在 summary 中如实为 missing；
- connect key/完整序列号与 raw HiLog/UI dump 均不入 Git。

任一条件不满足即 `DHA-HW-001` 仍为 BLOCKED / NOT PASS。

## 合并语义

维护者 merge 本 D2 PR 仅表示批准上述**一次、限时、E0**窗口，不批准
`DHA-HW-002`、任何 E1 capability 或新的 operation/Catalog/safety
变化。Agent 不得把本窗口 merge 解释为 change verified 或 release
support 声明。

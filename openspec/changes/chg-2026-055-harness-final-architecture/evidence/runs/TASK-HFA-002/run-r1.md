# TASK-HFA-002 run r1 — 防陈旧闸:一个真实的竞态,不是理论问题

- Date:2026-07-31
- Executor:agent(维护者指示开工)
- Source baseline:`main@de027169`(PR #892 已由维护者合入,任务已在 base 树)
- Hardware:none(本任务 host-only;真机复验属 TASK-HFA-005)

## 1. 根因:guard 缺失时,操作员的决定会被无声地跳过

`HarnessTaskCoordinator` 是 actor,但**规划会挂起它**——`decisionGateway.propose()`
是一次网络往返。挂起期间 `pause` / `resume` / `cancel` 可以合法地进入同一个 actor 并改变
任务状态。而 `dispatch` 用的是**规划前**读到的 snapshot。

改动前,这个窗口里唯一的拦截是 `store.commit(expectedVersion:)` 的乐观锁,而它跑在
`putIntent` 与 `jobPort.submit` **之后**:副作用已经发生,失败的只是记账。

### 变异对照(实测,不是推理)

把新加的 freshness 检查改成 `if false, let staleness = ...`(其余不动)后重跑
`testAHumanResolutionDuringPlanningStopsTheDispatch`:

```text
XCTAssertEqual failed: ("dispatched") is not equal to ("staleDecision")
XCTAssertTrue failed  (submittedOperations 非空 —— job 真的提交了)
XCTAssertEqual failed: ("0") is not equal to ("1")   (decisionStale 事件数)
Executed 1 test, with 5 failures
```

也就是说:操作员在模型作答期间 pause + resume 了这个任务,**这一步照样被派发**。
恢复 guard 后同一用例 10/10 通过。

## 2. 交付面

| 面 | 落点 |
|---|---|
| 决策携带它所见的事实 | `HarnessDecision.observedStateVersion` + `basisDigest`;由 coordinator 在规划前取 basis 并 `stamped(with:)`,producer 无法自报 |
| 事实基线 | 新增 `HarnessDecisionBasis`(仅持久化事实:version/status/phase/round/activeJob/cancelRequested/bindingRevision/latestEvaluation/observedState/artifactRefs/consumedBudget/offeredOperations),canonical JSON + SHA-256 |
| 闸门位置 | `dispatch()` **第一件事**:重新 load → 重建 basis → `HarnessDecisionFreshness.staleness()`;不通过则零 intent、零 submit |
| 陈旧的代价 | 新增 causation `.decisionStale` 与 action `.staleDecision`:不记失败指纹、不加 no-progress、不动预算;模型调用照记 |
| ModelRun | 新增 `HarnessModelRun`(provider/model/adapterVersion/observedStateVersion/contextDigest/contextBytes/responseBytes/outcome/起止),store 落 `rounds/<n>/model-runs/<MRUN-*>.json`,ID 文法防路径逃逸 |
| Context digest | `HarnessDecisionContext.transmittedBytes/transmittedDigest/transmittedByteCount`:在裁剪与出站筛查**之后**计算,代表真正离开本机的字节 |

### 两处如实登记的偏离

1. **命名**:任务文本写的是 decision 携带 `contextDigest`。实现拆成两个名字,因为它们回答
   不同问题:`decision.basisDigest` = §11.4 的 `contextHash` 位(producer 所见的持久化事实),
   `modelRun.contextDigest` = §12.9 的**模型实收字节** digest。共用一个名字会让第二个含义消失。
2. **token 计数**:任务文本要 input/output tokens。决策端口返回的是 `Data`,token 是 adapter
   与厂商的概念,端口看不见。因此记的是**实测的字节数**,不是猜的 token;真实厂商 adapter
   (TASK-HFA-011)接入时再补 usage。同理 `HarnessModelDescriptor` 的默认值只写端口真正知道
   的 producerID,其余标 `unspecified`,不编造厂商与版本。

## 3. 命令与结果

```text
swift build                                   Build complete
swift test --filter HarnessStaleDecisionContractTests
                                              Executed 10 tests, 0 failures
swift test                                    Executed 950 tests, 1 skipped, 0 failures (129s)
```

本任务新增 10 例(`HarnessStaleDecisionContractTests`)。

## 4. AC 覆盖

| AC | 用例 |
|---|---|
| HFA-AC-3 | `testAHumanResolutionDuringPlanningStopsTheDispatch`(真竞态,零提交)、`testACancelDuringPlanningStopsTheDispatch`(取消落在窗口内,任务终态,零提交)、`testAChangedBasisIsStaleEvenWhenTheVersionHeld`(version 没动但可用 operation 收窄)、`testAnActiveJobAppearingUnderAProposalIsStale`、`testADecisionWithoutABasisIsUnverifiableRatherThanFresh`(旧记录 fail closed) |
| HFA-AC-4 | `testAStaleWakeChargesNoFailureNoProgressAndNoBudget`:noProgressRounds=0、consumedBudget 全 0、failureRecords 空;且下一轮正常派发(闭环没被毒化) |
| HFA-AC-5 | `testTheBasisDigestIsReproducibleAndMovesOnlyWithPersistedFacts`(同事实同 digest、offered 顺序不是事实、observedState 是)、`testAnAcceptedProposalRecordsTheModelCallItCameFrom`(run 与 decision 的 observedStateVersion 相等、contextDigest 等于实发字节 digest)、`testARefusedProposalStillRecordsTheModelCall`(被解析器拒的调用照样有记录)、`testAModelRunIdCannotEscapeItsTaskDirectory` |

## 5. 未覆盖(如实登记)

- **workspace / build / deploy 前置**:§11.4 还要求 `baseWorkspaceRevision`、build/deploy
  artifact digest 的比对。这些字段的**消费者**要等 TASK-HFA-003(修复腿)与 TASK-HFA-009
  (workspace 主体)。本任务没有留空校验占位——不存在的前置就是不存在,不写成恒真判断。
- **真机**:全部为 host 面用例。防陈旧闸在真实设备多轮执行下的表现属 TASK-HFA-005。
- **`requestHuman` / `noSafeAction` 分支**的同窗口竞态:这两条不派发副作用,当前仍由
  `commit` 的乐观锁拦截(会抛 versionConflict)。不在本任务范围内改动,登记在此。

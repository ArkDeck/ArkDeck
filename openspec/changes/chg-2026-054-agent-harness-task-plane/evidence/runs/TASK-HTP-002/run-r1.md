# TASK-HTP-002 run r1 — evaluation engine

- Date:2026-07-30
- Executor:agent(交互式会话),host-only
- Gate:同 TASK-HTP-001 的维护者提前解冻(2026-07-30);前置 TASK-HTP-001 已 done(#845 合入)
- Effect:hostOnly / readOnly。零 HDC dispatch、零 capability 消耗、零 job 创建
- Authority:default read-only policy(E0)

## 1. 库层套件

```text
swift test --package-path Packages/ArkDeckKit
Executed 763 tests, with 1 test skipped and 0 failures (0 unexpected) in 61.330s
```

新增 `HarnessEvaluationContractTests` 15 例(HTP-AC-5/6/7);TASK-HTP-001 的 20 例在
新架构下全绿(evaluator 接管后,「无 evaluator 组合」的诚实停止改由 coordinator 产出,
reasonCode 不变 = `evaluationEngineUnavailable`)。

实现期抓出并修的缺陷:**乐观锁冲突**。evaluation 在同一次唤醒里提交第二条 transition
后,`apply()` 仍把**旧版本快照**交回 reconcile,下一次 commit 因 expectedVersion 过期
被拒(`versionConflict(expected: 4, actual: 5)`)。改为 `EvaluationStep.{ended,continues}`
显式把新版本快照交回;这正是 HTP-AC-3 乐观锁在实现中咬到的第一例。

## 2. 判定语义(逐条有测试)

| 规则 | 测试 |
|---|---|
| 只有 evaluator 能进 `succeeded`(事件 causation 恒为 `evaluation`,且带 evaluationId) | `testSuccessIsReachableOnlyThroughAPassingEvaluation` |
| 无 mandatory criterion → `inconclusive`(「没什么要查」不是修好) | `testNoMandatoryCriterionIsInconclusiveNotPass` |
| 样本不足 → `inconclusive` + `insufficientSamples:n/m`;够了才判 | `testSampleGateAndIntegrityDominateTheVerdict` |
| hash 不符 → `error`(「测不出」≠「坏了」),不产出任何 measurement | 同上 + `testHashMismatchIsAnIntegrityBlockerAndYieldsNoMeasurement` |
| `inconclusive` 升级取最严策略(requestHuman 不被 collectMore 稀释) | `testComparatorsAndEscalationSelection` |
| observedState 只能由 `jobObserved`/`evaluation`/`recovery` 写 | `testObservedStateCannotBeWrittenWithoutEvidence` |
| counter 跨轮累加、latest 覆盖,JSON 往返一致 | `testObservedStateAccumulatesCountersAndReplacesLatestValues` |

## 3. 证据完整性一律 fail closed(HTP-AC-7)

`HarnessObservationBuilder` 先验后测:读满字节并重算 SHA-256 与 artifact store 记录
比对,只有 `verified` 的字节才参与测量。

| 情形 | 分类 | 结果 |
|---|---|---|
| 声明但未发布(`upstreamCaptureFailed`) | collection blocker | `artifactMissing:hilog.txt:upstreamCaptureFailed` |
| 零字节 | collection blocker | `artifactEmpty:hilog.txt` |
| 超出评估读取上限 | collection blocker | `artifactExceedsEvaluationBound:...`(前缀 hash 证明不了任何事) |
| sensitive 未 opt-in | collection blocker | `artifactSensitiveNotOptedIn:...`,且**零读取** |
| hash 不符 | integrity blocker | `artifactHashMismatch:...` → verdict `error` |
| 需求 artifact 从未采集 | collection blocker | `artifactNotCollected:hilog.txt` |
| inventory 不可用 | collection blocker | `artifactInventoryUnavailable:<job>`(不是「空观测」) |

crash 扫描形态:`Reason:Signal:SIG*` 起块 + `#NN pc … (symbol+off)` 取首个**非 libc**
帧;声明签名按 `+` 拆 token,全部出现在故障块内才算 matching(不做格式化字符串相等,
否则帧偏移或库路径一变就漏)。

**如实登记**:上述 hilog fixture 是按 OpenHarmony cppcrash 文档形态**host 手写**的,
仓内目前不存在真机 hilog/crash 字节样本。因此 HTP-AC-7 的「真机字节」那一半仍是
pending-hardware,由 TASK-HTP-006 的设备窗口关闭;本轮不以 fixture 顶替真机结论。

## 4. 进程级实跑(host,真实 UDS)

```text
$ arkdeck-agentd --state-dir /tmp/adh2          # 组合根现在注入 artifact port
$ arkdeck task submit --target TGT-notadoptedyet \
    --goal "No WaterFlow SIGABRT across five runs" \
    --crash-signature "SIGABRT+WaterFlowPattern::RecoverBack" --max-rounds 4
htaskId=HTASK-12F75CFDAC51
criteria = [(DC-1 matchingCrashCount, minSamples 5, evidence [hilog.txt], collectMoreEvidence),
            (DC-2 applicationLiveness, 1, [hilog.txt], collectMoreEvidence),
            (DC-3 newFatalSignatureCount, 1, [hilog.txt], collectMoreEvidence)]

$ arkdeck task evaluations --task HTASK-12F75CFDAC51     → []      # 还没有证据可判
$ arkdeck task reconcile  --task HTASK-12F75CFDAC51
action=stoppedForHuman reasonCode=submissionRejected status=humanRequired
  # 引擎拒绝(target 未接管);零 job、零 capability 消耗,与 001 同一条 fail-closed 路径
```

## 5. 本轮**未**验证的部分(如实登记)

- **真机字节**:见 §3。真实 hilog/ui-dump 驱动的 observation 与真机收敛属 TASK-HTP-006;
- **Policy Guard / 预算矩阵 / 失败指纹 / 结构化 HumanActionRequired**:TASK-HTP-003;
- **修复能力**:criteria 判 `fail` 时 handler 交人工(`criteriaFailedNoRepairCapability`),
  因为 patch/build 属 TASK-HTP-005;本任务不假装能修;
- **模型**:未接入。判定与规划全为仓内确定性代码(TASK-HTP-004 才引入可替换决策端口)。

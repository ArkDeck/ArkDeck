# TASK-HTP-001 run r1 — harness task plane skeleton

- Date:2026-07-30
- Executor:agent(交互式会话),host-only
- Gate:维护者在本会话显式解冻 TASK-HTP-001/002(§20 提前解冻,理由:E0-only、
  零设备 mutation、零源码写入,只消费 GJ-1 已有产物)。本任务未执行任何设备命令。
- Effect:hostOnly / readOnly。零 HDC dispatch、零 capability 消耗、零 job 创建。
- Authority:default read-only policy(E0);无 E1/E2 授权参与。

## 1. 库层套件

```text
swift test --package-path Packages/ArkDeckKit
Executed 748 tests, with 1 test skipped and 0 failures (0 unexpected) in 59.126s
```

新增 `HarnessTaskPlaneContractTests` 20 例(HTP-AC-1..4 + 有界停止/取消/typed 请求面
负例),单独跑:

```text
swift test --filter HarnessTaskPlaneContractTests
Executed 20 tests, with 0 failures (0 unexpected) in 0.199s
```

三个由测试抓出并已修的真实缺陷(实现期,非事后补测):

1. `pause` 被 reducer 拒绝——原规则要求 `activeJobID` 仅在 `running` 下存在,而暂停
   **不应**放弃引擎已持有的 job。改为「仅终态任务不得声明 active job」
   (`activeJobOnTerminalTask`)。
2. 未知但形态合法的 htaskId 报 `ioFailure`(锁目录不存在),而不是 `notFound`;
   daemon 因此回 `internalError`。新增 `existingDirectory()`,读写既有任务统一走它。
3. `transition(activeJobID:)` 用 `String??` 表达三态,`nil` 同时意味着「清空」和
   「不变」——改为显式 `ActiveJobChange { unchanged, cleared, set }`。

## 2. 进程级实跑(host,真实 UDS + 真实引擎)

库层绿 ≠ 进程级可用(仓内两次教训),故 host 侧实跑二进制。

```text
$ arkdeck-agentd --state-dir /tmp/adh1
arkdeck-agentd listening on /tmp/adh1/agentd.sock      # 新建 harness/ 状态目录

$ arkdeck task submit --target TGT-notadoptedyet \
    --goal "No SIGABRT in WaterFlow::RecoverBack across five runs" --max-rounds 3 --json
htaskId=HTASK-8EBCCC0182B4 status=created phase=initializing
allowedOperations=[capture.diagnostics@1, observe.device@1]
successCriteria=DC-1..DC-3(默认三条,由 handler 提供;本任务只登记不评判)

$ arkdeck task reconcile --task HTASK-8EBCCC0182B4
action=stoppedForHuman reasonCode=submissionRejected dispatchedJobId=null status=humanRequired

$ arkdeck task reconcile --task HTASK-8EBCCC0182B4   # 第二次唤醒
action=awaitingHuman   # 人工阻塞不自解,零重复提交

$ arkdeck task result --task HTASK-8EBCCC0182B4
"Runtime admission refused observe.device@1: rejected(invalidInput,
 \"observe.device@1 is runtime unavailable: no HDC executable configured
 (set ARKDECK_HDC_PATH); dispatch stays fail-closed\")"
```

即:harness 自动推出 E0 第一步、构造 typed 请求、由**引擎**拒绝并把机器可读原因
如实写入 task result;dispatch intent 落 `rejected`(零副作用、恢复不重试)。

### 重启 + typed resume(HTP-AC-4 的进程级面)

```text
$ kill -TERM <pid>; ARKDECK_HDC_PATH=<DevEco hdc> arkdeck-agentd --state-dir /tmp/adh1
$ arkdeck task list      → HTASK-8EBCCC0182B4 humanRequired initializing v3   # 逐字保持
$ arkdeck task resume --task ... --resolution "operator: configured ARKDECK_HDC_PATH and retried"
                         → running initializing v4
$ arkdeck task reconcile → stoppedForHuman / submissionRejected
$ arkdeck task result    → "target facts cannot materialize the typed plan before
                            authorization: factsUnavailable(\"target TGT-notadoptedyet
                            has not been adopted\")"
$ arkdeck job list       → []            # 全程零 job、零 dispatch、零 capability 消耗
```

事件时间线(`harness/tasks/HTASK-8EBCCC0182B4/events.jsonl`,4 行,
sha256 前 32 位 `278c44ec4ee816691f6475b28836252e`):

```text
1 admitted       created       -> running        taskAdmitted
2 humanBlocked   running       -> humanRequired  submissionRejected
3 humanResolved  humanRequired -> running        operator: configured ARKDECK_HDC_PATH and retried
4 humanBlocked   running       -> humanRequired  submissionRejected
```

磁盘布局(实测):`harness/tasks/<HTASK>/{task.json, events.jsonl, .lock,
rounds/1/{decision.json, dispatch-intent.json}}`;round 1 intent 终态
`state=rejected`、`jobId=null`、`idempotencyKey=htask-d730df43f703…`。

## 3. 本轮**未**验证的部分(如实登记)

- **真实设备闭环**:未接管设备(手上 DAYU200 设备侧信任未完成),因此进程级实跑只走到
  「未接管 target → fail closed」。真实 dispatch → artifact → 收敛属 TASK-HTP-006,
  维持 hardware-pending,不以本次 host 运行顶替。
- **Evaluation**:不存在(TASK-HTP-002)。`succeeded` 在 reducer 层结构性不可达
  (需 `evaluation` causation + evaluationId),故本任务的任何路径都不会宣布成功;
  证据收齐后 handler 产出 `requestHuman(evaluationEngineUnavailable)`。
- **完整 Policy Guard / 预算矩阵 / 失败指纹 / 结构化 HumanActionRequired**:
  TASK-HTP-003。本任务只落了不可缺的三条:allowedOperations 闭集、round/wall-clock
  预算停止、`outcomeUnknown` 立即停止且不重发。

# Workflow, Journal, and Recovery Specification

> Version：1.0.0  
> Status：review candidate  
> Baseline：CORE-1.0.0  
> Applicability：all platforms

## Purpose

定义外部副作用、Job 状态、取消、持久化、崩溃恢复和进程执行的不可变语义。

## Requirements

### Requirement: REQ-WF-001 Closed typed workflow steps

Workflow SHALL 只组合批准的 typed step，例如 HDC/remote tool、send/receive、parameter snapshot/set/restore、wait、verify、storage preflight、postprocess、owned cleanup 和 confirmation。Profile SHALL NOT 注入任意 host shell。

#### Scenario: AC-WF-001-01 非法自由命令

- GIVEN Profile 包含未注册的 host command string
- WHEN schema/plan 校验
- THEN计划被拒绝
- AND外部进程调用数为 0

### Requirement: REQ-WF-002 Core minimum effect classification

每个 typed step SHALL 具有 Core 不可降低的 `hostOnly | readOnly | deviceMutation | destructive` minimum effect。Provider/Profile MAY 提高风险等级；未知 step SHALL 按 destructive fail closed。

#### Scenario: AC-WF-002-01 Profile 错标 erase 为 readOnly

- GIVEN Profile 尝试降低 erase step 的 effect
- WHEN生成计划
- THEN Core classification 覆盖该声明
- AND step 仍为 destructive

### Requirement: REQ-JOB-001 Distinct Job terminal states

Job SHALL 使用以下 Core transition graph；未列出的 transition SHALL fail closed 并记录 invariant violation。平台 SHALL NOT 新增绕过确认、recovery 或 cancellation 的状态路径。

```text
execute:
  queued → preflight → running ↔ waitingForDevice ↔ awaitingRebindConfirmation
                        ├→ finalizing → succeeded
                        └→ waitingForRecovery

  any execute nonterminal except userAbandonRequested/finalizing
    --confirmed failure--> finalizing → failed
  any active execute nonterminal --external outcome/identity unknown--> waitingForRecovery
  any cancellable execute nonterminal → cancelRequested
                                      → cancellingAtSafeBoundary → cancelled

  waitingForRecovery --explicit reconcile/recovery request--> reconciling
  reconciling ├→ resumeAtConfirmedSafeBoundary → running
              ├→ finalizing → failed
              └→ waitingForRecovery
  waitingForRecovery → userAbandonRequested → interrupted
                              └--audit/finalization failed--> waitingForRecovery

plan-only:
  queued → preflight → planning → finalizing → planned
  queued | preflight | planning --confirmed failure--> finalizing → failed
  any cancellable plan-only nonterminal → cancelRequested
                                        → cancellingAtSafeBoundary → cancelled

launch recovery:
  nonterminalOnLaunch → reconciling
                      ├→ resumeAtConfirmedSafeBoundary → running | planning
                      ├→ finalizing → failed
                      └→ waitingForRecovery → userAbandonRequested → interrupted
```

`confirmed failure` SHALL 表示失败及其外部副作用结果均已确定；只要设备身份或 external-effect outcome 仍未知，系统 SHALL 进入或保持 `waitingForRecovery`，不得用 `failed` 掩盖未知结果。`waitingForRecovery` 只能通过显式的 Provider recovery/reconcile 请求进入 `reconciling`，或者通过经审计的用户放弃进入 `userAbandonRequested`。只有 Provider 声明 restart-safe、安全边界已确认、最后 outcome 确定且设备 binding 已确认时，`reconciling` 才能进入 `resumeAtConfirmedSafeBoundary`；能确定失败且无需猜测副作用时才能进入 `finalizing → failed`。否则 SHALL 回到 `waitingForRecovery`。

`cancellable nonterminal` SHALL 排除 `waitingForRecovery`、`userAbandonRequested`、`reconciling` 和 `finalizing`。执行 `criticalNonInterruptible` Step 时，取消请求仍 SHALL durable 记录并进入 `cancellingAtSafeBoundary`，该状态表示等待 Provider 报告安全边界，而不是强杀当前进程；到达安全边界后才进入 `cancelled`。`planned`、`succeeded`、`failed`、`cancelled` 和 `interrupted` SHALL 是不同终态。终态 Job SHALL NOT 接受新的 external-effect Step。UI、manifest、History 和导出 SHALL NOT 把这些状态折叠为同一个“完成”。

#### Scenario: AC-JOB-001-01 Planned 不是刷机成功

- GIVEN plan-only 完整计划已持久化
- WHEN Job 终结
- THEN状态为 planned
- AND硬件成功计数不增加

#### Scenario: AC-JOB-001-02 非法终态迁移

- GIVEN Job 已处于 succeeded、planned、failed、cancelled 或 interrupted
- WHEN任何组件请求迁移回 running 或派发 external-effect Step
- THEN请求被拒绝并记录 invariant violation

#### Scenario: AC-JOB-001-03 Recovery 不得绕过确认

- GIVEN启动时发现没有 outcome 的 destructive intent
- WHEN Reconciler 运行
- THEN允许的路径只有 waitingForRecovery
- AND不得直接迁移到 running/succeeded 或重放该 Step

#### Scenario: AC-JOB-001-04 Execute preflight 确定失败

- GIVEN execute Job 在 preflight 得到已确认且没有未知外部副作用的失败
- WHEN状态机处理失败
- THEN路径为 preflight → finalizing → failed
- AND该 Job 不会永久停留在非终态

#### Scenario: AC-JOB-001-05 Waiting recovery 的受控恢复

- GIVEN Job 因设备身份或外部 outcome 未知而处于 waitingForRecovery
- WHEN用户发起 Provider recovery/reconcile
- THEN下一状态只能是 reconciling
- AND只有 restart-safe、安全边界、确定 outcome 和已确认 binding 全部成立时才能经 resumeAtConfirmedSafeBoundary 回到 running
- AND任一条件不成立时回到 waitingForRecovery，且不派发未知 Step

#### Scenario: AC-JOB-001-06 普通步骤取消

- GIVEN execute Job 正处于可取消的 running Step
- WHEN用户请求取消
- THEN路径为 cancelRequested → cancellingAtSafeBoundary → cancelled
- AND取消结果与安全边界写入 journal

### Requirement: REQ-JOB-002 Write-ahead intent and durable outcome

任何外部副作用前，系统 SHALL durable 写入 typed step intent、attempt、target/binding revision、arguments hash 和 compensation descriptors；执行完成后 SHALL 写 outcome 再原子更新 snapshot。关键持久化失败 SHALL 阻止下一步。

#### Scenario: AC-JOB-002-01 Intent 同步失败

- GIVEN journal 写入或同步失败
- WHEN外部 Step 准备执行
- THEN外部命令不启动
- AND Job 进入明确失败/恢复状态

### Requirement: REQ-JOB-003 Typed cancellation policy

每个 Step SHALL 声明 `immediate | atSafeBoundary | criticalNonInterruptible`。Critical step 收到取消后 SHALL 只记录请求并在 Provider 安全边界停止后续步骤，SHALL NOT 强杀正在写分区的进程。

#### Scenario: AC-JOB-003-01 Flash 中延迟取消

- GIVEN partition write 正处于 criticalNonInterruptible
- WHEN用户点击取消
- THEN状态进入 cancellingAtSafeBoundary
- AND当前进程不被强制终止

### Requirement: REQ-JOB-004 Compensation preserves the original failure

参数恢复、停止采集和 owned cleanup 等补偿 SHALL 保存 typed descriptor 并在 success/failure/cancel 的适用路径执行。补偿失败 SHALL 单独记录、标记 `needsAttention`，且 SHALL NOT 覆盖原始错误。

#### Scenario: AC-JOB-004-01 Restore 失败

- GIVEN Trace capture 失败且参数恢复也失败
- WHEN Job finalization
- THEN manifest 同时包含 capture failure 和 restore failure
- AND设备保持 needsAttention

### Requirement: REQ-JOB-005 Semantic process results

外部进程 SHALL 使用绝对 executable 和 argument array，不使用 host shell。Runner SHALL 流式分离 stdout/stderr，处理无效 UTF-8、大输出、timeout 和取消，并结合退出码与 Adapter 语义判断结果。

#### Scenario: AC-JOB-005-01 路径和参数不进入 shell

- GIVEN 工具或镜像路径包含空格、中文或 shell 元字符
- WHEN进程启动
- THEN字符按单个 argv 传递
- AND没有 shell expansion

### Requirement: REQ-JOB-006 Crash reconciliation never guesses

启动并取得单实例锁后，系统 SHALL 扫描未 finalize Session。只有 Provider 声明 restartSafe、最后 outcome 确定且设备匹配时 MAY 从安全边界恢复。只有 intent 没有 outcome SHALL 标记 `outcomeUnknown`；destructive step SHALL NOT 自动重放或猜测性补偿。

#### Scenario: AC-JOB-006-01 Flash outcome 缺失

- GIVEN App 在 flash intent durable 后、outcome 前崩溃
- WHEN重启 reconcile
- THEN Job 进入 waitingForRecovery/outcomeUnknown
- AND flash dispatch 数不增加

### Requirement: REQ-JOB-007 Audited recovery abandonment

用户 MAY 从 `waitingForRecovery` 选择“结束恢复并归档为 interrupted”。系统 SHALL 先 durable 写 abandon intent，按策略停止 managed host process，等待 critical child 安全边界，再 durable 写 terminal outcome，之后才释放 device lane 和 storage claim。该动作 SHALL NOT 声称设备恢复或自动清理远端副作用。

#### Scenario: AC-JOB-007-01 审计失败不释放资源

- GIVEN abandon terminal outcome 无法持久化
- WHEN用户确认归档
- THEN Job 保持 waitingForRecovery
- AND lane/claim 不因虚假归档而释放

#### Scenario: AC-JOB-007-02 Unresolved hazard 阻断冲突任务

- GIVEN interrupted Session 记录未知远端任务或参数变更
- WHEN新的冲突 Job preflight
- THEN默认 fail preflight
- AND只有 Provider 允许且用户显式风险 override 并审计后 MAY 继续

### Requirement: REQ-JOB-008 Single writer application instance

同一用户和产品 SHALL 只有一个可写 ArkDeck 实例。第二实例 SHALL NOT 访问 HDC 或 Session，MAY 请求激活主实例后退出。锁不可用或不可靠时 SHALL fail closed 到只读诊断状态。

#### Scenario: AC-JOB-008-01 双实例竞争

- GIVEN 主实例持有锁
- WHEN第二实例启动
- THEN第二实例不创建 Job、不触碰 HDC、不写 Session

### Requirement: REQ-NFR-001 Cross-platform clock semantics and explicit progress

审计时间 SHALL 使用 wall-clock/UTC；进程存活期间的时间判断 SHALL 使用可注入的跨平台单调时钟，而不是 wall-clock。系统 SHALL 区分两种语义：overall deadline/timeout 使用系统休眠期间仍推进的 elapsed/continuous monotonic clock；active-work duration、throughput 和 ETA sample 使用休眠期间暂停的 awake-work/suspending monotonic clock。平台 API 名称可以不同，但语义 SHALL 一致。

跨进程 checkpoint SHALL 持久化 accumulated elapsed/active duration、配置的 deadline/timeout 和对应 UTC wall timestamp，SHALL NOT 持久化或比较只在单一进程内有效的 monotonic instant/tick origin。重启后若 wall-clock 回退或无法证明 deadline 尚未到期，deadline SHALL fail safe 为 expired 或要求用户重新进入有界恢复流程，不得猜测延长。系统 wake 后 SHALL 开启新的 throughput/ETA segment，不得把休眠时间或休眠前的瞬时速率混入新 sample。只有 Adapter 提供可靠 completed/total 时 MAY 显示百分比、ETA 和吞吐，否则 SHALL 显示 indeterminate。

#### Scenario: AC-NFR-001-01 Wall clock 跳变

- GIVEN wall clock 因 NTP 前后跳
- WHEN timeout 和 duration 运行
- THEN其结果不受 wall-clock 跳变污染

#### Scenario: AC-NFR-001-02 系统休眠跨过 overall deadline

- GIVEN overall deadline 尚余 30 秒且系统休眠 60 秒
- WHEN系统唤醒
- THEN elapsed/continuous deadline 已到期
- AND active-work duration 不增加该 60 秒

#### Scenario: AC-NFR-001-03 唤醒后重置速率样本

- GIVEN 传输在休眠前已有 throughput 和 ETA sample
- WHEN系统从休眠唤醒且传输继续
- THEN系统建立新的 throughput/ETA segment
- AND首个新 sample 不使用休眠时长或休眠前瞬时速率计算

#### Scenario: AC-NFR-001-04 重启不复用进程内 tick

- GIVEN 未完成 Job 的 checkpoint 包含 accumulated duration 和 UTC timestamp
- WHEN App 在新进程中 reconcile
- THEN不读取旧进程的 monotonic instant/tick origin 作为当前时间基准
- AND wall-clock 回退或剩余 deadline 无法证明时按 fail-safe deadline 策略处理

### Requirement: REQ-NFR-002 Large data is streamed

GB 级镜像、日志和 Artifact SHALL 流式读取、hash 和写入，内存 SHALL NOT 随文件大小线性增长。

#### Scenario: AC-NFR-002-01 稀疏大文件

- GIVEN GB 级或稀疏 fixture
- WHEN执行 hash/transfer pipeline
- THEN峰值内存保持在实现声明的有界窗口内

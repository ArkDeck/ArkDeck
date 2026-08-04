# Workflow, Journal, and Recovery Specification

> Version：3.0.0
> Status：in baseline CORE-3.0.0（ratification 状态见 `openspec/baselines/CORE-3.0.0.yaml`）
> Baseline：CORE-3.0.0
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

### Requirement: REQ-WF-004 Trusted Runtime facts and truthful hardware evidence

Runtime SHALL 仅从同一 Job 的 durable intent/outcome、trusted target/binding/tool facts 和
已发布 Artifact metadata 推导 realHardware evidence。Agent E0/readOnly SHALL 记录
`defaultReadOnlyPolicy`；E1/deviceMutation SHALL 记录 `runtimeCapability`；E2/destructive
SHALL 记录 `standingAuthorization` 或 `evolutionCampaignConfirmation`。每个 E2 evidence
reference SHALL 精确匹配首个 destructive intent 前接受的 authority；campaign reference
还 SHALL 包含 durable campaign/attempt 和 ordinal correlation。schema validation、evidence
packaging、imported Manifest、caller assertion 或事后聊天消息 SHALL NOT mint、变更、扩大或
追溯提供 authority。

缺失、stale、mismatched、unknown 或非 durable trusted facts；authority/effect mismatch；
未匹配 intent/outcome；缺失 candidate pin；或不可验证 Artifact hash SHALL 阻止 evidence
publication。该 blocker SHALL NOT 把 Job 变为 success，也 SHALL NOT dispatch 或 replay device
Step。target identity 与 raw artifacts 继续适用隐私和不可变规则；历史 V2/V3 evidence 保持
不可变、可 decode。

#### Scenario: AC-WF-004-01 Agent evidence facts complete

- GIVEN Agent 完成真实 E0、E1 或 E2 typed run，且同一 Job 有完整 fresh target/binding/tool
  facts、admission decision、durable Step outcomes 和 immutable Artifact metadata
- WHEN Runtime projects hardware evidence
- THEN record 包含实际 executor/effect/Step kinds、匹配的 `defaultReadOnlyPolicy`、
  `runtimeCapability`、`standingAuthorization` 或 `evolutionCampaignConfirmation` provenance、
  target confirmation 和 Artifact hashes
- AND record 通过 schema 与 semantic correlation validation，且不 mint authority

#### Scenario: AC-WF-004-02 Required evidence facts are untrusted or incomplete

- GIVEN Agent run 缺少 required trusted fact、target/binding stale 或 mismatch、authority/effect
  mismatch，或 Artifact hash 不可验证
- WHEN Runtime 被请求发布 hardware evidence
- THEN Runtime 返回 `evidenceIncomplete`，schema-valid realHardware publication 为 0
- AND caller fields、historical receipt、human text 或事后聊天消息不能使 run PASS 或 authorize Step

#### Scenario: AC-WF-004-03 Campaign evidence cannot substitute for authority

- GIVEN destructive Agent Job 声称 `evolutionCampaignConfirmation`，但 evidence 缺少匹配的
  durable campaign/attempt reservation、authority pin、fresh target confirmation、intent/outcome
  correlation 或 actual Artifact hash
- WHEN Runtime projects Job
- THEN evidence publication 为 0，Job 如实报告 incomplete/policy blocker
- AND不发生新 device dispatch、authority minting 或 replay

### Requirement: REQ-JOB-001 Distinct Job terminal states

Job SHALL 使用以下 Core transition graph；未列出的 transition SHALL fail closed 并记录 invariant violation。平台 SHALL NOT 新增绕过确认、recovery 或 cancellation 的状态路径。

```text
execute:
  queued → preflight → running ↔ waitingForDevice ↔ awaitingRebindConfirmation
                        ├→ finalizing → succeeded
                        └→ waitingForRecovery

  any execute nonterminal except userAbandonRequested/finalizing/waitingForRecovery
    --confirmed failure--> finalizing → failed
  any active execute nonterminal --external outcome/identity unknown--> waitingForRecovery
  any cancellable execute nonterminal → cancelRequested
                                      → cancellingAtSafeBoundary → cancelled

  waitingForRecovery --explicit reconcile/recovery request--> reconciling
  reconciling ├→ resumeAtConfirmedSafeBoundary → running
              ├→ finalizing → failed
              └→ waitingForRecovery
  resumeAtConfirmedSafeBoundary
              ├--confirmed failure--> finalizing → failed
              └--external outcome/identity unknown--> waitingForRecovery
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
  resumeAtConfirmedSafeBoundary
                      ├--confirmed failure--> finalizing → failed
                      └--external outcome/identity unknown--> waitingForRecovery
```

`confirmed failure` SHALL 表示 failure、设备身份及其外部副作用结果均已确定；只要设备身份或任一 external-effect outcome 仍未知，系统 SHALL 进入或保持 `waitingForRecovery`，不得用 `failed` 掩盖未知结果。`waitingForRecovery` 只能通过显式的 Provider recovery/reconcile 请求进入 `reconciling`，或者通过经审计的用户放弃进入 `userAbandonRequested`。只有 Provider 声明 restart-safe、安全边界已确认、最后 outcome 确定且设备 binding 已确认时，`reconciling` 才能进入 `resumeAtConfirmedSafeBoundary`；能确定失败且无需猜测副作用时才能进入 `finalizing → failed`。否则 SHALL 回到 `waitingForRecovery`。

`resumeAtConfirmedSafeBoundary` SHALL 是恢复控制标记而非普通 Workflow Step 派发阶段。Job SHALL 先转移到 `running` 或 `planning` 才能派发普通 Step。若在该转移前发现 confirmed failure，Job SHALL 直接进入 `finalizing → failed`；若设备身份或任一 external-effect outcome 未知，Job SHALL 直接进入 `waitingForRecovery`。这两个分支 SHALL NOT 先伪造 `running` 或 `planning` 状态，且在 marker 状态的普通 Step 派发数 SHALL 为 0。未知 Step SHALL NOT 被派发、重放或猜测性补偿。

Journal transition-pair contract SHALL 同时允许 `resumeAtConfirmedSafeBoundary → finalizing` 与 `resumeAtConfirmedSafeBoundary → waitingForRecovery`。Pair membership 不构成语义授权：semantic validator SHALL 仅在 failure、identity 与全部 external-effect outcome confirmed 时接受前一 pair，仅在 identity 或至少一个 external-effect outcome unknown 时接受后一 pair；evidence 与 pair 不匹配时 SHALL 拒绝并记录 invariant violation。

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

#### Scenario: AC-JOB-001-07 Resume marker 的二值失败/未知决策

- GIVEN Job 已通过恢复确认并 durable 进入 resumeAtConfirmedSafeBoundary
- AND Job 尚未转移到 running 或 planning，且尚未派发普通 Workflow Step
- WHEN状态机分别评估以下 decision vectors
  - confirmed：failure、设备身份与全部 external-effect outcome 均已确定
  - unknown identity：设备身份未知
  - unknown outcome：至少一个 external-effect outcome 未知
- THEN confirmed vector 的精确路径为 resumeAtConfirmedSafeBoundary → finalizing → failed
- AND unknown identity 与 unknown outcome vectors 的精确目标均为 waitingForRecovery
- AND所有 vectors 在 resumeAtConfirmedSafeBoundary 状态的普通 Workflow Step 派发数均为 0
- AND confirmed 与 unknown vectors 在 marker 和目标状态之间的 running/planning transition 数均为 0

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

# TASK-HTP-004 run r1 — decision gateway、严格结构化输出与出站边界

- Date:2026-07-31
- Executor:agent(交互式会话),host-only
- Gate:同 TASK-HTP-001 的维护者提前解冻;前置 TASK-HTP-003 已 done(#858 合入)
- Effect:hostOnly / readOnly。零 HDC dispatch、零 capability 消耗、零 job 创建、**零出站**
- Authority:default read-only policy(E0)

## 1. 套件

```text
swift test --package-path Packages/ArkDeckKit
Executed 843 tests, with 1 test skipped and 0 failures (0 unexpected) in 64.454s
```

新增 `HarnessDecisionGatewayContractTests` 14 例(HTP-AC-12/13/14);001–003 的 55 例全绿。

## 2. 入站:严格 schema(HTP-AC-12)

`HarnessDecisionProposal.parse` 用**封闭键集**解码,并显式列出禁止键。

- `testStateRetryAndSuccessFieldsAreRejectedNotIgnored` 逐字段断言 12 个禁止键
  (status / phase / result / retryCount / verdict / succeeded / authorization /
  capabilityId / effect / budget / activeJobId / version)一律 **`forbiddenField` 拒绝**,
  不是忽略 —— 忽略会让模型以为自己决定了什么;
- 未知键、未知 kind、非 JSON → 各自拒绝;
- **raw 面同时管 inputs 与散文**:`hypothesis` 里夹 `hdc shell rm -rf /data/local/tmp`
  一样被拒(散文也会进 durable 记录);
- `operationRef` 必须在**本轮 offered 集合**内(offered = task 允许集 ∩ task type 许可集),
  越界给 `operationNotOffered` —— 比"不许可"更准:模型被明确告知过本轮桌面上有什么;
- 空 hypothesis、超长字段拒绝。

## 3. 出站:默认 deny(HTP-AC-13)

`HarnessEgressPolicy.deniedByDefault`:无项目级显式开启 → **零 context 出户**,
loop 继续跑内建确定性 handler。

- `testEgressIsDeniedByDefaultAndNoContextLeavesTheHost`:断言 gateway 一次都没被调用、
  任务照常 `dispatched`、reasonCode 含 `egressDenied:egressNotEnabledForProject`,
  且回退**记进 task memory**(不是静默跳过);
- 无 projectRef → `egressRequiresProjectRef`(拒);
- 开启后的 context:`targetPseudonym` = 单向摘要(断言 ≠ 原 targetID),
  `HarnessEgressScreen.violations` 断言不含 targetID / connectKey / serial /
  stablePhysicalIdentity / 远端路径;artifact 只带 id、name、byteCount、sha256 前缀与
  verified,**不带内容**;
- 裁剪**显式记录**:`trimmed: ["attempts:kept1of4", "operations:kept1of2", …]`,
  超过字节上限则**拒绝发送**(`contextTooLarge`)而不是悄悄截断,调用方退回确定性策略。

生产接线:`ARKDECK_HARNESS_EGRESS_PROJECTS=app-a,app-b` 才开;未设即 deny,daemon 日志
只在开启时打印一行。本轮进程实跑未设该变量,故全程零出站。

## 4. 端口可替换(HTP-AC-14)

`testConclusionsFollowTheStepNotTheProducer`:同样两步(observe → capture),一次由内建
handler 提出、一次经端口由脚本化模型提出(第三拍模型不可达),断言两条 trace **逐项相等**
且都以 `stoppedForHuman` 收尾 —— 结论跟着**步骤**走,不跟提出者身份走。

`testTaskStateHoldsNoModelSessionHandle`:decision 记录里有 producer id,task 快照里
扫不到 session / conversation / messages / apiKey / token。

`testARejectedProposalFallsBackVisiblyAndChangesNothingElse`:模型宣称
`status: succeeded` → 整条拒绝 → 回退确定性策略,任务**没有**变成 succeeded,
reasonCode 带 `proposalRejected:forbiddenField:status`,回退写进 memory。

## 5. 实现期由测试/实跑抓出的两个真问题

1. **删掉了 `DeterministicDecisionGateway`**。它号称"确定性 handler 装在端口后面",实际按
   排序挑第一个 operation → 会在设备还没被观测时先跑 capture,phase 永不前进;AC-14 的等价
   性测试直接把它照出来。内建生产者本来就是 handler(无 gateway 时协调器直接用),再包一层
   就是**第二份会漂移的实现**(同 guard 那条教训)。端口只留给仓外生产者;文件里写明理由,
   防止后人再加回来。
2. **guard 拒绝没有进 task memory**。job 失败、admission 被拒都有记录,唯独 guard 自己拒绝
   的那一步没有 —— 而它恰恰是"试了什么、为什么没发生"最需要解释的一类。已补:`stop()` 写一条
   `attempt` 记忆(证据 = decision id),并加断言。

## 6. 进程级实跑(host,真实 UDS)

guard 的 availability/capability 端口这次接进了生产组合根,停止点因此更早、原因更准:

```text
$ arkdeck task submit --target TGT-notadoptedyet --project demo-app \
    --goal "No WaterFlow SIGABRT" --crash-signature "SIGABRT+WaterFlowPattern::RecoverBack"
$ arkdeck task reconcile
reconcile: stoppedForHuman | operationUnavailable:observe.device@1
   # 引擎都不必收到请求;零 dispatch、零 capability 消耗
humanActions: block=environmentUnavailable | reason=operationUnavailable:observe.device@1 | doc=none
task memory: (修复前为空 → 修复后含 "guard refused the proposed step: operationUnavailable:…")
```

## 7. 本轮**未**验证的部分(如实登记)

- **真实模型适配器**:本轮不含任何厂商 adapter(`decisionGateway: nil`),端口与解析面由
  脚本化 double 覆盖。接入真实模型时其唯一新增面是 transport,解析与出站边界不变;
- **真机**:未接管设备,真机收敛仍属 TASK-HTP-006(pending-hardware);
- **workspace 操作**:patch/build/test 属 TASK-HTP-005,因此 `requestHuman` 仍是
  criteria 判 fail 时的终点。

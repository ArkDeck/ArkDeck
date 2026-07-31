# TASK-HFA-011 run r1 — 三家厂商 adapter,以及「一次调用花掉了什么」

- Date:2026-07-31
- Executor:agent(维护者指示:完成全部 HFA;§20 冻结门显式提前解冻)
- Source baseline:`main@c4c7b69c`(#897 已合入)
- Hardware:none
- 网络:**零**。全部用例经 fake transport;仓内无密钥,测试用哨兵串只用于断言"它没出现在不该出现的地方"

## 1. 端口是真的可替换,这次可以检验

TASK-HTP-004 立了 `HarnessDecisionGateway` 这个端口,但仓内一直只有离线确定性路径——
"可替换"是设计意图,不是被验证过的性质。本任务补上三家真实 adapter,并把可替换性写成断言:
同一份回复喂给 Claude / OpenAI / Gemini 三家,`reconcile` 的 action 与派发的 operation
**完全相同**。adapter 只搬运字节,不解释。

三条边界:

- **出站的就是 digest 记的那份**:请求体携带 `context.transmittedBytes`,而 ModelRun 的
  `contextDigest` 正是对这份字节取的。否则 digest 记录的是没发生过的事;
- **密钥只在 header**:用哨兵密钥断言它不在 body、不在 URL、不在 `modelDescriptor`。
  Gemini 特意用 `x-goog-api-key` 头而不是 query 参数——URL 里的密钥会进日志;
- **厂商出错不会变成提议**:500 / 401 / 非 JSON / 空 envelope 四种一律
  `transportFailure`,由既有路径退回确定性 handler 并记一条 ModelRun。

## 2. model call 预算:一次调用要在每条出口路径上计费

新增 `maxModelCalls` 与 `HarnessBudgetKind.modelCalls`。真正需要想清楚的是**在哪里计**:

规划过程中提交一次事务会移动 `state version`,而 TASK-HFA-002 的防陈旧闸正是拿这个
version 校验决策——**在规划中途计费会把自己刚拿到的 decision 变成 stale**。所以计费不能
就地提交,而是由 `PlannedProposal.modelCallsSpent` 带出规划,折进本轮**同一次** transition:
dispatch、patch dispatch、交人、noSafeAction、stale,五条出口路径全部计。

`maxModelCalls: 0` 时零请求到达 vendor,reasonCode `maxModelCallsExhausted`,而任务不停——
确定性 handler 仍然收敛。这是**花费的上限,不是停机开关**。

## 3. 一处必须记的连带修正

TASK-HFA-002 的 `testAStaleWakeChargesNoFailureNoProgressAndNoBudget` 原本断言陈旧轮
"预算全零",原因是当时没有 model call 预算可计。本任务落地后,该断言改为
`HarnessConsumedBudget(modelCalls: 1)`。

这不是为了让测试变绿而放宽——**HFA-AC-4 的原文就是**「stale 不计策略失败、不增
no-progress,**但已发生的 model call 仍计入预算**」。002 当时只能实现前半句,现在后半句
才有落点。方向是收紧。

顺带把 `HarnessModelRun.responseBytes` 从占位 `0` 改成实测字节数。

## 4. 命令与结果

```text
swift build                                          Build complete
swift test --filter HarnessVendorGatewayContractTests
                                                     Executed 10 tests, 0 failures
swift test                                           Executed 978 tests, 1 skipped, 0 failures
./scripts/check-sdd.sh                               0 error(s), 0 warning(s), 114 acceptance IDs
```

## 5. 未覆盖(如实登记)

- **没有真实厂商端点调用**。三家的 envelope 形态按各自公开文档实现并用 fixture 钉死;
  首次真实调用需要凭据与出站开启,属部署动作,不在本任务;
- **不记 token usage**。三家 envelope 的 usage 字段形态不同,当前也没有消费者;
  记实测字节数(`contextBytes`/`responseBytes`)而不是半可信的 token —— 与 TASK-HFA-002
  当时的取舍一致;
- **密钥来源**(keychain / 环境 / 配置)由 composition root 决定,本任务只定义
  `HarnessVendorCredential` 的形状。仓内不含任何真实密钥;
- **出站默认 deny 不变**:配置 adapter ≠ 开启出站。开启仍需项目级显式配置
  (`HarnessEgressPolicy`)。

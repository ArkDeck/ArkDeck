# ADR-0008: Device Runtime Agent 执行交接

- Status: accepted(CHG-2026-049,2026-07-29;维护者 review 期加入)
- Deciders: lvye(merge 即批准)
- Context: MU-3 证明了 CLI→daemon→真设备的技术链路,但 `BER-HW-*` 的
  全部 host 命令仍由维护者亲手运行、贴回 transcript。若沿用该模型,每新增
  一个 operation 都会把人当作 Runtime 调用器——与两平面治理"AI 提交已
  发布 operation"的目标相悖,也让"自动化"停留在纸面。

## Decision

1. **Agent 执行 host Runtime 调用**。`AgentRuntimeExecutor` 一次调用完成
   health → target list/adopt → submit → run → artifact query,并产出
   `RuntimeAgentExecutionReceipt`。真机 AC 的执行者是 Agent,不是人。
2. **人是 physicalAssistant,不是 executor**。只有三件事需要人:设备屏幕
   首次信任、多候选歧义选择、验收所需物理拔插。每件都是封闭的
   `RuntimeHumanAction` + 持久化 resume token——**等待人类是可恢复的
   记录状态**,不是放弃的运行。`arkdeck agent resume` 从 token 恢复原
   request、catalog digest、execution ID 与 humanAction 时间线;同一
   execution 的 request/idempotency identity 不变,不得靠重新执行
   `agent run` 制造第二个 job。选择动作直接携带 `--selection` 可接受值,
   不要求人再跑 `target.list`;人不代跑 host CLI。
3. **surface 窄到不能作恶**。runner 只组合 daemon 的 typed 方法;没有
   executable/argv/shell/远端路径字段;**没有 capability 的
   install/create/modify/revoke**——只能按 ID 引用维护者已接受的那张。
   该约束由**行为测试**钉死(记录实际调用的方法名),而非源码文本检查。
4. **单次单 operation**。一次 invocation 最多提交一个已发布 operation,
   health/adopt/submit/run/artifact query 共享同一个 monotonic 总 deadline,
   而不是每次调用重新获得完整 timeout;`job.run` 超时、传输失败或返回
   非终态时,runner 只经额外有界的 typed `job.cancel` 请求安全收敛。结构
   上不可能变成无限 debug loop(那属 T19,另有预算与停止条件)。
5. **receipt 是运行载体**。executor/operation/job/target/binding/catalog
   digest/authority reference/humanAction 时间线/终态全部如实记录并脱敏;
   **人工粘贴的 transcript 不构成 `executor=agent` 的验收**。

## Consequences

- 真机 AC 的判据随之收紧:没有可用的 Device Runtime Agent 时,AC 保持
  blocked,不允许退回"维护者代跑 CLI"冒充自动化验收。
- E0 的 authority reference 固定为 catalog digest + 默认只读策略;E1 只
  引用 capability ID,签发仍是维护者经 merged PR 的 D2 决策(POL-AGENT-002
  不变)。
- 后续 MU 的真机验收都走这条路径,窗口文档从"命令清单"变成"Agent 执行
  计划 + 人类物理协助点"。
- daemon 重启或人类响应较晚不会丢失待恢复请求;catalog digest 漂移、
  token 不存在、选择不属于当前候选集时均 fail closed。
- runtime 终态失败会把 journal timeline 的最后一条明确 reason 返回给
  Agent,不再只报告无信息量的 “job ended in failed”。

## Alternatives considered

- **继续人工窗口**:被否——它让每个新 operation 的成本正比于人的时间,
  且 transcript 无法证明执行者身份。
- **让 runner 自己管 capability**:被否——那等于 Agent 自批,复活
  chg-033 修掉的"human-only approval 不可证明"缺陷。
- **多轮自治 loop**:被否——本 ADR 只解决"谁来调 Runtime";带预算与
  停止条件的决策循环是 T19 的独立议题。

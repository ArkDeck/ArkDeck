# ArkDeck 产品闭环优先总指令(PRODUCT-LOOP)

> Status:current(2026-07-30 由维护者签发;合并进受保护 `main` 即批准生效)
> 定位:本文件是当前阶段所有 AI 开发任务的执行优先级正本,在 `AGENTS.md` 权威顺序中列于
> Constitution 安全不变量之下、其余一切治理流程文档之上。
> 安全边界:本指令不突破设备安全边界、不绕过副作用授权(E1/E2)、不降低错误设备防护能力;
> `AGENTS.md`「Agent 禁令」与 Constitution Safety invariants / POL-* 全部保留,任何条款不得
> 被本指令解释为放宽。

## 0. 指令优先级

本指令用于约束 ArkDeck 后续所有 AI 开发任务。

在不突破设备安全边界、不绕过副作用授权、不降低错误设备防护能力的前提下,本指令优先于:

- 普通任务拆分;
- OpenSpec 扩展;
- readiness 流程;
- acceptance 补充;
- evidence 完善;
- verification 状态维护;
- archive 整理;
- 治理框架优化。

ArkDeck 当前已经进入:

> **产品闭环优先阶段**

首要目标不是继续完善治理系统,而是让以下真实设备闭环尽快稳定运行:

```text
真实 OpenHarmony 设备
    ↓
设备发现与接管
    ↓
Typed Operation 提交
    ↓
精确目标设备上的 HDC 执行
    ↓
Artifact 收集
    ↓
自动分析
    ↓
生成下一次 Typed Request
    ↓
有界 Debug Loop
```

任何不能直接提升以上闭环能力、降低人工介入或提高真实设备执行可靠性的工作,默认降低优先级。

---

## 1. 核心成功标准

ArkDeck 是否成功,不看:

- OpenSpec 数量;
- Task 数量;
- Acceptance 数量;
- Evidence 数量;
- 测试文件数量;
- 治理规则覆盖率;
- 已归档 Change 数量。

只看:

```text
一个工程师拿到一台 OpenHarmony 设备
    ↓
完成首次 USB 连接、设备信任和必要系统授权
    ↓
执行一个 ArkDeck Debug Operation
    ↓
AI 自动完成:

1. 检查设备状态;
2. 确认精确目标设备;
3. 安装或替换 HAP;
4. 启动应用;
5. 抓取 bounded HiLog;
6. 抓取 UI Dump;
7. 抓取 Trace;
8. 收集其他已声明 Artifact;
9. 分析异常;
10. 推送受控且可回滚的修复;
11. 重启或重新运行;
12. 再次采集和验证;
13. 在达到成功、预算上限或安全停止条件后结束。
```

如果上述流程还不能完成:

> 继续优化 Runtime 和真实 Provider,不要优化治理系统。

---

## 2. 禁止重新进入治理建设循环

除非发现真正影响安全边界的缺陷(见 §3),否则禁止创建新的:

- OpenSpec Change;
- Proposal;
- Readiness Task;
- Readiness-only PR;
- Status-only PR;
- Done-only PR;
- Verified-only PR;
- Archive-only PR;
- Evidence Schema;
- Acceptance Framework;
- Verification Framework;
- Governance Migration;
- Scope Remediation;
- Handoff Reference Change;
- Acceptance Count Change;
- 纯历史状态修订任务。

以下情况不得作为停止产品开发的理由:

- 缺少新的 Acceptance ID;
- 缺少新的 Evidence 类型;
- 当前 Task 描述无法完全覆盖实现;
- 旧 Change 的状态没有更新;
- 旧任务仍显示 blocked;
- 文档不能完整表达真实运行结果;
- 需要重新整理 Scope;
- 需要先归档历史 Change;
- 需要先补一个 Governance Proposal;
- 需要增加新的状态字段;
- 需要重新计算 Acceptance Count。

正确处理方式:

```text
代码目标明确
    ↓
直接修改产品代码和测试
    ↓
执行真实运行验证
    ↓
在同一交付中更新必要的最小文档
```

旧文档与新执行路线存在冲突时:

1. 记录一条简短兼容说明;
2. 以当前产品闭环任务为准;
3. 不停止代码执行;
4. 不创建新的治理 Change;
5. 不重新规划整套任务。

> 已实证的反模式(2026-07-29,DHA-HW-001 attempt#2):真实设备上 Agent E0 运行成功,
> 却因「权威硬件证据 schema 无法编码该结果」而维持 BLOCKED。本指令生效后,真实运行结果
> 本身即为一等证据;schema 表达力不足只允许产生一行兼容说明,不允许阻塞状态推进。

---

## 3. 治理工作允许触发的唯一条件

只有以下问题允许优先处理治理或安全规则:

1. 可能对刷错设备;
2. 可能向错误设备部署文件;
3. 可能绕过 E1/E2 授权;
4. 可能重复执行未知结果的副作用;
5. 可能导致系统分区或用户数据不可逆损坏;
6. 可能破坏 durable intent、journal 或 recovery 语义;
7. 可能把未实现的 Operation 对外标记为可用;
8. 可能让 AI 直接执行未经声明的 raw shell、HDC 或刷机命令;
9. 可能泄漏敏感 Artifact;
10. 可能在身份不明确时执行 mutation。

即使满足以上条件,也应优先:

```text
修复 Runtime 安全代码
    ↓
增加对应测试
    ↓
进行真实验证
```

而不是优先扩展治理框架。

---

## 4. 一个问题只能产生一个垂直产品任务

禁止把一个问题拆成:

```text
Analysis Change
    ↓
Proposal Change
    ↓
Readiness Change
    ↓
Implementation Change
    ↓
Evidence Change
    ↓
Verification Change
    ↓
Archive Change
```

正确方式:

```text
一个问题
    ↓
一个垂直修复任务
    ↓
一个产品 PR
```

该任务必须同时包含:

- 根因说明;
- 产品代码修复;
- 必要测试;
- 真实设备验证,适用时;
- 最小必要文档更新;
- 明确的完成结论。

示例:

```text
问题:
HDC 命令没有绑定 connectKey,可能操作默认设备。

同一任务内完成:
- 所有 device-scoped HDC argv 增加 `-t <connectKey>`;
- 增加多设备测试;
- 在真实设备上验证;
- 更新一处相关文档;
- 合入后关闭问题。
```

不得再为同一问题创建额外的 readiness、verification 或 archive PR。

---

## 5. 禁止重复任务定义

创建任何新任务前,必须搜索:

- 当前产品 Backlog;
- 已打开 PR;
- 最近合入提交;
- 当前 Operation Catalog(`Catalog/operations/`);
- Runtime Provider(`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/`);
- 旧 OpenSpec Task;
- 已存在测试;
- 相关脚本。

发现已有任务或实现覆盖当前问题时:

1. 继续现有任务;
2. 补充遗漏验收项;
3. 修复现有实现;
4. 不创建语义重复任务。

判断是否重复时,以产品结果为准,而不是以任务名称为准。

例如以下任务属于同一能力,不得重复创建:

```text
E0 Capture Executor
Diagnostics Runtime
HiLog Operation
Diagnostic Artifact Collection
Device Observation Evidence
```

它们都可能属于同一个:

```text
capture.diagnostics@1
```

---

## 6. Golden Journey 是唯一进度指标

所有开发进度必须映射到以下 Golden Journey。

### GJ-1:Device Observe

目标:

```text
arkdeck doctor
    ↓
HDC 注册或发现
    ↓
设备候选发现
    ↓
首次信任提示
    ↓
设备接管和 durable binding
    ↓
observe.device@1
    ↓
bounded HiLog
    ↓
UI Dump
    ↓
Artifact 入库
    ↓
Daemon 重启后仍可查询结果
```

状态只能是:

- `NOT_STARTED`
- `IMPLEMENTING`
- `BLOCKED_BY_PRODUCT_DEFECT`
- `REAL_DEVICE_PASS`

禁止使用文档完成、Schema 完成或 Fake Test 通过代替 `REAL_DEVICE_PASS`。
`REAL_DEVICE_PASS` 必须在**当前 catalog digest** 上取得;旧 digest 的真机记录只证明历史。

### GJ-2:HAP Debug

目标:

```text
HAP Artifact Lease
    ↓
解析真实本地文件
    ↓
发送到稳定的 job-owned 远端路径
    ↓
远端文件 readback
    ↓
install -r
    ↓
package readback
    ↓
启动 Ability
    ↓
PID 或应用状态 readback
    ↓
抓取 HiLog
    ↓
抓取 UI Dump
    ↓
抓取 Trace
    ↓
停止应用
    ↓
清理 staging
    ↓
生成完整结果
```

状态同 GJ-1 四态。

### GJ-3:Native Debug

目标:

```text
验证 .so Artifact
    ↓
校验 ELF、ABI、Build ID 和 Hash
    ↓
发送到受控 staging
    ↓
校验远端 Hash
    ↓
原子发布
    ↓
重启目标进程或应用
    ↓
验证 loader 状态
    ↓
采集 Crash、HiLog、Dump 或 Trace
    ↓
失败时自动 rollback
    ↓
再次验证
```

状态同 GJ-1 四态。

### GJ-4:Flash Recovery

目标:

```text
设备身份确认
    ↓
E2 精确计划授权
    ↓
执行刷机
    ↓
处理设备模式转换和重连
    ↓
启动完成
    ↓
重新发现并接管设备
    ↓
验证系统版本和设备状态
    ↓
恢复正常 Debug Runtime
```

状态同 GJ-1 四态。

### GJ-5:Bounded AI Debug Loop

目标:

```text
运行应用
    ↓
采集 Artifact
    ↓
分析问题
    ↓
生成下一次 Typed Request
    ↓
重新经过 Runtime Admission
    ↓
部署修复
    ↓
复验
    ↓
达到成功或安全停止条件
```

必须包含以下预算:

```text
maxRounds
maxWallClock
maxArtifactBytes
maxE1Mutations
allowedOperations
stopOnRepeatedFailure
stopOnOutcomeUnknown
stopOnHumanActionRequired
stopOnAuthorizationRequired
```

状态同 GJ-1 四态。

---

## 7. 当前优先级必须固定

始终按照以下顺序处理:

### P0:真实设备执行正确性

包括:

- 精确设备选择;
- `-t <connectKey>`;
- durable target 和 binding;
- Provider availability;
- plan materialization;
- 错设备防护;
- outcomeUnknown;
- intent-before-effect。

### P1:Artifact 和恢复可靠性

包括:

- stable job-owned remote path;
- send、capture、receive、cleanup 路径一致;
- Artifact lease;
- size、hash、readback;
- daemon 重启恢复;
- cleanup debt;
- reconcile 原始 intent。

### P2:Operation 产品能力

包括:

- observe;
- HiLog;
- UI Dump;
- Trace;
- HAP lifecycle;
- `.so`;
- Flash。

### P3:AI 自动分析和下一轮请求

包括:

- Artifact 分析;
- typed next request;
- bounded debug loop;
- 成功判定;
- 重复失败停止。

### P4:CLI 和 App 体验

包括:

- doctor;
- adopt;
- submit;
- status;
- result;
- cancel;
- reconcile;
- HumanActionRequired。

### 最低优先级:治理完善

除非直接解决安全缺陷,否则不处理。

---

## 8. Availability First

Catalog 中存在一个 Operation,不代表生产环境可执行。

每个 Operation 必须明确返回:

```text
AVAILABLE
```

或:

```text
UNAVAILABLE
```

并给出机器可读原因。

禁止:

```text
Catalog 中声明支持
    ↓
operation.list 返回可用
    ↓
submit 成功
    ↓
消耗 Capability
    ↓
运行阶段才发现 Provider 未注册或 Step 不支持
```

正确顺序:

```text
查找 Operation Descriptor
    ↓
校验 Provider 是否注册
    ↓
解析真实 Target Facts
    ↓
完整 materialize Typed Plan
    ↓
确认每个 Step 均有生产 lowering
    ↓
计算 Plan Digest
    ↓
检查 Capability
    ↓
持久化 Job
    ↓
执行
```

Capability 不得在 Provider 或 Plan 不可用时被消耗。

`operation.list` 至少应返回:

```json
{
  "reference": "flash.dayu200@1",
  "status": "unavailable",
  "reasonCode": "provider_not_registered",
  "reason": "Rockchip provider is not registered in the production runtime"
}
```

---

## 9. 所有设备命令必须精确绑定目标

除 host/server 级命令外,所有 device-scoped HDC Action 必须显式包含:

```text
-t <connectKey>
```

禁止依赖默认设备。

适用范围包括但不限于:

- shell;
- hilog;
- hidumper;
- hitrace;
- file send;
- file recv;
- install;
- uninstall;
- aa start;
- aa force-stop;
- pidof;
- fport;
- remote cleanup;
- property query;
- package readback;
- remote hash readback。

必须由统一函数生成参数,例如:

```swift
func deviceArguments(
    connectKey: String,
    command: [String]
) -> [String] {
    ["-t", connectKey] + command
}
```

AI 不得在不同 Feature 中自行拼接目标参数。

---

## 10. AI、CLI 和 App 禁止执行 Raw Command

AI、CLI 和 App 只能提交:

- Operation Reference;
- Typed Inputs;
- Target Reference;
- Artifact Lease;
- Capability Reference;
- 预算和输出要求。

禁止提交或执行:

- raw executable path;
- raw argv;
- raw HDC command;
- raw shell;
- 任意远端路径;
- 未登记的系统命令;
- 未声明的文件部署位置。

命令 lowering 必须只由受版本控制的 Provider 完成。

---

## 11. 优先修真实运行路径

优先级:

```text
真实设备失败
    >
真实 Provider 集成测试失败
    >
Descriptor-bound Process 测试失败
    >
Fake Provider 测试失败
    >
Schema 测试失败
    >
文档表达不完整
```

发现真实设备问题时,禁止通过以下方式逃避:

- 新增 Fixture 证明理论正确;
- 修改 Evidence Schema;
- 把真实测试推迟到最终阶段;
- 将状态标记为 blocked 后转去做治理;
- 仅增加 Mock 测试;
- 重新规划任务。

正确做法:

1. 保存真实失败信息;
2. 确认目标设备和输入;
3. 定位生产执行路径;
4. 修复代码;
5. 重跑真实设备;
6. 将结果记录到同一产品任务。

Fake 测试面必须断言**真实 argv 形态**(含 `-t <connectKey>` 与完整子命令),
不得只在 typed action 层面断言;两次实证教训:typed 层全绿时,生产 argv 仍缺
`-t`、`hidumper` 服务名错误、`file send` 源参数为字面量占位符。

---

## 12. 禁止扩大设计范围

当前阶段禁止主动开展:

- 大规模模块重构;
- 新治理 DSL;
- 新 Workflow Abstraction;
- 新 Evidence Framework;
- 新 Approval Model;
- 新 Compliance Layer;
- 新状态机,仅为表达文档状态;
- 新通用框架,尚无两个真实使用方;
- 与当前 Golden Journey 无关的跨平台抽象;
- 为未来 Windows/Linux 实现提前重构 macOS MVP。

仅在以下情况允许结构性改动:

1. 当前模块边界导致无法完成真实闭环;
2. 存在错误设备执行风险;
3. 存在未知副作用重复执行风险;
4. 存在不可恢复的数据损坏风险;
5. 当前抽象导致不同执行路径绕过统一安全内核。

结构性改动必须和一个 Golden Journey 同车交付,不得独立成为架构治理项目。

---

## 13. Runtime 与 Repo 治理必须彻底分离

Repo Plane 只负责:

- 代码变更;
- Operation Bundle 发布;
- Provider 实现审查;
- 新硬件 Profile 登记;
- 高风险能力的发布审批;
- PR Review。

Runtime Plane 负责:

- Job submit;
- status;
- result;
- cancel;
- reconcile;
- target adoption;
- device lease;
- Artifact;
- Capability 消耗;
- HumanActionRequired。

日常 Runtime Request 禁止要求:

- `changeId`
- `taskId`
- `approvalPR`
- `mainCommitOID`
- `taskBlobOID`
- readiness 状态
- GitHub Issue
- OpenSpec Change

发布一个 Operation 可能需要 Repo Review。

运行一个已经发布的 Operation,不得再次进入 Git 治理流程。

---

## 14. 人工介入预算

首次接入设备时允许:

- 插入 USB;
- 设备侧首次信任;
- 系统权限授权;
- 多设备歧义选择;
- E1/E2 Capability 批准;
- outcomeUnknown 人工决策。

完成首次接管后,普通 E0 Debug 的人工操作预算必须为:

```text
0
```

普通 E1 Debug 在 Capability 有效时,人工操作预算必须为:

```text
0
```

以下行为均视为产品失败:

- 每次 Debug 创建 Task;
- 每次 Debug 创建 Change;
- 等待 PR Review 后才能抓日志;
- 人工执行 HDC;
- 人工复制 Artifact;
- 人工拼接远端路径;
- 人工判断安装是否成功;
- 人工停止应用;
- 人工清理 staging;
- 每轮 AI 分析后重新申请同范围授权;
- Daemon 重启后重新开始整个任务。

---

## 15. Durable Recovery 必须针对原始 Intent

禁止构造一个新的通用 Observe Action 来代替原始副作用的 reconcile。

必须持久化:

- 精确 Operation ID 和 Version;
- 精确 Step ID;
- Typed Provider Action;
- Stable Target Identity;
- Connect Key Snapshot;
- Binding Revision;
- Artifact ID、Hash 和 Lease;
- Provider-owned Remote Path;
- Materialized Plan Digest;
- Capability Reservation 和 Consumption 状态;
- Semantic Verification Recipe;
- Compensation;
- Cleanup Obligation。

恢复时必须:

```text
读取原始 Durable Intent
    ↓
执行该 Action 对应的专用 Readback
    ↓
判断:

COMPLETED
NOT_EXECUTED
STILL_UNKNOWN
PARTIALLY_COMPLETED
CLEANUP_REQUIRED
```

规则:

- `COMPLETED`:继续后续 Step;
- `NOT_EXECUTED`:重新经过安全 Admission 后才允许执行;
- `STILL_UNKNOWN`:停止并请求人工决策;
- `PARTIALLY_COMPLETED`:执行已声明补偿或专用恢复;
- `CLEANUP_REQUIRED`:生成并消费 cleanup debt。

`outcomeUnknown` 永远不得自动重发原始副作用。

---

## 16. 旧任务处理规则

旧 OpenSpec Task 与当前 Golden Journey 重复时:

- 不重新执行旧 Task;
- 不刷新 readiness;
- 不创建 scope remediation;
- 不为旧状态补 verification;
- 不因为旧 Task 显示 blocked 而停止当前实现。

应将其视为:

```text
历史设计记录
```

而不是:

```text
当前 Runtime 执行队列
```

只保留真正未完成的产品能力,例如:

- Durable Recovery;
- Trace 真实收取与校验;
- app-owned `.so`;
- Rockchip Runtime Provider;
- Bounded AI Debug Loop。

CI 机械说明:`scripts/check_pr_paths.py` 的任务声明只是**路径护栏**,不是治理仪式。
产品 PR 声明一个 base 上已存在、allowed paths 覆盖其改动的 active 任务
(如 `TASK-BER-002`、`TASK-DHA-001` 覆盖 `Packages/ArkDeckKit/**`)即可;
该声明不触发被声明任务的 readiness/verification/archive 连锁义务。

---

## 17. 每次准备创建新任务时的强制自检

创建任务前必须回答:

### 问题一

这个任务是否会减少 AI 操作 OpenHarmony 设备时的人工步骤?

- 是:继续评估;
- 否:默认不创建。

### 问题二

这个任务是否直接提高以下流程的可靠性?

```text
submit
    ↓
execute
    ↓
collect artifact
    ↓
analyze
    ↓
repair
    ↓
verify
```

- 是:可以创建产品任务;
- 否:降低优先级。

### 问题三

这个问题能否在现有产品任务或 PR 中修复?

- 能:加入现有任务;
- 不能:才允许创建新任务。

### 问题四

这个任务是否只是为了让文档、状态或 Evidence 更完整?

- 是:不创建;
- 否:继续。

### 问题五

这个任务完成后,至少一个 Golden Journey 的状态是否会前进?

- 会:允许执行;
- 不会:默认不执行。

---

## 18. 检测到治理循环时的强制退出机制

出现以下任意信号,视为已经进入治理循环:

- 连续两个任务没有修改生产 Runtime;
- 连续两个 PR 只有文档、Evidence 或状态修改;
- 为一个产品 Bug 创建两个以上治理任务;
- 因 Acceptance Schema 不足而停止真实设备修复;
- 重新扫描旧 Task 后开始重复规划;
- 准备创建 readiness-only 或 archive-only PR;
- Fake 测试大量增加,但 Golden Journey 状态没有变化;
- 新增了治理类型,但没有减少任何人工步骤;
- 最近五个提交中,产品代码提交少于两个;
- 同一能力在 Catalog、OpenSpec 和 Backlog 中出现多个活跃任务。

触发后必须立即执行:

```text
1. 停止创建新治理任务;
2. 列出当前唯一阻塞 Golden Journey 的产品缺陷;
3. 选择最高优先级产品缺陷;
4. 直接修改生产代码;
5. 增加最小必要测试;
6. 执行真实设备验证;
7. 不再重新规划整套项目。
```

---

## 19. 每轮执行后的强制汇报格式

每轮完成后只能使用以下格式汇报。

### 本轮产品结果

- 修复的问题:
- 修改的生产执行路径:
- 减少的人工步骤:
- 新增或改进的真实设备能力:
- 是否执行真实设备验证:
- 验证设备:
- 验证结果:

### Golden Journey 进度

| Golden Journey | 执行前 | 执行后 | 当前唯一阻塞 |
|---|---|---|---|
| GJ-1 Device Observe |  |  |  |
| GJ-2 HAP Debug |  |  |  |
| GJ-3 Native Debug |  |  |  |
| GJ-4 Flash Recovery |  |  |  |
| GJ-5 Bounded AI Debug Loop |  |  |  |

### 治理循环检查

本轮是否新增:

- OpenSpec Change:否/是
- Proposal:否/是
- Readiness-only Task:否/是
- Acceptance Framework:否/是
- Evidence Schema:否/是
- Verification-only Task:否/是
- Archive-only Task:否/是

如果任意一项为「是」,必须说明:

1. 对应的真实安全风险是什么;
2. 为什么不能直接通过 Runtime 代码修复;
3. 它推进了哪个 Golden Journey;
4. 为什么不会产生后续 readiness、verification、archive 连锁任务。

无法回答以上四项时,撤销该治理工作。

### 重复任务检查

- 是否搜索了已有 Task、PR 和实现:
- 是否发现语义重复:
- 已合并或替代的旧任务:
- 本轮新建产品任务数量:

### 下一步

只允许给出:

```text
当前阻塞最高优先级 Golden Journey 的一个产品缺陷
```

禁止重新输出完整项目规划。

---

## 20. 当前阶段冻结项

在 GJ-1 和 GJ-2 达到 `REAL_DEVICE_PASS` 之前,冻结:

- 新的治理框架;
- 新 Evidence Schema;
- 新 Acceptance 体系;
- 新 Workflow DSL;
- 大规模 App UI;
- 大规模 Package 重构;
- system `.so`;
- Rockchip 扩展;
- 新平台支持;
- 无真实使用方的通用抽象;
- 历史 Change 的批量归档整理。

允许处理的工作仅包括:

1. 精确设备执行;
2. Operation Availability;
3. Provider 完整 lowering;
4. Artifact 收集;
5. HAP Debug;
6. Durable Recovery;
7. 当前真实设备失败;
8. 直接阻塞 GJ-1/GJ-2 的产品缺陷。

---

## 21. 最终执行原则

始终遵守:

```text
产品闭环 > 治理完整
真实设备 > Fake Fixture
生产执行路径 > Schema
减少人工步骤 > 增加规则
修复现有任务 > 创建新任务
一个垂直 PR > 多个状态 PR
真实 Artifact > Evidence 描述
Runtime 安全代码 > 治理文档
Golden Journey 前进 > Task 数量增长
```

安全内核必须保留,但治理系统不得进入日常设备操作和产品开发的关键路径。

当前唯一方向是:

```text
真实设备
    ↓
精确目标
    ↓
真实命令
    ↓
真实 Artifact
    ↓
可靠恢复
    ↓
自动分析
    ↓
自动复验
    ↓
最少人工介入
```

---

## 22. 兼容与落地说明

- 本指令经 `AGENTS.md` 权威顺序获得约束力:Constitution 安全不变量 > 本指令 > `AGENTS.md`
  其余条款 > specs/contracts > 流程文档(enforcement/policy 等,适用范围收窄至安全内核治理)。
- `openspec/changes/README.md`「任何工作都从 change package 开始」、
  `openspec/delivery/roadmap.md`「Work begins only from approved change with ready Task packets」、
  `openspec/README.md` 旧「Agent 执行入口」步骤 2,自本指令生效起对产品闭环工作不再适用;
  各文件留有兼容注记。
- 恰四类 Repo 审批不变:新 operation 或对已发布 operation 的破坏性修改、新 provider、
  新 integration/device profile、E2 安全策略变化——仍走 OpenSpec change + 维护者 PR review,
  且必须与对应 Golden Journey 交付同车,不得独立成为治理项目。
- 与旧治理文档的其余冲突,按 §2 的兼容说明规则处理:一行注记,继续工作。

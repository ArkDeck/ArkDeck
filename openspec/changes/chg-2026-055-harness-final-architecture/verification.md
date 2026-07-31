# Verification — CHG-2026-055

> Change:CHG-2026-055-harness-final-architecture@r1

Status:pending # r1(2026-07-31):十三个任务尚未开工,HFA-AC-1..23 全部 `pending`。
每条结论由其所属任务的实现 PR 写入本文件;维护者 review/merge 该实现 PR 即确认。
不为本 change 追加独立 verification/archive 载体(`PRODUCT-LOOP.md` §4/§20)。

约定:

- 结论只能取 `PASS` / `FAIL` / `pending`(未开工)/ `pending-hardware`(缺设备窗口,
  如实分类,不得以 fake/simulation 顶替);
- 每条结论必须给出可复查的落点(测试名、命令、退出码、artifact hash、脱敏设备标识);
- **HFA-AC-11/HFA-AC-12 是 GJ-5 唯一可写 `REAL_DEVICE_PASS` 的依据**,且必须在当前
  catalog digest 上取得;
- 判定面的每条 AC 都必须包含至少一条"证据缺席/不可解析时不判成功"的负例落点。

## HFA-AC-1 崩溃判定以崩溃台账为源(TASK-HFA-001)

- 方法:用真实 fault log 字节样本(CHG-2026-049 TASK-DHA-005 窗口产出)驱动
  observation builder,断言 crash signature、reason、进程/包名被正确提取,
  并与 goal 的 `crashSignature` 匹配计数;同一样本下 `matchingCrashCount > 0` 时
  mandatory criterion 不得 PASS。
- Evidence:实现 PR 内测试 + 全量套件结果 + 使用的样本 hash。
- **结论:pending**

## HFA-AC-2 证据缺席不得判成功(TASK-HFA-001)

- 方法:三条独立负例——①声明的崩溃证据产物缺席/`missing`/`truncated` → `INCONCLUSIVE`;
  ②台账为空且工具正常返回 → 可作为"无匹配崩溃"正证据(与"没采到"可区分);
  ③条目不可解析 → `ERROR` + `evidenceIntegrity` 人工阻塞。并保留 r6 真实场景回归
  (真实 crash 之后不得出现 verdict `pass`)。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-3 Stale decision 不执行(TASK-HFA-002)

- 方法:逐前置各一条竞态用例——state version 递增后、contextDigest 变化后、
  人工 resolution 之后、binding revision 变化后,旧 decision 一律被拒且零副作用;
  同一事务内校验(并发 accept 只有一条成功)。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-4 Stale 的代价语义与失败区分(TASK-HFA-002)

- 方法:断言 stale 不计策略失败、不增 no-progress 轮次、不写 failure fingerprint,
  但已发生的 model call 计入预算;stale 之后重新组装 context 产生**不同** digest。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-5 Context digest 可复算且 ModelRun 完整(TASK-HFA-002)

- 方法:同一 task state version + 同一持久化事实 → 同一 `contextDigest`(重复组装断言);
  digest 在脱敏之后计算(含未脱敏字节的输入不会产生相同 digest);ModelRun 记录字段齐全
  (provider/model/adapterVersion/observedStateVersion/contextDigest/tokens/schema 校验/decisionId)。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-6 `PROPOSE_PATCH` 越界整条拒绝(TASK-HFA-003)

- 方法:负例集——超 `maxPatchBytes`、超文件数、写入 ProjectProfile 未声明的 glob、
  二进制 patch、符号链接、`..` 路径逃逸、`.git` 内部修改、base revision 失配,
  各自断言整条 decision 被拒且零 ActionRun、零 apply。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-7 三条 stage gate 是结构性相等判定(TASK-HFA-003)

- 方法:分别构造 ①applied-patch readback revision ≠ Attempt.patchRevision、
  ②build source revision ≠ 当前 patch revision、③部署 readback digest ≠ build output digest,
  断言各自不得进入下一 stage;相等时才推进。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-8 未知结果不重复 apply、失败必回滚(TASK-HFA-003)

- 方法:apply 结果未知时只走 readback 四态判定(`PATCH_APPLIED`/`PATCH_NOT_APPLIED`/
  `STILL_UNKNOWN`/`PARTIALLY_APPLIED`),断言零第二次 apply;部署或复验失败触发
  `workspace.revertPatch@1` 且回滚消耗 E1 预算;回滚结果未知 → 人工阻塞,不重复回滚。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-9 重复策略不得伪装成新 Attempt(TASK-HFA-004)

- 方法:同 patch digest + 同 base revision + 同 build preset + 同 failure fingerprint,
  仅改写 hypothesis 文本,断言 `DUPLICATE_STRATEGY` 拒绝、不新建 Attempt、不派发 job;
  七要素任一变化则允许新 Attempt(正例)。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-10 Action Retry 与 Strategy Attempt 分离、无进展可停止(TASK-HFA-004)

- 方法:瞬态失败 → 同 Attempt 新 ActionRun(崩溃重放用原 idempotencyKey、确认重试用新 key);
  只重新分析/总结/规划、相同 decision fingerprint、workspace 回到同一 revision 一律不计进展;
  连续 `maxNoProgressRounds` 后关闭当前 Attempt 并要求新 strategy fingerprint,
  无安全替代 → 人工阻塞或 FAILED。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-11 真机:一次 submit 完成含修复腿的收敛,人工步骤 0(TASK-HFA-005)

- 方法:已接管 DAYU200 + 当前 catalog digest,一次 `task submit` 跑通
  运行 → 采集 → 判定 → patch → build → 部署 → 复验;记录人工步骤计数、每轮
  decision/attempt/job/artifact 链、预算消耗与停止原因。
- Evidence:设备窗口 run 记录(命令、退出码、artifact hash、脱敏设备标识、capability ID)。
- **结论:pending**

## HFA-AC-12 真机:注入真实崩溃后不得判 PASS(TASK-HFA-005)

- 方法:在真机上注入可复现的目标崩溃,断言 verdict 不是 `pass`(关闭 r6 假阳性);
  修复后复验 `PASS`。两条证据缺一不可,缺则 GJ-5 不得写 `REAL_DEVICE_PASS`。
- Evidence:同上窗口记录 + 两轮 verdict 的 evaluation ID。
- **结论:pending**

## HFA-AC-13 设备瞬断不回退业务进度(TASK-HFA-006)

- 方法:stage = VERIFYING 时令 `DeviceReady` 变 FALSE,断言 lifecycle → `waiting`、
  **stage 不变**;设备恢复且 binding 仍合法 → 回到 running、stage 仍不变;
  binding revision 变化未确认 → `DeviceBound=UNKNOWN` 且旧 decision 全部 stale;
  stage gate 表逐格负例。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-14 既有任务前向迁移逐字保持(TASK-HFA-006)

- 方法:以 CHG-2026-054 真机窗口留下的持久化任务目录为输入跑迁移,断言迁移后
  `task.status`/`task.events`/`task.result` 逐字保持,`paused` → `waiting +
  USER_SUSPENDED`、历史 `deviceReady` phase → `stage=REPRODUCING + DeviceReady=UNKNOWN`。
- Evidence:实现 PR 内测试 + 使用的历史任务目录标识。
- **结论:pending**

## HFA-AC-15 Analyzer 确定性、版本化且 provenance 完整(TASK-HFA-007)

- 方法:同一输入 artifact 重复运行产出**逐字节相同**的 derived artifact;derived artifact
  带 sourceArtifactIds/hashes、analyzerRef@version、revision 作用域、redaction 状态、
  content hash;分析结论不改变 task 状态(负例)。
- Evidence:实现 PR 内测试 + catalog digest 更新 + 生成器零 drift。
- **结论:pending**

## HFA-AC-16 外部工具不得走 engine-internal 例外(TASK-HFA-007)

- 方法:负例——声明为 analyzer engine-internal 例外的 step 若 spawn 子进程或访问声明外
  路径/网络,一律拒绝;外部 symbolizer/parser 必须经 `arkdeck-analyzer` provider 与
  `DescriptorBoundProcessDispatcher`;provider/工具未配置 → `UNAVAILABLE` 带机器可读原因
  且零 capability 消耗。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-17 workspace 只读族 typed-only 且 argv 逐 token 正确(TASK-HFA-008)

- 方法:八个 operation 各有 argv 逐 token 断言(沿用 `DeviceProviderArgvContractTests` 范式)
  与 typed inputs 边界用例;`runShell`/`executeCommand`/`runArbitraryScript`/`runGit`/
  `writeFile` 在契约面不可表达(负例);scope 逃逸与 byte budget 超限 fail closed;
  `createCheckpoint@1` 有 readback 与 revert 配对。
- Evidence:实现 PR 内测试 + catalog digest 更新 + 生成器零 drift。
- **结论:pending**

## HFA-AC-18 workspace 主体绑定 exact base revision(TASK-HFA-009)

- 方法:workspace revision 失配时 `applyPatch`/`build`/`revertPatch` 一律
  `WORKSPACE_REVISION_CONFLICT` fail closed;dirty worktree 能被 revision digest 识别
  (同一 HEAD、不同工作区内容 → 不同 revision);capability 绑定 workspace identity +
  expectedWorkspaceRevision + allowedFileScopesDigest。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-19 device 主体准入逐条不变、capability 只收窄(TASK-HFA-009)

- 方法:`binding: confirmedDevice` 的既有准入回归断言逐条不变;E2 exact-plan 语义不变;
  负例——workspace 主体的 capability 不能授予 runtime 不具备的能力、不能自签、不能续期、
  不能扩范围;复用同一 reservation/consumption/outcome 账本(不出现第二套账本)。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-20 Memory 晋升条件与作用域过滤(TASK-HFA-010)

- 方法:`VERIFIED` 只能由 evaluator PASS 或人工确认产生且带证据引用(负例:自述结论无法晋升);
  超出 revision/device/toolchain 作用域的 memory 不得进入 `confirmedFacts.current`;
  未验证 memory 的检索得分低于当前 task evidence;`SUPERSEDED`/`INVALIDATED` 不再被选入。
- Evidence:实现 PR 内测试。
- **结论:pending**

## HFA-AC-21 厂商 adapter 可替换且出站受限(TASK-HFA-011)

- 方法:三个 adapter 与离线确定性路径在同一持久化事实下产生**相同的状态机结论**;
  解析负例集(未知字段/未知 kind/raw argv/shell/远端路径/状态字段/retry 计数/成功结论)
  整条拒绝;出站内容断言不含设备标识、未脱敏字节与凭据;`maxModelCalls` 耗尽后安全停止;
  模型不可用时闭环退化为确定性路径而非停摆。
- Evidence:实现 PR 内测试(不含真实网络调用的密钥)。
- **结论:pending**

## HFA-AC-22 SQLite 迁移可逐字回读且崩溃可重入(TASK-HFA-012)

- 方法:以真实历史 task 目录迁移,断言 `task.events`/`task.result` 逐字保持;
  迁移中断后重入不产生重复或丢失;WAL + 外键 ON + 同事务 snapshot/event + 乐观锁
  各有用例;失败时停在旧存储且不损坏。
- Evidence:实现 PR 内测试 + 迁移前后逐字对照。
- **结论:pending**

## HFA-AC-23 module 抽取是纯移动且依赖方向单向(TASK-HFA-013)

- 方法:抽取前后测试数与结论不变(逐项对照);依赖断言测试证明 `ArkDeckHarness`
  不 import OpenHarmony 设备参数、不持远端路径、不构造 Git/HDC/build argv;
  仍是单 `arkdeck-agentd` executable。
- Evidence:实现 PR 内测试 + 前后套件计数对照。
- **结论:pending**

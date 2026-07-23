# CHG-2026-029 Design：Agent 失败模式检索与任务期预防

> Status:candidate（随 proposal r5；本 revision 经维护者 review/merge 前不构成实现授权）
> Core baseline:CORE-2.1.0（零 Core/product behavior 变更）
> r2 变更范围：§3 taxonomy 由九项扩为十八项（新增 §3.1 对 r1 九项的修正、
> §3.2 新增九项的记录），§5 drill 增加执行/验证轴的可选覆盖说明。
> §1 authority boundary、§2 record contract、§4 template integration、§6 verification
> strategy、§7 task/PR boundaries 逐字不变。
> r5 新增 §3.3 并同步 §7：只登记 AF-014 一手事实修正、addendum 契约与 AFP-006
> PR 边界，不改变 taxonomy。

## 1. Authority boundary

`agent-failure-patterns.md` 是**非权威导航索引**，不属于 Constitution、spec、contract、
integration/platform profile、enforcement 或 execution policy。它可以：

- 引用 canonical rule 与历史 evidence；
- 概括重复失败的触发信号和预防动作；
- 指出某项防线已由哪个 guard/CI 覆盖，或仍需语义 review；
- 帮助新 task 选择需要显式回答的问题。

它不得：

- 新增、改写或放宽 Requirement/AC/Safety/approval 语义；
- 把某个历史实现细节提升为跨平台产品规则；
- 把未批准建议描述为 required gate；
- 将 evidence 链接本身解释成 task done/change verified；
- 复制 raw evidence、秘密、真实设备标识或大段日志。

手册首屏固定给出权威顺序与冲突处置：发生冲突时忽略手册建议，按 `AGENTS.md`
权威顺序处理；无法裁决时任务 blocked，而不是由手册选择方便解释。

## 2. Pattern record contract

首批每个 `AF-NNN` 使用相同 Markdown 结构：

1. **Signal**：开工/readiness/review 时可观察的触发信号；
2. **Observed cases**：仓库相对路径、PR/完整 Git OID；事实与推断分开；
3. **Root cause**：解释为何现有检查未在更早阶段发现；
4. **Preflight**：实现前必须显式回答的问题；
5. **Verification**：至少一个正向、一个反向/故障向方法；
6. **Canonical references**：仅链接，不复制或重写 normative 语义；
7. **Automation status**：`mechanized` / `partiallyMechanized` / `semanticReview`，
   写明真实边界，CI 绿不解释为批准；
8. **Currency**：最近复核的完整 protected-main OID 与日期。

`AF-NNN` ID 不复用。后续发现只是既有模式的新案例时追加 case/currency；只有根因、
预防动作或验证面不同才新增 ID。任何更新仍需处在 approved change/ready task 的
allowed paths 内并由维护者 review/merge，手册本身不创造该授权。

## 3. Initial taxonomy and routing

taxonomy 分两轴。**治理/交付轴**（`AF-001`…`AF-009`，r1）关注 change、PR、
evidence 与授权面；**执行/验证轴**（`AF-010`…`AF-018`，r2）关注实现与验证动作
本身。两轴正交：同一次事故可以同时命中两轴（例如 CHG-2026-021 TR-001 harness
同时是 `AF-013` 与 `AF-012`），手册按根因归属登记，不做互斥分类。

| ID | Primary decision point | Existing machine help | Semantic question retained |
| --- | --- | --- | --- |
| AF-001 | readiness/scope | CHG-2026-028 allowed-paths guard（已落地部分） | 所有真实消费者与闭环文件是否已枚举 |
| AF-002 | design/verification | 无通用机械门 | production root 能否取得可信 authority 并到达 effect |
| AF-003 | threat model/authority | schema/contract tests 仅部分 | 谁产生事实、能否由调用者同时伪造事实与证明 |
| AF-004 | integration/platform run | Swift CI/局部 contract | producer 与 consumer 是否在同一真实路径端到端运行 |
| AF-005 | evidence/status | evidence schema/人工 review | 该 PASS 是否仍绑定当前 bytes、输入、环境和 evidence class |
| AF-006 | PR/governance | CHG-2026-028 revision/pins/path checks（分阶段） | PR 载体、状态与真实内容是否一致 |
| AF-007 | readiness/environment | Swift CI 部分覆盖 | 测试是否依赖用户目录、锁屏、隐藏链接或未钉工具链 |
| AF-008 | design/review | fault tests 按任务 | 是否覆盖资源替换、并发、崩溃窗口和 unknown outcome |
| AF-009 | governance design | 无通用机械门 | 机制是否在真实信任边界上阻断了声明的威胁 |
| AF-010 | implementation/test authoring | 无通用机械门（028 只对新 check 要求 canary） | 断言的期望值是否有独立于被测代码的来源 |
| AF-011 | verification/judgement | 局部 contract matrix | 判定用的信号是否是该工具真实的成功语义 |
| AF-012 | crib/runbook 交付 | 无（host self-test 靠约定） | 操作者的 shell 里能否一次跑通，且窗口不消耗在脚本 bug 上 |
| AF-013 | design/readiness 复用假设 | 无 | 目标 capability 的每条 SHALL 是否被被复用形态真正覆盖 |
| AF-014 | gate implementation/review | 无 | 门放行时校验的是凭据存在，还是凭据语义与目标绑定正确 |
| AF-015 | review remediation | 无（grep 靠约定） | 该 finding 是单点缺陷还是模式实例，全仓命中是否已处置 |
| AF-016 | 任何写入 pin/状态/结论 | CHG-2026-028 revision/pins 形状校验 | 这个值是复核仓内 bytes 得到的，还是从会话记忆抄的 |
| AF-017 | review 收尾/提案规模 | 无 | 每轮修复是否在加新变更面；新机制拦住了什么 review 拦不住的东西 |
| AF-018 | 并行会话/工作副本 | MECH-004 allowed-paths diff（近似） | 当前分支/工作树是谁的，他方“已通过”是否本地复验过 |

手册不得维护单独的“发生次数真相数据库”。次数只在有完整审计基线与可复查查询时
作为 dated observation 写入，避免新的同步账本。

### 3.1 r2 corrections to AF-001…AF-009

r2 复扫发现的以下子面归属既有根因，作为已观察子面并入原 ID，不新开 ID：

- **AF-001**：补三条。(a) 实现过程中发现的相邻缺陷**不得顺手修复**，越出授权面
  只能事后走 remediation（CHG-2026-026 `#303`，仅为同步一行依赖表）；
  (b) 硬编码的横切契约表（共享依赖表、registry 表）是 readiness 起草时的
  **可预见冲突点**，起草时预判设计改动波及哪些共享契约测试并提前纳入 allowed
  paths；(c) readiness 声明“交付形态与观察点逐项对应”必须验证到**逐观察点取证
  路径级**——UI 面存在 ≠ 可取证（`chg-2026-006/tasks.md` `#243` readiness →
  `chg-2026-022/proposal.md` 记录的 `#250` 当日 fail-closed 回退）。
- **AF-002**：补一条。仪表/计数落在**生产永不调用的防御性入口**等价于分支常量
  变体；强形态是唯一真实边界（如 spawn 边界）计数 + 非伪造 origin
  （`chg-2026-022/proposal.md`、`tasks.md` 记录的 `#265` 四缺口之一）。
- **AF-003**：与 `AF-014` 分工写明——AF-003 是**事实由调用方自报**（谁生产事实），
  AF-014 是**门自身校验强度不足**（门校验了什么）。同一 gate 可两者兼有。
- **AF-004**：补一条。同一契约的**多份实现**（Swift/Python/数据件）必须逐对查
  语义漂移，并在修复时显式定权威侧；`chg-2026-026` `#301` 出现同一失败态被
  Swift 判 `toolBlocked`、Python 判 `permissionDenied`，以及单一
  `maximumOutputBytes` 被 per-stream 与 combined 两种解释。
- **AF-005**：补三条。(a) “工具产出”型 evidence（receipt/JSON）必须能由**仓内
  工具复现**，手工组装即 invalidated——`#301` 首版 sanitized receipt 与
  `run_probe()` 同 `schemaVersion` 却不同 key 形状，且含不存在于任何代码枚举的
  值；review 对照法 = receipt key 集 vs 生成代码输出形状、枚举字段值 vs 代码
  `rawValue`。(b) 聚合类 evidence 只取语义流文件，元数据会把 marker 挤出截断
  窗口（`archive/2026-07-21-chg-2026-020` RF-002 postflight）。(c) 脱敏形态先例
  见 RF-001/RF-002 transcript：设备序列号/connect key 字节永不入仓。
- **AF-006**：补三条。(a) **PR 载体与内容一致**：状态 PR 不夹带实现，实现 PR 不
  夹带状态翻转（`chg-2026-028/proposal.md` 列的 `#28` 规则、`#126` 误合类）。
  (b) archive 前必做目录外精确路径引用扫描，断链即暂缓（CHG-2026-014 ledger 类；
  CHG-2026-015 曾因 evidence/provenance 被活跃 registry 正本与产品测试 fixture
  精确路径引用而长期暂缓，最终由 `#351` 以 provenance re-pin 方式收口归档 —— 该
  暂缓是扫描生效的正例，不是遗漏）。(c) PR body 的 checks 数字随修复 commit
  累积会 stale，合并前对账（`#301`）。
- **AF-007**：补两条。(a) **flaky 判定纪律**：已知环境性失败绿一次不证明它不
  存在，红一次也必须逐名核对是否**恰为**已知集，多一个即当真实失败查
  （`/private/tmp` worktree 下 HDCGolden/ProbeRegistry 两例，`#301`/`#305` 复验
  在案）。(b) **外部 CI runner 镜像的工具链谱系必须先探针实证再钉**：
  TASK-MECH-001 readiness r1 钉 `macos-15`，被实测推翻（默认与最高 Xcode 均编译
  不过），r2 `#333` 重钉 `macos-26`（`chg-2026-028/evidence/runs/TASK-MECH-001/run.md`）。
- **AF-008**：补一条。反例注入优先用**真实故障点**而非 fake——TASK-TR-002R 对
  真实 `SessionArtifactStore` 的 13 个 fault point 逐一注入，断言 cleanup
  authority=none / dispatch=0（`chg-2026-021/tasks.md` `#278`）。
- **AF-009**：与 `AF-017` 分工写明——AF-009 是**机制与真实信任边界错位**（强度
  问题：签名与被防对象同 UID），AF-017 是**机制规模超出所解决的问题**（收敛与
  成本问题）。`postmortem-2026-07-governance.md` 同时是两者的案例。

### 3.2 r2 new patterns（AF-010…AF-018）

每项在手册中仍须按 §2 的八字段展开并钉完整 OID；此处登记的是根因、案例锚点与
最低验证要求，作为 TASK-AFP-001 的封闭范围。

**AF-010 自证式验证：套套逻辑断言与未经变异证伪的测试**

- Signal：断言的期望值与被测代码取自同一赋值源或同一常量；测试只有绿证据；
  计数器/仪表定义在生产路径从不触发的入口。
- Cases：`archive/2026-07-21-chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-003/run.md`
  （tautological counter removed）；`archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/tasks.md`
  两处套套逻辑清理（测试回显字面量被误写为运行期度量）；`chg-2026-022` `#265`
  的防御性入口计数。
- Root cause：实现与测试同一作者，期望值就近取自实现；“通过”被当成“覆盖”。
- Preflight：逐条断言写出期望值的**独立来源**；每个计数/仪表定位到唯一真实边界。
- Verification：正 = 正常路径绿；反 = **变异实验必须红**（篡改 fixture 一字节、
  注入 `XCTFail`、改被测常量），红结果与红因入 evidence。
- Automation：`semanticReview`。CHG-2026-028 已把“新 check 须有 canary 红反证”
  定为四项机械化的共同验收门，但产品测试面无通用门。

**AF-011 成功判据取错信号：exit code、marker 与管道截断**

- Signal：用退出码判外部工具的语义成功；判定链经 `| tail`/`| grep` 后取 `$?`；
  只读输出末尾。
- Cases：`chg-2026-021/design.md`（空 trace `exit 0` 不判 succeeded）；
  `chg-2026-026/verification.md` AC-FLASH-012-01 的 exit0/marker/postflight 叉乘；
  `chg-2026-025/tasks.md` ld/ppt/wlx/rd 的“exit0 缺 marker”矩阵；
  `archive/2026-07-21-chg-2026-020` RF-002 `assessOutcome`（exit 0 ≠ succeeded）。
- Root cause：外部工具的成功语义未按**真实观测形态**登记；shell 管道的退出码
  语义被默认为链首命令。
- Preflight：登记该工具真实的成功/失败形态（marker、stderr、产物、退出码）；
  判定不经管道，或用 pipestatus / 先落盘后判；必须抓全汇总行而非截断尾部。
- Verification：反 = 构造 `exit 0` 但语义失败、以及非零但语义成功两向各一例。
- Automation：`partiallyMechanized`（按任务的 contract matrix；无跨任务通用门）。

**AF-012 交付给人类执行的一次性产物未在 host 侧自测（烧设备窗口）**

- Signal：crib/runbook 含未在本机跑通的语法、未验证的外部工具参数签名、
  `<占位符>`、交互式子进程或 heredoc；窗口计划里没有“脚本失败”的重试预算。
- Cases：`archive/2026-07-21-chg-2026-016-dayu200-recovery-rehearsal/evidence/runs/TASK-RH-001/`
  attempt 2/3/4 三份 blocked 记录，其中 attempt-4 的根因是
  `python3 -` 的 stdin 被 heredoc 抢占、管道里的 `ppt` 数据被整段丢弃；
  `chg-2026-008` harness echo remediation（`#222` 定义、`#229` done）。
- Root cause：把“脚本逻辑正确”当成“在操作者的 shell 里可执行”；设备窗口是
  稀缺且不可重试的一次性资源，脚本 bug 与设备事实的失败成本被等同看待。
- Preflight：交付前跑通**全部可 host 侧测项**（语法、外部工具参数签名、比对
  逻辑、退出码、脱敏、umask）；零 `<占位符>`（用 `$()` 取值或直接给脚本）；
  数据走 argv/文件不走 stdin；交互式子进程用 `script -q` 录 pty；流内容不回显
  终端，只显字节数与 hash。
- Verification：正 = host self-test 全绿并记录命令与结果；反 = 故意给错参数/
  错 hash，脚本自身必须拒绝并给出具名退出码。
- Automation：`semanticReview`。

**AF-013 形态照搬：复用既有 harness/设计而未回读目标 capability 的全部 REQ**

- Signal：“与 X 同型，照 X 做”；design/readiness 出现“复用既有面”而无逐条
  REQ 对照表。
- Cases：`chg-2026-021/evidence/runs/TASK-TR-001/run.md` 记录的 `#274` hardening——
  TR-001 harness 照搬 m0b 的“probe + 固定 owned 面 + 精确清理”形态，漏了
  REQ-TRACE-006 自身的 Job-UUID 隔离（SHALL）与 verified-receive-before-cleanup；
  `chg-2026-022` `#265` 的“复用 discovery”实际需要独立登记的周期观察面。
- Root cause：相似性判断建立在**既有实现形态**上而非**目标 spec 条款**上；
  被复用形态的隐含假设（只读面、固定路径）在新语境下不成立。
- Preflight：列出目标 capability 的全部 REQ 与 SHALL，逐条标注被复用形态
  覆盖/未覆盖；复用假设验证到“该面是否被**治理登记**”级，而不是“代码里有”。
- Verification：反 = 对每条标为未覆盖的 SHALL，写出它在当前设计下会如何被违反。
- Automation：`semanticReview`。

**AF-014 门只校验凭据存在/形状，不校验语义绑定（fail-closed 弱化）**

- Signal：以“类型封死构造器/typed gate 存在”论证“绕过不可能”；门所需的 capability
  值可由调用方直接构造而不经能力校验；cleanup/dispatch 无条件执行。
- Cases（**r3 更正，逐条钉到一手出处**）：`chg-2026-021/tasks.md` TASK-TR-002R
  的四个 gap（`#276` scoping、`#278` real-fault 修复），四条均是前一轮 review 判
  APPROVE 后由 post-merge 对抗审查逮到：
  1. rebind context 未绑定期望目标与 pre-reboot revision——一手表述见
     `chg-2026-021/tasks.md` 二值门 ①（wrong target、same/older/skipped revision
     全部 dispatch=0，只有 exact `revision + 1` receipt 放行）；实现层标识
     `expectedTargetID` 位于 `TraceWorkflowContracts.swift`；
  2. plan builder 无条件 cleanup 且无 publication receipt——一手表述见
     `evidence/runs/TASK-TR-002R/run.md`（typed remote-cleanup authority 与
     bound cleanup step）；
  3. catalog membership 被当作 per-device capability——一手表述见同 run.md
     （“Catalog membership alone … fail before mutation plan materialization”）；
  4. reliable progress total 可不经 capability 校验产生——一手表述见
     `chg-2026-021/tasks.md` 二值门 ④（“reliable-total receipt 只能由当前 adapter
     capability=true factory 产生，false/缺失/drift/非法 total 均保持 indeterminate
     + elapsed”）与同 run.md（“Reliable progress totals have no public
     initializer … minted only by a factory”）；相关 capability 字段为
     `TraceCatalogContracts.swift` 的 `reliableByteTotalAvailable`。

  > **r2 勘误（不改写 r2 的 Git 历史）**：r2 曾把第 4 条写作
  > “`TraceProgressTotal.reliable` 作为 public case 绕过 capability 门”，并把该
  > 表述整体归属于 `chg-2026-021/tasks.md`。经全仓复核，`TraceProgressTotal`
  > **在仓内不存在**（仅出现于 r2 的本文件），“public enum case”这一机制描述亦
  > 未经一手核对；同段的 `expectedTargetID` 与 `publication receipt` 虽为真实
  > 符号，但位于 Swift 源码/测试与 run evidence，不在被归属的 `tasks.md` 内。
  > 根因 = `AF-016`（以会话记忆代替一手核查），发生在本 change 自身的 r2 起草中。
  > `AF-014` 模式本身与四条 gap 的存在性不受影响。发现载体 = TASK-AFP-003
  > readiness（`#369`）的 pin 复核。
- Root cause：review 追问停在“门是否可被绕过”，没有继续追问“**门放行时校验的
  凭据语义是否正确**”。类型封死防的是跳过接受步骤，不防凭据本身语义错误。
- Preflight：对每个 gate 写出——凭据由谁产生、绑定到哪个具体目标/revision、
  是否可由调用方自行构造、cleanup/dispatch 是否需要真实 receipt。
- Verification：反 = 真实（非 fake）fault 注入覆盖凭据错绑、缺 receipt、
  未经能力校验直接产生 capability 值三向，断言 authority=none 且 dispatch 计数为 0。
- Automation：`semanticReview`。与 AF-003 的分工见 §3.1。

**AF-015 缺陷类只在发现点修复，未全仓扫描同模式**

- Signal：review 指出一处缺陷，修复 diff 只触及该处，无同模式搜索记录。
- Cases：`archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/`
  的 review-remediation round 2/3/4（同类问题逐轮再现）；`chg-2026-026` `#301`
  的 `#filePath` 脆弱性由后续 `#305` 收口，HDC Golden/Trace 同族因 hash 多处
  pin 收口成本高而**如实留为已记录限制**。
- Root cause：把 review finding 当作单点缺陷而非模式实例；修 A 处后 B 处复发。
- Preflight：每个 finding 先全仓 grep 同模式，列出全部命中及其处置
  （修复 / 记录限制并说明成本 / 另立 change），三选一但不得沉默。
- Verification：反 = 修复后同模式搜索结果为空；未修项必须有具名记录与理由，
  “漏掉”与“有意留下”在 evidence 中可区分。
- Automation：`semanticReview`。

**AF-016 以会话记忆/摘要代替一手核查**

- Signal：pin、状态、待办或结论的来源是“上次/我记得/摘要里写了”；引用他处
  摘要而未复核仓内 bytes；对外部环境（runner 镜像、工具链版本）凭印象下钉。
- Cases：`chg-2026-022` `#265` 的第四个 gap——readiness pins 用截断前缀且未对
  一手 evidence 复核；`chg-2026-024` r2 的三方 revision 漂移（`#275`，与
  CHG-2026-015 `#140`→`#152` 同型重演）；`chg-2026-028/evidence/runs/TASK-MECH-001/run.md`
  的 readiness r1 `macos-15` 假设被 CI 实测推翻。
- Root cause：长会话与跨会话摘要被当作事实源；唯一事实源是 protected-main
  bytes 与一手 evidence。摘要天然滞后于 `main`。
- Preflight：任何 pin/状态/待办写入前对 repo 复核；外部环境先探针实证再钉；
  引用他处结论时给出可解析路径与完整 OID，而不是转述。
- Verification：反 = 对至少一项 pin 独立重取并逐字比对，比对命令与结果入
  evidence；不一致即 blocked 而非就地改小。
- Automation：`partiallyMechanized`。CHG-2026-028 MECH-002/003 覆盖 revision
  同步与 pin 的**形状**（全 40/64 hex），不覆盖“值是否来自一手核查”。

**AF-017 收敛失败：修复轮次引入新架构与过度设计**

- Signal：每轮 review 修复都带来新抽象或新机制；轮次不收敛；提案的机制规模
  明显超出所解决问题。
- Cases：`chg-2026-008/tasks.md`、`verification.md` 与 `planning/backlog.md`
  记录的 r3 初稿（`#128`，head `a613b76`）JAUTH 过度架构，经 `#131` 裁剪为
  M0B-model gates、JAUTH 降级入 backlog；`planning/postmortem-2026-07-governance.md`
  记录的 V1——约 12,900 行 guard 自身成为唯一事故源，0 行产品代码受影响，且
  恢复方向一度是把失败机制重建为更重的版本（外部签名服务/WORM/HSM）。
  次要案例：`archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/`
  的四轮 remediation（与 `AF-015` 共用，此处取“轮次为何不收敛”一面）。
- Root cause：用新机制回答缺陷而不是用最小修复；收尾阶段仍在扩大变更面，
  每个新面又带来新的可失败点。
- Preflight：收尾阶段显式声明**机制冻结**（只修不加）；任何新机制先回答
  “它拦住了什么 PR review 拦不住的东西”，答不上即不立项。
- Verification：反 = 收尾轮次的修复 diff 新增抽象数为 0；新机制的 rollback
  路径是单次 revert。
- Automation：`semanticReview`。与 AF-009 的分工见 §3.1。

**AF-018 多会话共享状态与轻信他方声明**

- Signal：多个会话共用同一工作副本；引用另一会话的“已修复/已通过”作为结论；
  并行任务无文件级分工；提 PR 时对方仍在实时编辑。
- Cases：`chg-2026-021`/`chg-2026-022` 的 TR-002 与 OBS-001 并行——两侧 readiness
  各自写入文件级分工（Trace* 新文件 vs supervisor 既有文件）以保证零交集；
  `chg-2026-026` `#301` 分支被他会话 worktree 占用的处置记录。
- Root cause：git 工作副本、分支 HEAD 与 PR 状态都是**共享可变状态**；他方
  声明未经本地复验即被引用为事实（与 AF-016 同源但触发点不同）。
- Preflight：commit 前确认当前分支；并行实现真用 git worktree；并行任务在
  readiness 显式写文件级分工；他方“已通过”一律以本地重跑为准。
- Verification：正 = 本地独立复跑编译/测试；反 = 分工交集为空的机械核对
  （两侧 diff 文件集比对）。
- Automation：`partiallyMechanized`（MECH-004 的 allowed-paths diff 是近似，
  防的是无意混装，不防并发写同一文件）。

### 3.3 r5 AF-014 first-source remediation contract

r3 已否定“public enum case 绕过 capability 门”这一未经一手核对的机制描述，但
现行手册仍在 `AF-014` 的 Signal、Observed cases、Preflight 与 Negative verification
保留该表述。TASK-AFP-006 必须只按下列一手事实修正，不得从 r2 散文或会话记忆补足：

1. `chg-2026-021/tasks.md` 二值门 ①：expected target、pre-reboot revision 与
   selected candidate 共同约束 rebind，只有 exact `revision + 1` receipt 放行；
2. `TASK-TR-002R/run.md`：只有 matching `PublishedArtifact` 可产生 remote-cleanup
   authority，publication fault 无 cleanup authority/dispatch；
3. 同一 run：catalog membership alone 不构成 per-device capability；
4. `chg-2026-021/tasks.md` 二值门 ④ + 同一 run：reliable-total receipt 只能由
   当前 adapter `capability=true` factory 产生，reliable progress total 没有 public
   initializer；false/missing/invalid/drifted capability 保持 indeterminate。

手册的允许改动封闭为 `AF-014` 四处：

- **Signal**：以“reliable total/capability 值是否可绕开当前 adapter factory 产生”
  替换“公开枚举 case”；
- **Observed cases**：第四条 Fact 改为 capability-bound factory/receipt 的一手表述，
  同时链接 tasks.md 与 TASK-TR-002R run；
- **Preflight**：追问 capability/receipt 的唯一 minting point、当前 adapter binding
  与调用方是否可绕开 factory 自制；
- **Negative verification**：以 missing/false/drifted/invalid capability 与绕开
  factory 的构造尝试为反例，断言保持 indeterminate/authority none/dispatch 0。

为避免再次以汇总替代证据，`evidence/runs/TASK-AFP-004/addendum-r5.md` 必须：

1. 明确旧 TASK-AFP-004 run 的 `AFP-CORRECT-001 PASS` 对 AF-014 部分
   `superseded`，但不改写旧 run bytes；
2. 对手册 implementation base 上**全部当前 Fact 行**逐行列出：行 ID、AF ID、
   一手相对路径、完整 40-hex blob OID、可检索位置、supported/
   partially-supported/unsupported 判定与处置；
3. 单列 AF-014 before/after 与上述两份一手 source 的逐句对应；
4. 记录 `Inference` 误标检查、全部相对链接/anchor、OID ancestry、代码符号、
   privacy、archive/template/forbidden diff 与实际链接计数；
5. 将 18 项 `Currency` 统一更新为本次全量复核的 implementation audit base。

TASK-AFP-006 不新增 AF ID、acceptance ID、自动化门或批准语义；旧 evidence 是历史
事实，新 addendum 只取代其用于当前 change-level conclusion 的资格。

## 4. Template integration

### tasks template

新增短字段，不复制整份手册：

```text
- Applicable failure patterns:AF-NNN... | none（附理由）
- Production reachability:root → authority → effect，或明确 not applicable
- Trusted fact sources:事实生产者、freshness/binding 与 anti-forgery 边界
```

选择 `none` 不是自动通过；reviewer 可要求改为相关 AF ID。字段本身不改变 task
status，也不替代 Requirements/Acceptance/Allowed paths/Verification。

### design template

在 architecture/failure/security 之间增加 “Authority and production reachability”：

- production composition root；
- authority/permit/capability 的唯一产生点；
- effect dispatch point 与 intent/outcome durable 边界；
- fake/simulation 与 production 的结构差异；
- facts/provenance 是否能由同一调用者同时控制。

对于纯文档/host-only 无 effect 的任务可写 `not applicable`，但必须给出理由。

### evidence-run template

run identity 增加完整 base OID、关键输入 hash/pin、producer→consumer 路径与 evidence
currency：

- `current`：本 run 精确绑定当前被评审 bytes；
- `superseded`：保留历史事实但不得用于当前结论；
- `invalidated`：执行/输入/环境不满足方法，不构成 acceptance evidence。

状态必须在事实原位可见；不得只在新文件尾部写一个模糊 supersession 注记。

## 5. Historical detection drill

AFP-003 固定选择至少六个仓内案例，覆盖全部九个 AF 类别中的主要决策点。最低案例：

1. CHG-2026-026 RKFUI-001 dependency table/allowed-path remediation；
2. CHG-2026-022 OBS production source 与 unforgeable origin 缺失；
3. CHG-2026-025 AIN r2 caller-controlled authorization/facts/dispatch；
4. archived CHG-2026-009 signed broker JSON bool producer/consumer 缝隙；
5. archived CHG-2026-002 M1-009 filesystem/adversarial 多轮 remediation，或 M1-006
   current-revision evidence/supersession；
6. `postmortem-2026-07-governance.md` 的 V1 信任边界错位。

演练表每行记录：若使用新模板，最早在哪个阶段触发、对应 AF ID、需要的阻断/拆分/
验证动作、历史上最终发现该问题的证据。另加入至少一个环境失败反例（例如锁屏、
module cache、缺 PyYAML 或 quarantine），证明手册要求如实分类而不是把环境失败误报为
产品缺陷。

AFP-003 只写本 change evidence，不修改上述历史文件，也不宣称重新验证历史 change。

**r2 补充（不改变 `AFP-DRILL-001` 的最低要求）**：上述六个固定案例全部落在
治理/交付轴。执行/验证轴的案例已在 §3.2 逐项给出锚点，drill 的 readiness PR
**可以**在六案例之外追加执行轴案例（推荐 CHG-2026-016 attempt-4 的 heredoc/stdin
窗口损耗对应 `AF-012`，与 TR-002R 四 gap 对应 `AF-014`），但追加属可选覆盖，
不构成新的验收条件，也不改变“六个固定案例 + 至少一个环境反例”这一二值门。

## 6. Verification strategy

- 结构审读：九个 AF ID 唯一、字段齐全、canonical link 可解析、完整 main OID 格式正确；
- shadow-spec 扫描：手册没有新增 normative `SHALL`、批准/授权状态或产品支持声明；
- 模板 diff 审读：只新增提示字段，不删除/放宽既有 task/design/evidence 条目；
- historical drill：六个固定案例 + 一个环境反例均能映射到具体模板字段和动作；
- repository checks：`scripts/check-sdd.sh`、`git diff --check`，archive diff 为零。

不为这份 Markdown 手册新增 parser 或数据库。若后续复发数据证明某一字段适合机械化，
另立 change，并要求正例与 canary/反例同时证明，避免“只会绿”的检查。

## 7. Task and PR boundaries

- AFP-001：只交付手册与本 task evidence；
- AFP-002：只交付三个模板的小改与本 task evidence；
- AFP-003：只交付 historical drill evidence；
- AFP-006：只交付 AF-014 手册修正、TASK-AFP-004 addendum、本 task run 与本 task
  evidence 引用；
- approval、各 task 的 readiness、implementation/evidence、done 与 verified 分别保持
  独立 PR；
- 所有任务均不得修改 `AGENTS.md`、enforcement、spec/contracts、archive 或产品代码。

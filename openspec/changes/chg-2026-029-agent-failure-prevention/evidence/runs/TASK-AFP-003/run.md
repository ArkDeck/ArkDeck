# TASK-AFP-003 run record — 历史案例检出演练 — 2026-07-23

- Evidence class: `plan`（document review；零产品执行、零硬件、零 device/network dispatch）
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `AFP-DRILL-001`
- Base: `cfab930722afe60ed5e8759ea0c91d7a178971cc`（readiness r2 #381 合入后）
- Input pins: readiness r2 carrier **28/28** 于本 base 实测复核无漂移
- Producer → consumer: 本演练的"producer"是 readiness r2 所钉的历史一手记录 bytes，
  "consumer"是 TASK-AFP-002 已合入的模板字段与 TASK-AFP-004 已复核的手册条目；
  两端在同一 base 上直接比对。**不经本 change 的 design/proposal 转述**。
- Evidence currency: `current`

> 本 run 不翻转任务状态，不修改任何历史文件，不重新验证任何被引用 change 的结论，
> 也不构成产品、硬件、平台、conformance 或 support 声明。

## Environment

- macOS；仓内 Git + Markdown；`scripts/check-sdd.sh` 经 `.venv-sdd`。
- 零外部工具、零网络、零 secret、零设备。

## 演练方法与其边界

对 readiness r2 封闭的六个历史案例，逐例回答：**如果 TASK-AFP-002 已合入的模板字段
在当时就存在，最早会在哪一阶段、由哪个字段、促成什么动作。**

**列 ①②③⑤ 是事实**（阶段、AF ID、字段名、历史发现证据均可由 pinned bytes 与
protected `main` ancestry 直接核对）。**列 ④ 与"会更早发现"这一判断整体是
`Inference`** —— 历史上这些字段并不存在，任何"当时会被拦住"的说法都是反事实推断，
不得表述为既成事实。本 run 在每行显式标注。

## 六案例检出矩阵

### 案例 1 — readiness/allowed-paths 漏项（`AF-001`）

| 列 | 内容 |
| --- | --- |
| ① 最早触发阶段 | **readiness**（实现开工前） |
| ② AF ID | `AF-001` |
| ③ 模板字段 | `tasks.md` 的 **`Allowed paths`**（既有）+ 新增 **`Trusted fact sources`** 的"消费者枚举"面 |
| ④ 促成动作（`Inference`） | 起草 readiness 时逐项写出"谁消费本任务改动的文件"，会把共享依赖表纳入枚举，从而**在开工前**扩充 allowed paths，而非实现时被 CI 阻断再补 remediation |
| ⑤ 历史最终发现 | 实现 PR #301 merge `864df6fb29213e39338e72f4e35d7369d10ab961` 期间全量套件被 allowed-path blocker 阻断；精确路径 remediation PR #303 merge `b81361bcbe19c136e96005513261a38252755c9c` |
| ⑥ 标注 | ①②③⑤ = `Fact`（RKFUI-001 `run.md` 记载 blocker 与 remediation 清除）；④ = `Inference` |

### 案例 2 — production source / unforgeable origin 缺失（`AF-002`，并触 `AF-010`）

| 列 | 内容 |
| --- | --- |
| ① 最早触发阶段 | **design** |
| ② AF ID | `AF-002`（主）、`AF-010`（计数落在生产不可达入口一面） |
| ③ 模板字段 | `design.md` 的 **`## Authority and production reachability`**，具体是"production composition root"与"authority 产生点/谁能构造它"两问 |
| ④ 促成动作（`Inference`） | design 阶段必须写出 fan-out 的生产数据源与计数的唯一真实边界；写不出即应在 design 收敛前暴露"生产面不存在"，而不是进入实现后由 review 判 prototype 失效 |
| ⑤ 历史最终发现 | CHG-2026-022 `review.md` 记 `OBS-FANOUT-001` 无 production data source、`OBS-COUNTER-001` 无可满足的 unforgeable production origin，被接受的替代形态是唯一成功 identity-bound spawn hook 上的 opaque-permit 分类；#269 merge `3147e33c0d4bf0f9f54e6160850a42f370c05cb6` |
| ⑥ 标注 | ①②③⑤ = `Fact`；④ = `Inference` |

### 案例 3 — caller-controlled authorization / facts / dispatch（`AF-003`，并触 `AF-014`）

| 列 | 内容 |
| --- | --- |
| ① 最早触发阶段 | **design**（迟至 readiness） |
| ② AF ID | `AF-003`（主）、`AF-014`（门校验强度一面） |
| ③ 模板字段 | `tasks.md` 的 **`Trusted fact sources`**（事实生产者 / freshness-binding / anti-forgery 边界）+ `design.md` 的 **`Facts/provenance` 一问**（能否由同一调用方同时构造事实与其证明） |
| ④ 促成动作（`Inference`） | 该字段要求逐项写出"谁生产 authorization、绑定到哪个 revision、调用方能否自制"，正是 `P0-AUTH-001`/`P0-FACT-001` 的提问形式；并发 usage count 的原子性也在同一问下 |
| ⑤ 历史最终发现 | CHG-2026-025 `review.md` 的 `P0-AUTH-001`（parser 只校验 JSON shape 与 pin 格式）、`P0-FACT-001`（`maxRuns=1` 可被多个 `priorRunCount=0` 并发通过）、`P0-DISPATCH-001`（正例 contract 真实 dispatch = 0）；#299 merge `a2dab4c3f4279cff0ef1a859cdb5297afe9aeb85` |
| ⑥ 标注 | ①②③⑤ = `Fact`；④ = `Inference` |

### 案例 4 — producer→consumer 跨语言缝隙（`AF-004`）

| 列 | 内容 |
| --- | --- |
| ① 最早触发阶段 | **implementation**（首次真实端到端 run 之前） |
| ② AF ID | `AF-004` |
| ③ 模板字段 | `evidence-run.md` 的 **`Producer → consumer`**（本 run 实际走通的路径两端；未端到端跑通时写明缺口） |
| ④ 促成动作（`Inference`） | 该字段迫使 run 记录声明"两端是否在同一真实路径跑通"；若只有单侧套件绿则须写明缺口，从而把端到端 run 提前到平台 attempt 之前 |
| ⑤ 历史最终发现 | archived TASK-PD-002 `platform-attempt-2026-07-20.md` 记首次真实 producer→consumer run 暴露 Objective-C `@(expr != 0)` 装箱 `NSNumber(int)`、JSON 为 `1`、Python `is True` 永败而 `==` 意外通过；r5 revision #158 merge `b8902b199bfa834e8ea6022ea30f8e809c280eee`，producer 修复 #160 merge `33aff46b9a66370074af66b66ff2afb1ec164e48` |
| ⑥ 标注 | ①②③⑤ = `Fact`（该 attempt 为 blocked 记录，未升级为 passing evidence）；④ = `Inference` |

### 案例 5 — adversarial 多轮 remediation（`AF-008`，并触 `AF-015`）

| 列 | 内容 |
| --- | --- |
| ① 最早触发阶段 | **design** |
| ② AF ID | `AF-008`（主）、`AF-015`（同类问题跨轮再现一面） |
| ③ 模板字段 | `design.md` 的 **`## Failure, cancellation, and recovery`**（既有）+ 新增 **`Fake/simulation 与 production 的结构差异`** 一问；`tasks.md` 的 **`Applicable failure patterns`** 选中 `AF-008` 会引到手册的 adversarial matrix |
| ④ 促成动作（`Inference`） | 在 design 阶段一次性列出路径替换、inode/rename、非常规文件、writer-lock/identity 等面，而不是逐轮由 review 补齐；`AF-015` 一面则要求每个 finding 先全仓扫同模式 |
| ⑤ 历史最终发现 | archived TASK-M1-009 四份 remediation 记录逐轮暴露上述面（FIFO/non-regular 在 round 3；writer-lock/identity 与路径替换在初轮与 round 4）；实现 PR #50 merge `15697e85444fdacab81779a588c0e290c2f47125` |
| ⑥ 标注 | ①②③⑤ = `Fact`（轮次归属经 AFP-004 一手复核更正）；④ = `Inference` |

### 案例 6 — 治理机制与真实信任边界错位（`AF-009`，并触 `AF-017`）

| 列 | 内容 |
| --- | --- |
| ① 最早触发阶段 | **proposal**（机制立项时） |
| ② AF ID | `AF-009`（主）、`AF-017`（规模超配一面） |
| ③ 模板字段 | `design.md` 的 **`## Authority and production reachability`**，具体是"authority 产生点：谁能构造它"与"fake 与 production 的结构差异"两问 |
| ④ 促成动作（`Inference`） | 该两问在治理机制上等价于"私钥与被防对象是否同 UID""ledger 在真实部署中是否跨 run 存活"；据实回答会在 ratify 前暴露密码学层对自身威胁模型零防护 |
| ⑤ 历史最终发现 | `postmortem-2026-07-governance.md` 记三把私钥与运行 Agent 同机同 UID 可读且存在自动签名路径、ledger 每次从空目录重建、被判 P0 的 identity 碰撞实为维护者自身 relock 的正常运维；#2 merge `47b310d6ef4e06a3048b74c71420bfe411b53621` |
| ⑥ 标注 | ①②③⑤ = `Fact`；④ = `Inference` |

## 环境失败反例（误报边界）

### 反例 — E0 quarantine blocker（**保持 environment blocked，不是产品缺陷**）

| 列 | 内容 |
| --- | --- |
| 事实 | RKFUI-001 `run.md`：operator 经 `NSOpenPanel` 选中精确 pinned 工具，bookmark 与 security-scope 均成功；子进程启动前观察到 ad-hoc 签名完整但 `com.apple.quarantine` 存在且 Gatekeeper 拒绝，因此返回 typed `toolBlocked(quarantinePresent)` 并**零子进程启动** |
| 产品行为 | ArkDeck **未**清除或改写 quarantine、**未**尝试 helper/提权绕过；run 明确记载 quarantine 来源未独立确定，故只记录"存在"而不主张由谁添加 |
| 记账形态 | 该 attempt 记为 **BLOCKED**：`platform trust = BLOCKED`、`direct non-elevated ld = NOT DISPATCHED`、`USB semantic result = NOT OBSERVED`、`device mutation / destructive = 0 / 0`；execute-readiness gate 保持 blocked |
| 手册判定 | 命中 `AF-007`（非 hermetic 环境）的**正确一侧**：环境阻断被如实分类为环境阻断。手册**不会**把它判为产品缺陷——`AF-007` 的 Preflight 要求消除或显式钉定宿主假设，而本例的宿主假设（工具未被 quarantine）已被显式记录为未满足 |
| 二值边界 | `fake`/`simulation`/`plan` 未因本演练升级为 `realHardware` 或平台支持；该 attempt 未被记为 PASS |
| 标注 | 全部为 `Fact`（逐项取自 pinned run.md） |

### 备用反例

RKFUI-001 `hermetic-contract-test-2026-07-22.md` 记录的 `/private/tmp` 工作树口径
差异，对应 `AF-007` 的 flaky 判定纪律面（已知环境性失败须逐名核对，不得因绿一次
即认定不存在）。本 run 不展开，仅登记其可用性。

## 可选覆盖（执行/验证轴，不构成验收条件）

readiness r2 允许追加执行轴案例。本 run 追加**一例**作为方法示范，不改变二值门：

- `AF-012`（交付给人类执行的一次性产物未 host 自测）→ archived CHG-2026-016
  `rehearsal-attempt-4-2026-07-21.md`：根因是 heredoc 占用 `python3 -` 的 stdin、
  管道数据被丢弃。最早触发阶段 = **implementation**（crib 交付前）；模板字段 =
  `evidence-run.md` 的 `Producer → consumer`（"未端到端跑通时写明缺口"会迫使
  crib 作者声明 host 自测覆盖面）；④ = `Inference`。

## Commands and results

| Command | Result |
| --- | --- |
| 开工前 readiness r2 carrier 复核（28 项） | 28/28 无漂移 **PASS** |
| 六案例逐行六列齐全 | 6/6，无缺列 **PASS** |
| 环境反例 | 1 主 + 1 备用，主反例六项逐条取自 pinned bytes **PASS** |
| 每行 AF ID 存在于已合入手册 | 引用 `AF-001`…`AF-004`、`AF-007`…`AF-010`、`AF-012`、`AF-014`、`AF-015`、`AF-017` 全部命中 **PASS** |
| 每行模板字段存在于已合入模板 | `Allowed paths`、`Trusted fact sources`、`Applicable failure patterns`、`## Authority and production reachability`、`## Failure, cancellation, and recovery`、`Producer → consumer` 全部在场 **PASS** |
| 完整 40-hex OID 复核 | 本 run 引用的承载 merge OID 全部在 protected `main` ancestry **PASS** |
| `Fact`/`Inference` 分离 | 每案例第 ⑥ 列显式标注；列 ④ 全部标 `Inference` **PASS** |
| hindsight-bias 扫描 | 历史结论改写 = 0；产品/硬件重新验证声明 = 0；`fake`→`realHardware` 升级 = 0 **PASS** |
| `changes/archive/**` diff | 0 **PASS** |
| allowed/forbidden path audit | diff 仅本 change `evidence/**` 与 `tasks.md`；手册与模板零触碰（均在本任务 forbidden paths 内）**PASS** |
| `./scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | 干净 **PASS** |

## AC conclusion

- `AFP-DRILL-001`: **passed**（documentReview）。六个 readiness 钉定的历史案例各自
  映射到最早触发阶段、AF ID、具体模板字段、应采取动作与历史最终发现证据（含完整
  merge OID）；至少一个环境失败反例保持 environment blocked 而非产品 failure；
  演练未修改任何历史 bytes 或结论，未产生产品、硬件、conformance、support 或
  release 声明。

## Deviations and residual risk

- **方法论边界（非偏差，显式声明）**：列 ④ 与"会更早发现"整体是反事实推断。历史上
  这些模板字段并不存在，本 run 不主张"当时应当被发现"以外的更强命题，也不据此
  重判任何历史 review 的质量。
- **Residual risk 1 — 选择性**：六案例由 readiness 钉定，不是全量历史扫描；它们
  证明手册与模板对**已发生**模式可检出，不证明对未来模式的覆盖率。
- **Residual risk 2 — 字段映射的主观性**：同一案例可能合理地映射到多个字段；本 run
  取"最早能问出该问题"的字段，reviewer 可提出不同映射而不推翻案例事实。
- **Residual risk 3 — 无机械门**：drill 结论由 document review 承担，未引入
  parser/CI（proposal 明列 out of scope）。
- destructive dispatch = **0**；device/network/effect dispatch = **0**；真实硬件 = **无**。

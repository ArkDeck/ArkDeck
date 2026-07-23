# TASK-AFP-002 run record — 2026-07-23

- Evidence class: `plan`（document review；零产品执行、零硬件、零 device/network dispatch）
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `AFP-TEMPLATE-001`
- Base: `9397e23d62434cc9b7cb747d721044442322763f`（readiness #364 合入后）
- Input pins: readiness r1 两个 `yaml pins` carrier 共 **52 项**，开工前于本 base
  实测复核 **52/52 无漂移**；三个模板 blob 仍为 readiness 钉定值
  `7fe7e00a9cf3ebc051abb4ced4147b8ca8d8d540`（tasks）、
  `b3f18410a2199975595b44a1cdd558ab890825d5`（design）、
  `a5fb98d9eada0d0664772756cfc8b2a2b1e78f3a`（evidence-run）
- Producer → consumer: 本 run 无产品 producer/consumer 链（模板是给未来任务作者
  阅读的文档面）。可验证的"消费"= 本 run 记录自身按新增的 evidence-run 字段填写，
  即模板消费者的首个实例；模板对未来任务的实际约束力由 review 承担，不由本 run 证明。
- Evidence currency: `current`（精确绑定本 PR 提交的三个模板 bytes）

> 本 run 不翻转任务状态。`ready→done` 使用独立 PR；本记录不构成 change `verified`，
> 也不构成任何批准、授权或平台/硬件支持声明。

## Environment

- macOS；仓内 Git + Markdown；`scripts/check-sdd.sh` 经 `.venv-sdd`。
- 零外部工具、零网络、零 secret、零设备。审读脚本在仓库外 scratchpad 执行，
  不产生仓内写入，不是交付物。

## Work completed

按 readiness 的 **Exact field set:closed** 逐项交付，只增不删：

| 模板 | 新增 | 插入点（实测行号） |
| --- | --- | --- |
| `tasks.md` | 恰 3 个 bullet：`Applicable failure patterns`(L23)、`Production reachability`(L28)、`Trusted fact sources`(L32) | `Readiness input pins`(L12) 之后、`Allowed paths`(L36) 之前 ✓ |
| `design.md` | 恰 1 个二级小节 `## Authority and production reachability`(L24)，含五要点 | `## Data and contract changes`(L20) 之后、`## Failure, cancellation, and recovery`(L35) 之前 ✓ |
| `evidence-run.md` | 恰 4 个 run identity bullet：`Base`(L10)、`Input pins`(L11)、`Producer → consumer`(L12)、`Evidence currency`(L13，含三态与"事实原位"要求) | 既有 `Evidence class`/`Core baseline`/`Scope`(L7–9) 列表内 ✓ |

三处均含 readiness 要求的三条可见约束：允许诚实 `not applicable` + 理由；
`none` 不是自动通过（reviewer 可要求改为相关 AF ID）；不创造批准/状态语义
（"本行只用于让相关问题在开工前被显式回答，不改变任务状态或批准语义"、
"本节只要求把判断写下来，不创造批准或就绪语义"、"填写本行不使调用方自报字段
升级为可信事实"）。

手册引用使用相对路径 `../../planning/agent-failure-patterns.md`，并标注其为
非权威索引、与 canonical rule 冲突时以 canonical 为准。

## Commands and results

| Command | Result |
| --- | --- |
| 开工前 pins 复核（两个 carrier，52 项） | 52/52 无漂移 **PASS** |
| `git diff --numstat` 三模板 | tasks `+13 -0`、design `+11 -0`、evidence-run `+10 -0` — **零删除、零修改行** **PASS** |
| zero-deletion 逐行核（base 每一非空行是否仍在 head） | tasks 41→54、design 34→45、evidence-run 33→43；base 行缺失 **0** **PASS** |
| 既有关键条目在场（13 项点名） | 13/13 在场 **PASS** |
| polarity-aware boundary scan（6 类） | 各项 **0** **PASS** |
| boundary scan canary（4 条注入违规） | 4/4 **变红** **PASS** |
| 模板内新增相对路径解析 | `../../planning/agent-failure-patterns.md` → 解析到 `openspec/planning/agent-failure-patterns.md` **PASS** |
| `changes/archive/**` diff | 0 **PASS** |
| allowed/forbidden path audit | diff 仅三个模板 + 本 change `evidence/**` + 本 change `tasks.md`（仅 evidence 引用）；forbidden 面零触碰 **PASS** |
| `./scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | 干净 **PASS** |

### 13 项点名的既有条目（zero-relaxation）

tasks 模板：`Status` 取值行、非载体 ` ```yaml pin-example ` 块、"实例化时改用
`yaml pins`"注记、`Risk` 行的 destructive/standing authorization 注释、
`Forbidden paths`、`Deliverables`/`Verification`/`Notes / handoff`；
design 模板：`Requirement mapping`、`Alternatives and ADRs`、"Design 不能藏产品
规则"；evidence-run 模板：抬头禁令、"simulation/fake 永不计入 realHardware"、
"run record 不改任务状态"、CHG-2026-025 引入的人类执行例外。全部逐字保留。

### boundary scan 的自纠与反证

首版扫描对两处报红，逐条核对上下文后判定为**正则假阳性**，而不是直接放行：

| 命中 | 实际文本 | 判定 |
| --- | --- | --- |
| `tasks.md:26` | "填 `none` **不是**自动通过" | 否定式表述，正是 readiness 要求写入的约束 |
| `evidence-run.md:38` | "simulation/fake **永不**计入 realHardware" | base 既有禁令，本 PR 未触碰（`-0` 已证） |

处置：扫描改为 **polarity-aware**（同句含否定词即判为禁止/否定表述），复跑
6 类全 0。为避免"改宽判据把红改绿"这一自证式风险（`AF-010`），对精化后的扫描
注入 4 条真实违规做 canary：自动批准断言、`simulation` 计入 `realHardware`、
手册优先于 constitution、新增 `SHALL` —— **4/4 全部变红**，证明放宽的只是极性
判断而非检测能力。

## AC conclusion

- `AFP-TEMPLATE-001`: **passed**（documentReview）。三个模板按 design §4 与
  readiness Exact field set 增加短字段；既有 Requirements/Acceptance/Depends/
  Allowed/Forbidden/Risk/Hardware/Deliverables/Verification/Notes、design 六小节、
  evidence-class 规则与两条禁令**零删除零放宽**（逐行核 + `-0` 双证）；新增字段
  允许诚实 `not applicable` + 理由且不自动通过；不存在自动 approval/ready/done、
  fake→realHardware 或手册覆盖 canonical rule 的表达。

本 run 不主张 `AFP-HANDBOOK-001`（已于 TASK-AFP-001 达成）或 `AFP-DRILL-001`
（TASK-AFP-003 仍 `blocked`）的任何结论。

## Deviations and residual risk

- **Deviation（如实记录）**：首版 boundary scan 的两处红为正则假阳性，见上节；
  精化判据后以 4 条 canary 反证检测能力未被削弱。该过程记录于此，不修改扫描
  结论本身。
- **Residual risk 1 — 模板是提示而非强制**：新增字段不由 parser/CI 校验，作者可
  填写空洞内容或误答 `not applicable`。缓解 = reviewer 可要求改写；进一步机械化
  须另立 change（proposal 明列 out of scope）。本 run 不声称模板具备强制力。
- **Residual risk 2 — 手册链接脆弱**：`../../planning/agent-failure-patterns.md`
  依赖手册路径不变；路径变动会静默断链，无机械门。如实记录，不声称已解决。
- **Residual risk 3 — 存量 change 不追溯**：既有 active change 的 tasks/design/
  evidence-run 不因本次模板更新而回填新字段；本 PR 未改动任何既有 change 文件。
- destructive dispatch = **0**；device/network/effect dispatch = **0**；
  真实硬件涉及 = **无**。

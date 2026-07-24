# CHG-2026-032 Tasks

> Change approval 状态以 `proposal.md` 为唯一事实源。本文件只登记任务，不执行任务、
> 不产生 completion evidence，也不把任何 task 置 ready；change approval 本身不解除
> 各任务的独立 readiness 前置。

## TASK-HLD-001 — 活跃 change 引用改为耐久形式

- Status:done（2026-07-23；仅在维护者 review/merge 本独立状态 PR 后生效。
  implementation + evidence PR #441 已合入 protected `main`，squash merge OID
  `b8f41066e0aa3a8d1343f805524f9c9439ff9c5c`；交付物
  `openspec/planning/agent-failure-patterns.md` 与
  `evidence/runs/TASK-HLD-001/run.md` 于该 merge 的 blob 与实现分支 head
  `be495dd8885b5da6ce164f0bd47af92f6df7f4f3` **逐字一致**。done 不等于 change
  `verified`：`HLD-DURABLE-001` 的最终结论仍需 change 级 verify PR 由维护者确认。）
- Done recheck（在**合入版** `b8f41066e0aa3a8d1343f805524f9c9439ff9c5c` 上重跑，
  非沿用实现 PR 的结论）：
  - 活跃 change 相对链接 = **0**；`changes/archive/**` 类 = **16**（计数与内容零变化）；
  - 新增 blob OID 11 个唯一值，`git cat-file -e` 逐个可解析，0 不可解析；
  - 不动面：`AF-001`…`AF-018` ID 集合完整；H3 = 144 且八字段同序；
    `Fact` 36 / `Inference` 18 / positive 18 / negative 18；`Currency` 18 行；
  - **归档模拟**：chg-2026-006/008/022/025/026/028 六个被引用活跃 change 逐个验证，
    各 **0 条可断项**；
  - `scripts/check-sdd.sh` 0 error / 0 warning / 111 acceptance IDs。
- Provenance 复核边界（**如实记录**）：TASK-BAP-003 凭据分离生效后 Agent 无维护者
  `gh` 凭据，无法读取 #441 的 reviews/mergedBy。本次以 `git` 验证：squash commit
  `b8f41066…` 在 protected `main` 上，两个交付物 blob 与实现 head 逐字一致。
  **"由维护者 APPROVED"未经 Agent 独立验证**，由维护者 review 本状态 PR 时确认。
- Readiness（r1，base = protected `main` `4675971ee132d0b94a7f0780e9987518489974bf`）：
  - **Approval/dependency gate:satisfied。**r1 proposal #437 合入
    `02b27b01246eaed4b230f3a2cfec6a72545c63ff`；approval-only #438 合入
    `4675971ee132d0b94a7f0780e9987518489974bf`，`status: approved` 已在 protected `main` 生效。
    本任务无前序 task；TASK-HLD-002 依赖本任务 done，继续 `blocked`。
  - **Base/input pins。**下表由脚本枚举并于本 base 实测取值（非手抄）。implementation
    开工时必须基于本 readiness 合入后的最新 protected `main` 逐项复核；任一漂移、
    路径删除/重命名或目标 change 在开工前归档，立即停止并重新 readiness。

    ```yaml pins
    - artifact: TASK-HLD-001 readiness audit base
      commit: 4675971ee132d0b94a7f0780e9987518489974bf
    - artifact: CHG-2026-032 propose merge
      commit: 02b27b01246eaed4b230f3a2cfec6a72545c63ff
    - artifact: CHG-2026-032 approval merge
      commit: 4675971ee132d0b94a7f0780e9987518489974bf
    - path: openspec/planning/agent-failure-patterns.md
      blob: f35cd6ad9fa3f283d27a4a8d01b67a7ac584777c
    - path: openspec/changes/chg-2026-006-dayu200-m0b-bringup/tasks.md
      blob: 779ff6ac060ab7ba82ddaf955b65702ec52285db
    - path: openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-REDACTOR-001/run.md
      blob: 172ea48fba64819d0bf0743816323b8da68b6ec3
    - path: openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/tasks.md
      blob: abaee6a12290108f4daeac9f84a3ff6700971433
    - path: openspec/changes/chg-2026-022-hdc-supervisor-observability/proposal.md
      blob: 63fa348e8f08276d17b1655532714d5da3a67482
    - path: openspec/changes/chg-2026-022-hdc-supervisor-observability/review.md
      blob: d03118ab83cbeb278910c08e55573094edbd5169
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/review.md
      blob: 197e4adc47f75444a54eefadf00e58b4681e5202
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md
      blob: 659f99f470cea5f03984de6ea28ce1395e391287
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/run.md
      blob: 0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/verification.md
      blob: f4aea707ded798680aacb7811a4786247a94dac8
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-001/run.md
      blob: f5e51fad2f2a429748126eee27ab61df282c2f23
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/proposal.md
      blob: d7718251c074f3b23bb32f8703c863efc9912245
    - path: openspec/changes/chg-2026-032-handbook-link-durability/proposal.md
      blob: 1b3d49b36a405923921515bf51725dc5066ba1d3
    - path: openspec/changes/chg-2026-032-handbook-link-durability/design.md
      blob: 3ea8dd7f44db5037401f60a5aaeb8d0dfc906130
    - path: openspec/changes/chg-2026-032-handbook-link-durability/verification.md
      blob: ab0abcce77c2c0a573e733ef53a8c97e7d1209df
    - path: openspec/changes/chg-2026-032-handbook-link-durability/acceptance-cases.yaml
      blob: 65f0b651fe3fa7075c8c51720daf37e2b9595730
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/constitution.md
      blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/verification/policy.md
      blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
    ```

  - **待改清单:closed（恰 19 条，落在 11 个目标文件）。**下表为**全部**待改项，
    实现不得多改也不得少改。行号以本 base 的手册为准（改写会使后续行号位移，
    实现时以 `AF` 项 + 目标路径定位，不以行号定位）。

| # | 行 | AF 项 | change | 目标文件（change 目录内相对） | 定位 blob |
| --- | --- | --- | --- | --- | --- |
| L01 | 46 | `AF-001` | `CHG-026` | `evidence/runs/TASK-RKFUI-001/run.md` | `0f24bb2424e4…` |
| L02 | 51 | `AF-001` | `CHG-006` | `tasks.md` | `779ff6ac060a…` |
| L03 | 53 | `AF-001` | `CHG-022` | `proposal.md` | `63fa348e8f08…` |
| L04 | 88 | `AF-001` | `CHG-028` | `proposal.md` | `d7718251c074…` |
| L05 | 105 | `AF-002` | `CHG-022` | `review.md` | `d03118ab83cb…` |
| L06 | 158 | `AF-003` | `CHG-025` | `review.md` | `197e4adc47f7…` |
| L07 | 221 | `AF-004` | `CHG-026` | `evidence/runs/TASK-RKFUI-001/run.md` | `0f24bb2424e4…` |
| L08 | 271 | `AF-005` | `CHG-008` | `evidence/runs/TASK-UD-REDACTOR-001/run.md` | `172ea48fba64…` |
| L09 | 275 | `AF-005` | `CHG-026` | `evidence/runs/TASK-RKFUI-001/run.md` | `0f24bb2424e4…` |
| L10 | 328 | `AF-006` | `CHG-028` | `proposal.md` | `d7718251c074…` |
| L11 | 383 | `AF-007` | `CHG-026` | `evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md` | `659f99f470ce…` |
| L12 | 389 | `AF-007` | `CHG-028` | `evidence/runs/TASK-MECH-001/run.md` | `f5e51fad2f2a…` |
| L13 | 551 | `AF-010` | `CHG-022` | `review.md` | `d03118ab83cb…` |
| L14 | 600 | `AF-011` | `CHG-026` | `verification.md` | `f4aea707ded7…` |
| L15 | 708 | `AF-013` | `CHG-022` | `review.md` | `d03118ab83cb…` |
| L16 | 822 | `AF-015` | `CHG-026` | `evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md` | `659f99f470ce…` |
| L17 | 868 | `AF-016` | `CHG-028` | `evidence/runs/TASK-MECH-001/run.md` | `f5e51fad2f2a…` |
| L18 | 872 | `AF-016` | `CHG-022` | `review.md` | `d03118ab83cb…` |
| L19 | 921 | `AF-017` | `CHG-008` | `tasks.md` | `abaee6a12290…` |

  - **改法:closed。**每条改为与 CHG-2026-029 TASK-AFP-005 同构的耐久形式，保留三项：
    ① change ID（如 `CHG-2026-026`）；② change 目录内的文件路径（含必要的
    `TASK-*`/章节标识）；③ 上表的**完整 40-hex blob OID**。去掉 `](../changes/...)`
    相对链接。链接文字（如 “TASK-RKFUI-001 `run.md`”）可保留为普通文本。
    **禁止改法**：改指向预期的 `changes/archive/<date>-<id>/` 路径；删除事实指向；
    把被引用内容复制进手册；改动任何案例的事实文字。
  - **不动面:binary。**指向 `changes/archive/**` 的 **16 条**链接逐字不动；
    `AF-NNN` ID 集合（`AF-001`…`AF-018`）、taxonomy 归属与两轴划分、八字段契约与
    顺序（H3 = 144）、`Automation status` 取值域、`Fact` 36 / `Inference` 18、
    positive 18 / negative 18、首屏五项声明、各项 `Currency` 行——全部零变化。
  - **OID 取值纪律:binary。**上表 blob 均由 `git rev-parse HEAD:<path>` 实测取得；
    实现时须逐条复取并在 run 中记录取值命令。**禁止由短 hash 补全为 40 位**——该形态
    是 `AF-016` 的已知复发实例（CHG-2026-029 期间发生过，见其 TASK-AFP-005 readiness
    的起草期自纠记录）。
  - **Verification/evidence gate:binary。**implementation/evidence PR 必须交付手册改动、
    本任务 run 与 `tasks.md` evidence 引用，但不得翻 `ready→done`；run 至少记录：
    19 条逐条“原链接 → 改后文本 → 定位 OID → 取值命令”、活跃 change 相对链接计数
    → 0、archive 类 16 条计数与内容零变化、每个新增 OID 经 `git cat-file -e` 实测
    可解析、上述不动面逐项零变化的实测、归档模拟（对 6 个被引用活跃 change 逐个
    验证其目录移入 archive 后手册无可断项）、`openspec/templates/**` 与
    `changes/archive/**` diff 为 0、`scripts/check-sdd.sh` 0/0/111 与
    `git diff --check` PASS。
  - **Environment/concurrency gate:satisfied。**纯 host-side document task，零硬件、
    零 device/network/effect dispatch。手册面并发：本 change 是当前唯一持
    `openspec/planning/agent-failure-patterns.md` 授权的 change（CHG-2026-029 已
    archived，其任务不再可开工）。若实现期间出现同路径 PR、目标 change 归档或
    canonical conflict，任务立即回到 `blocked`。
  - **Review boundary。**本 readiness PR 只修改本文件的 HLD-001 本节；零手册改动、
    零 implementation、零 evidence。implementation/evidence 与后续 `ready→done` 各自
    使用独立 PR；本 readiness merge 不构成 `HLD-DURABLE-001` PASS 或 change `verified`。
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `HLD-DURABLE-001`
- Depends on:change approval、independent readiness
- Applicable failure patterns:`AF-006`（archive 前引用扫描与断链即暂缓——本 change
  正是该模式的一次前置修复）、`AF-015`（同模式须全量处置而非只改发现点）、
  `AF-016`（逐条改写须以实测取值为准，不得凭记忆补全 OID）
- Production reachability:not applicable；纯文档索引，零产品 effect、零 dispatch
- Trusted fact sources:`git grep` 与链接解析对 protected `main` 的实测结果、被引用
  文件的仓内 bytes 与 `git rev-parse` 取得的完整 OID；**不以本 change 的 proposal
  转述、既往 run 的历史计数或会话记忆替代实测**
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-032-handbook-link-durability/evidence/**`、
  `openspec/changes/chg-2026-032-handbook-link-durability/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/changes/archive/**`、
  `openspec/templates/**`、其他 change 目录、产品 source/tests/scripts/workflows
- Risk:low（风险是改写时丢失事实指向、误改 archive 类链接、或 OID 凭记忆生成）
- Hardware required:no

### Deliverables

- 手册中指向**活跃 change** 的相对链接归零（readiness 钉定的逐条清单全数处置）；
- 每条改后仍含可唯一定位的事实指向：change ID + 文件名 + 必要的章节/任务标识 +
  完整 40-hex OID；
- 指向 `changes/archive/**` 的链接**逐字不动**；
- run 记录逐条列出：原链接 → 改后文本 → 用于定位的 OID → 该 OID 的实测来源命令。

### Verification

- `HLD-DURABLE-001` document review；
- 二值门：活跃 change 相对链接计数 → 0；archive 类链接计数与内容零变化；
  每条改后文本含完整 40-hex OID 且该 OID 在 protected `main` ancestry 中可解析；
- 不动面：`AF-NNN` ID 集合、taxonomy 归属与两轴划分、八字段契约与顺序、
  `Automation status` 取值域、`Fact`/`Inference` 标注、positive/negative 计数
  全部零变化；
- 归档模拟：对每个被引用的活跃 change，其目录若移入 `changes/archive/<date>-<id>/`，
  手册中不存在可断项；
- `scripts/check-sdd.sh` 与 `git diff --check`；archive 与 templates diff 为零。

### Evidence（candidate；不构成状态翻转）

- implementation + evidence run:
  [`evidence/runs/TASK-HLD-001/run.md`](evidence/runs/TASK-HLD-001/run.md)
  与逐条对照表
  [`evidence/runs/TASK-HLD-001/link-inventory.md`](evidence/runs/TASK-HLD-001/link-inventory.md)
  （2026-07-23，base `a7ee3f88634972cea4f3bb6622d2f6dab6ea6e06`）。
- 二值门实测：开工前 carrier 23/23 无漂移、六个目标 change 均未归档；活跃 change
  相对链接 19 → **0**；archive 类 16 条计数与内容零变化；新增 11 个唯一 blob OID
  全部可解析；不动面（ID 集合、H3=144 八字段同序、`Automation status` 取值域、
  `Fact` 36 / `Inference` 18、positive/negative 各 18、`Currency` 18 行）逐项零变化；
  **六个活跃 change 的归档模拟各 0 条可断项**；模板与 archive diff = 0；
  check-sdd 0/0/111。
- 任务状态保持 `ready`；`HLD-DURABLE-001` 的 PASS 结论待维护者在独立 `ready→done`
  PR 中确认。

### Notes / handoff

- 逐条 OID 一律以 `git rev-parse` / `git log` 实测取得并在 run 中记录取值命令；
  **禁止由短 hash 补全为 40 位**（`AF-016` 的已知复发形态，CHG-2026-029 期间发生过）；
- 实现/evidence PR 不翻 task 状态；`ready→done` 使用独立 PR。

## TASK-HLD-002 — 在手册内登记引用约定

- Status:ready（2026-07-23 D1 readiness r1；仅在维护者 review/merge 本独立 PR 后生效。
  三前置全部闭合：① approval-only #438；② TASK-HLD-001 done #442 合入
  `73b46b684b27eda23cfbaad06c5b707bff39e2cc`；③ 本 readiness 钉定手册 blob、拟增文本的精确位置与措辞边界。
  **维护者 merge 本 readiness 亦构成对下方“范围扩展”一节的接受**；merge 前不得开
  implementation/evidence PR）
- Readiness（r1，base = protected `main` `73b46b684b27eda23cfbaad06c5b707bff39e2cc`）：
  - **Approval/dependency gate:satisfied。**propose #437 合入
    `02b27b01246eaed4b230f3a2cfec6a72545c63ff`；approval-only #438 合入
    `4675971ee132d0b94a7f0780e9987518489974bf`；TASK-HLD-001 实现 #441 合入
    `b8f41066e0aa3a8d1343f805524f9c9439ff9c5c`、done #442 合入 `73b46b684b27eda23cfbaad06c5b707bff39e2cc`。
    本任务为本 change 最后一个任务。
  - **Base/input pins。**

    ```yaml pins
    - artifact: TASK-HLD-002 readiness audit base
      commit: 73b46b684b27eda23cfbaad06c5b707bff39e2cc
    - artifact: CHG-2026-032 approval merge
      commit: 4675971ee132d0b94a7f0780e9987518489974bf
    - artifact: TASK-HLD-001 done status merge
      commit: 73b46b684b27eda23cfbaad06c5b707bff39e2cc
    - path: openspec/planning/agent-failure-patterns.md
      blob: 9fae009c83fc9d560a0eaafa8a759cc471de0988
    - path: openspec/changes/chg-2026-032-handbook-link-durability/proposal.md
      blob: 1b3d49b36a405923921515bf51725dc5066ba1d3
    - path: openspec/changes/chg-2026-032-handbook-link-durability/design.md
      blob: 3ea8dd7f44db5037401f60a5aaeb8d0dfc906130
    - path: openspec/changes/chg-2026-032-handbook-link-durability/verification.md
      blob: ab0abcce77c2c0a573e733ef53a8c97e7d1209df
    - path: openspec/changes/chg-2026-032-handbook-link-durability/acceptance-cases.yaml
      blob: 65f0b651fe3fa7075c8c51720daf37e2b9595730
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/constitution.md
      blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/verification/policy.md
      blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
    ```

  - **首屏现状:实测。**手册首屏为 **4 个**引用块（非此前登记的“五项”，见下方勘误）：
    ① `**本文件不是规则源。**`（L3）；② `**冲突处置。**`（L7）；
    ③ `**只链接，不复制。**`（L14）；④ `**archive 只读。**`（L19）。
  - **拟增文本:closed（恰一条）。**在 ④ `**archive 只读。**` 块之后、正文首段之前
    插入**恰一个**新引用块 `**引用形式。**`，内容须含且仅含三点：① 指向**活跃
    change** 时使用耐久形式（change ID + change 目录内路径 + 完整 40-hex blob OID），
    不使用相对路径；② 指向已在 `changes/archive/**` 的目标可保留相对路径（归档目录
    不再移动）；③ **该约定只约束本手册自身的后续编辑**，不创造 normative 规则，不
    改变 `AGENTS.md`、enforcement、模板或任何其他文档的要求。措辞禁止出现
    `SHALL`/`MUST` 及对其他文档的强制表述。
  - **范围扩展:需维护者接受（merge 本 readiness 即接受）。**除“增加一条”外，本任务
    另需**修正一处因 TASK-HLD-001 而陈旧的既有表述**：首屏块 ③ `**只链接，不复制。**`
    现文为“每条案例只给出仓内相对路径与完整 40-hex Git OID”。HLD-001 合入后，
    **19 条活跃 change 引用已不再是相对路径**，该句与手册实际内容矛盾。
    - **为何超出 approval 字面**：#438 的封闭范围写的是“只在手册首屏既有边界声明中
      **增加**一条非规范引用约定”，未授权修改既有声明句。
    - **为何仍建议纳入**：不改则手册首屏自述与正文形式相互矛盾，且该矛盾正由本
      change 的 HLD-001 造成；为一句话另立任务的成本高于收益。
    - **边界**：只改该句中描述**引用形式**的部分（相对路径 → 区分活跃/已归档两种
      形式）；“不复制 raw evidence、hash 表、transcript、secret、真实设备标识、
      用户绝对路径或大段日志”及其 `POL-PRIVACY-001`/`POL-ARTIFACT-001` 两处引用
      **逐字保留**。
    - 若维护者不接受该扩展，请在 review 中指出；实现将退回“只增加一条”，并把块 ③
      的陈旧表述作为已知缺陷指针留待独立载体处理。
  - **不动面:binary。**首屏其余 3 块（①②④）逐字不动；`AF-NNN` ID 集合
    （`AF-001`…`AF-018`）、taxonomy 归属与两轴划分、八字段契约与顺序（H3 = 144）、
    `Automation status` 取值域、`Fact` 36 / `Inference` 18、positive 18 /
    negative 18、各项 `Currency` 行、正文全部 19 条耐久引用与 16 条 archive 类
    链接——全部零变化。
  - **勘误（dated，2026-07-23）。**TASK-HLD-001 readiness 的不动面条款写作“首屏
    **五项**声明”，实测为 **4 块**。该数字未被 HLD-001 的实现或 done recheck 用作
    判定依据（其校验的是 ID 集合、八字段契约、计数与链接等具体门），故**未产生
    错误结论**；但登记值本身错误，属 `AF-016`（凭印象写计数）。此处在事实原位
    更正，不改写 HLD-001 已合入的记录。
  - **Verification/evidence gate:binary。**implementation/evidence PR 必须交付手册
    改动、本任务 run 与 `tasks.md` evidence 引用，但不得翻 `ready→done`；run 至少
    记录：首屏块数 4 → 5 且新增块恰为 `**引用形式。**`；块 ③ 的改动逐字对照
    （改前/改后，并证明隐私条款与两处 `POL-*` 引用逐字保留）；shadow-spec 扫描
    （新增 `SHALL`/`MUST` = 0、对其他文档的强制表述 = 0、自动批准/ready/done
    语义 = 0）；不动面逐项零变化的实测；活跃 change 相对链接仍为 0、archive 类仍
    为 16；`openspec/templates/**` 与 `changes/archive/**` diff 为 0；
    `scripts/check-sdd.sh` 0/0/111 与 `git diff --check` PASS。
  - **Environment/concurrency gate:satisfied。**纯 host-side document task，零硬件、
    零 device/network/effect dispatch；本 change 是当前唯一持该手册授权者。若出现
    同路径 PR 或 canonical conflict，任务立即回到 `blocked`。
  - **Review boundary。**本 readiness PR 只修改本文件的 HLD-002 本节；零手册改动、
    零 implementation、零 evidence。implementation/evidence 与后续 `ready→done` 各自
    使用独立 PR；本 readiness merge 不构成 `HLD-CONVENTION-001` PASS 或 change
    `verified`。
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `HLD-CONVENTION-001`
- Depends on:change approval、TASK-HLD-001 done、independent readiness
- Applicable failure patterns:`AF-009`（避免把一条编辑约定写成新的 normative 规则）
- Production reachability:not applicable；纯文档，零产品 effect
- Trusted fact sources:TASK-HLD-001 已合入的手册 bytes；约定文本只描述本手册自身的
  编辑惯例，不引用外部授权
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-032-handbook-link-durability/evidence/**`、
  `openspec/changes/chg-2026-032-handbook-link-durability/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:同 TASK-HLD-001
- Risk:low（风险是措辞被误读为对其他文档的强制要求）
- Hardware required:no

### Deliverables

- 手册首屏既有边界声明中增加一条**非规范**引用约定：活跃 change 用耐久形式
  （change ID + 完整 OID），已在 `archive/` 的目标可用相对路径；
- 措辞须明确该约定**只约束本手册自身的后续编辑**，不创造 normative 规则、
  不改变 `AGENTS.md`/enforcement/模板对其他文档的要求。

### Verification

- `HLD-CONVENTION-001` document review；
- shadow-spec 扫描：新增 normative `SHALL`/`MUST` = 0；对其他文档的强制表述 = 0；
  自动批准/ready/done 语义 = 0；
- 不动面同 TASK-HLD-001（ID 集合、八字段契约、取值域、标注与计数零变化）；
- `scripts/check-sdd.sh` 与 `git diff --check`。

### Evidence（candidate；不构成状态翻转）

- implementation + evidence run:
  [`evidence/runs/TASK-HLD-002/run.md`](evidence/runs/TASK-HLD-002/run.md)
  （2026-07-23，base `5f34a2aa376bd3677b69ba14410f265f1a29aaf7`）。
- 二值门实测：开工前 carrier 12/12 无漂移；首屏块数 4 → **5**，新增块恰为
  `**引用形式。**`；块 ③ 的隐私条款与两处 `POL-*` 引用逐字保留；首屏其余 3 块、
  `AF-NNN` ID 集合、H3 = 144 八字段同序、`Fact` 36 / `Inference` 18、
  positive/negative 各 18、`Currency` 18 行、活跃相对链接 0 / archive 类 16 /
  11 个耐久 blob 可解析——全部零变化；shadow-spec 三项扫描均为 0；手册 diff
  2 个 hunk；模板与 archive diff = 0；check-sdd 0/0/111。
- 任务状态保持 `ready`；`HLD-CONVENTION-001` 的 PASS 结论待维护者在独立
  `ready→done` PR 中确认。

### Notes / handoff

- 本任务只加约定文本，不再改任何既有链接；
- 实现/evidence 与状态 PR 分离。

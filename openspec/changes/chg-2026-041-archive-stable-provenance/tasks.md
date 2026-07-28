# CHG-2026-041 Tasks

> 两任务 host-only、零设备、零凭据。ASP-002 需 `scripts/**` 授权面，可在
> approval 时被裁掉而不影响 ASP-001。`Decision-Grade` 行由维护者亲笔
> （#577 载体先例），本文件不代写。

## TASK-ASP-001 — 定义 archive-stable provenance 并完成迁移与哈希级联

- Status:ready（r2 corrective readiness；r1 的迁移面勘察不完整且其 AC 与
  自身 scope 自相矛盾，实现中实测发现后停手（见 Readiness（r2）Survey gap）。
  r2 只做**范围与判据的更正**，不改形态设计；r1 已完成的迁移成果为严格子集，
  可复用。原 r1 授权文字如下续：
- Historical Status:ready（r1 implementation readiness；仅在维护者对本独立 readiness PR
  exact head review/merge 后生效。只授权一个实现交付：按下方契约把 15 处
  仓内 change 路径迁移为 archive-stable 形态，并在**同一 PR** 内完成哈希
  级联与契约测试形态更新；载体 = 常规会话 agent/* PR。不授权：任何 registry
  语义字段变更、`scripts/**`（属 ASP-002）、`Sources/**`/`Package.swift`/
  App/xcodeproj/Core 面、chg-2026-024 的 archive PR、`Decision-Grade` 代写。）
- Historical Status:blocked（前置：① approval #671；② 本 r1。）
- Readiness（r1；audit base = protected `main`
  `5427fbccd0cd83d95d4d8dde029841763b0f4204`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件的本任务
    段；生效条件 = `lvye` 对 exact head APPROVED、checks terminal success、
    `mergedBy=lvye`、squash merge 进 protected main。
  - **Dependency gate:closed。**propose #669、approval #671 均已合入且为
    audit base 祖先；ASP-002 依赖本任务 done，顺序不可颠倒（守卫先落地会
    立刻把仓打红）。
  - **Source pins:closed（audit base 实测 blob，13 项）。**
    `readonly-probes.yaml` **与** `Probes/1.0.0/registry.yaml`
    `99e8cc3d9929f9502a3e978a53cd56ad285d2aad`（**同 blob** = 正副本字节一致，
    先例 #305）；`device-observation-probes.yaml` **与**
    `Probes/DeviceObservation/1.0.0/registry.yaml`
    `1130ca663f686d9f202f53ceb8814320ebc862bd`（**同 blob**）；
    `INTEGRATION-PROFILES.lock.yaml`
    `129abc6216593d73e401167181f61924addf602f`；
    `Probes/1.0.0/resources.json` `5796449dee4a7166746d9b0d7245d26bd2b21aae`；
    `Probes/DeviceObservation/1.0.0/resources.json`
    `72618f79e12dcdc3ecd6c09537a28be2bfa8572e`；
    `HDCProbeRegistryContractTests.swift`
    `6f83b54e4d01148005a7348786c886cf4b7c7ade`；
    `HDCDeviceObservationRegistryContractTests.swift`
    `a7264626a6a93e06008ece9ec73fae32343c0291`；四个 receipt =
    `122e4e06…`（selected-device-authorization-binding）/ `d1bc481e…`
    （server-identity-generation）/ `9cdb8b6e…`（subserver-capability）/
    `82b873ef…`（key-access-diagnostics）。任一漂移即停并重钉。
- Readiness（r2；audit base = protected `main`
  `6383f5b`… 即 r1 #674 合入后的 head；r1 的 13 项 source pin 于此 base
  复核 **13/13 零漂移**，形态设计、解析规则、正副本字节一致门、测试基线与
  非 `/private/tmp` 验证要求全部原文有效）：
  - **Survey gap（实现中实测，2026-07-28）。**r1 把迁移面钉为「恰 15 处 /
    9 文件」，同时把 `ASP-SHAPE-001` 写成「迁移后 `openspec/integrations/**`
    与 `Fixtures/**` 下字面量为 0」。**两者不可同时成立**：全仓实测另有
    **4 处 / 2 文件**同类引用，且都在 `openspec/integrations/**` 下——
    `openharmony/trace-probes/1.0.0/registry.yaml` 的
    `provenance.redactedManifests`（3 条**裸字符串数组**，指向已归档
    chg-2026-021）与 `rockchip/loader-transition/1.0.0/registry.yaml` 的
    `evidencePath`（1 条，指向未归档 chg-2026-026）。
    **勘察为何漏**：r1 起草时用 `"source[A-Za-z]*": "openspec/changes/`
    模式扫描，该模式只认「`source*` 键 + 字符串值」，**看不见**裸字符串
    数组元素，也看不见键名不叫 `source*` 的 `evidencePath`。正确形态是
    直接扫字面量 `openspec/changes/` 再逐一归类。
  - **为何不并入 ASP-001（实测约束，非偏好）。**这 4 处的迁移**必须改
    `scripts/**`**：`scripts/trace_capture/validate_registry.py:196` 读
    `provenance.redactedManifests`；
    `scripts/rockchip_loader_transition_probe/probe.py:63,459`
    读写 `evidencePath`（并有常量 `SOURCE_EVIDENCE_RELATIVE_PATH`），
    其 `test_probe.py:317` 亦以该键构造负例。而 `scripts/**` 是 ASP-001 的
    **Forbidden path**、恰是 ASP-002 持有的授权面。把它们并入 ASP-001 会
    取消维护者在 approval 时保留的「ASP-002 可单独裁掉」选项。
  - **r2 的更正（三项，形态设计零变化）。**
    ① `ASP-SHAPE-001` 的零字面量断言**限定到 ASP-001 的 9 个具名文件**
    （verification.md 与 acceptance-cases 同步更正）；
    ② 余下 4 处 / 2 文件**显式移交 TASK-ASP-002**，其 In scope 相应扩列；
    ③ 由此，**ASP-002 的守卫必须「先迁移后设卡」**：在同一任务内先把这
    4 处迁完再启用仓级守卫，否则守卫落地即把仓打红（该顺序约束写入
    ASP-002）。
  - **迁移面:binary（r2 限定为 ASP-001 的 9 文件）。**`openspec/changes/`
    字面量**恰 15 处**：`readonly-probes.yaml` 4、
    `Probes/1.0.0/registry.yaml` 4、`device-observation-probes.yaml` 1、
    `Probes/DeviceObservation/1.0.0/registry.yaml` 1、四个 receipt 各 1、
    `HDCProbeRegistryContractTests.swift` 1（第 280 行的
    `hasPrefix("openspec/changes/")` 形态断言）。迁移后该字面量**在这 9 个
    文件中必须为 0**；`trace-probes` 与 `rockchip/loader-transition` 的 4 处
    按 r2 移交 ASP-002，不在本任务判据内。实现若在这 9 文件外再发现同类
    引用，停并重 readiness。
  - **两个 registry 的 provenance 形态不同，分别规定（实测，勿假设对称）：**
    - `readonly-probes.yaml`（4 entry）现有
      `{evidenceClass, sourcePath, sourceSHA256, acceptedBy}`；迁移为
      `{evidenceClass, sourceChange, sourceEvidence, sourceSHA256, acceptedBy}`。
      **`sourceSHA256` 四条逐字不变**（三个 distinct 值 `6bb63426…`/
      `7949d8a2…`×2/`a06cc989…`）——这是「只改引用未改内容」的机器证明。
    - `device-observation-probes.yaml`（1 entry）现有
      `{evidenceClass, sourcePath, sessions[{id,acceptedBy,mergeOID}],
      rawLocation, repositoryGoldenFixture}`，**无 `sourceSHA256`**；迁移为
      以 `sourceChange` + `sourceEvidence` 取代 `sourcePath`，其余字段
      逐字保留（其内容锚是 lock/resources 的哈希与两个 mergeOID）。
    - 四个 receipt 的 `source.path` 同步改形，并保持与其 entry 的交叉一致
      （契约测试第 419 行的比对必须继续成立，只换字段名/形态）。
  - **正副本字节一致必须保持。**迁移后
    `readonly-probes.yaml` 与 `Probes/1.0.0/registry.yaml` **仍须同 blob**，
    `device-observation-probes.yaml` 与其副本亦然（二值门：`git rev-parse`
    两侧相等）。这同时是对 CHG-2026-024 记录的「无自动化守卫」遗留的部分
    缓解——但**不**声称已闭合该遗留（其自动化属 ASP-002 面的可选项）。
  - **解析规则（形态定义的一部分）。**change 目录 =
    `openspec/changes/<id 小写>/` 或 `openspec/changes/archive/*-<id 小写>/`
    **恰一处**存在；0 或 2+ 为 loud fail。与
    `scripts/host_loop/test_support.py` 的 active-or-archive 解析同构（该
    文件属 ASP-002/其他授权面，本任务**不**修改它，只复用其规则）。
  - **两分支各须实测。**现存两个来源 change 恰好一活一档：
    `CHG-2026-015-hdc-readonly-probe-registration`（**已归档**于
    `archive/2026-07-22-…`）与 `CHG-2026-024-hdc-device-snapshot-registration`
    （**未归档**）。契约测试须对**两者各**断言解析成功且恰一处命中；只测
    一边不满足 `ASP-SHAPE-001`。
  - **测试基线。**Swift 全量 = **413 tests / 1 skipped / 0 failures**
    （2026-07-27 于 `ffca996f` 实测；已机器核验 `ffca996f..origin/main` 在
    `Packages`/`ArkDeckApp`/`ArkDeck.xcodeproj` 下 **0 文件差异**，故对本
    audit base 有效）。实现后 = 413 + 新增数 / 1 skipped / **0 failures**。
    **必须在非 `/private/tmp` 检出复测**——`/private/tmp` 的已知路径改写会
    使 `HDCGoldenResourceContractTests` 与 `HDCProbeRegistryContractTests`
    双双假红并掩盖真实信号（CHG-2026-024 实现期实证）。
    `check-sdd` 保持 **0/0/111**。
  - **迁移方式。**由**可重跑脚本**完成（草稿入本 change `evidence/**`，
    **不**入 `scripts/**`），禁止逐文件手工编辑；evidence 须给出迁移前后
    每文件 blob 对照与 `sourceSHA256` 逐条相等的证明。
  - **Concurrency/absence:closed at drafting（2026-07-28）。**remote
    `agent/*asp*` 分支 = 0（推送前实测）。**主 checkout 为共享工作副本**
    （近期曾被另一会话切至其他分支），实现须在独立 worktree 内进行且 commit
    前核 `git branch --show-current`。
  - **Grade 注记**：`Decision-Grade` 由维护者亲笔（#577 载体先例）。本契约
    已机器可判定（15 处精确计数 + 13 blob pin + 二值哈希门），符合 D0 三
    条件；但本任务改动共享 registry 与契约测试，载体为常规会话 PR。
- Platform:macos（纯数据与测试面；零 runtime、零设备）
- Requirements/AC:change-local `ASP-SHAPE-001`、`ASP-CASCADE-001`
- Depends on:none
- In scope:
  - 形态定义：`provenance` 以 `sourceChange`（change id，如
    `CHG-2026-024-hdc-device-snapshot-registration`）+ `sourceEvidence`
    （**相对 change 目录**的路径，如 `evidence/runs/TASK-I24-001/run.md`）
    取代 `sourcePath`；`sourceSHA256`、`acceptedBy`、既有 merge OID 字段
    保留原值；解析规则 = 目录在 `openspec/changes/<id 小写>/` 或
    `openspec/changes/archive/*-<id 小写>/` **恰一处**存在，0 或 2+ 均为
    loud fail（与 `scripts/host_loop/test_support.py` 的 active-or-archive
    解析同构）。
  - 迁移面（**恰这 11 个文件**，一个 PR 内一致）：
    `openspec/integrations/openharmony/readonly-probes.yaml`（4 处）、
    `openspec/integrations/openharmony/device-observation-probes.yaml`（1 处）、
    两者的 bundled 副本
    `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/registry.yaml`
    与 `…/Probes/DeviceObservation/1.0.0/registry.yaml`、
    `…/Probes/1.0.0/receipts/*.json`（4 个，`source.path` 同步改形）、
    `…/Probes/1.0.0/resources.json` 与
    `…/Probes/DeviceObservation/1.0.0/resources.json`（哈希级联）、
    `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`（相关 SHA-256）、
    `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCProbeRegistryContractTests.swift`
    （第 280 行的 `hasPrefix("openspec/changes/")` 形态断言改为新形态断言；
    第 419 行 receipt↔entry 交叉比对同步改字段）。
  - 迁移由**可重跑脚本**完成（草稿置于 evidence，不入 `scripts/**`），
    禁止手工逐文件编辑。
- Out of scope:任何 registry 的语义字段（family/argv/semanticMappings/
  authority/timeout/cancellation/effect/identity）；`trace-probes` 与
  `rockchip` registry（实测无 `sourcePath`）；`Sources/**`、`Package.swift`、
  App/xcodeproj、Core/specs/contracts/baselines；chg-2026-024 的 archive PR；
  `scripts/**`（属 ASP-002）。
- Allowed paths:
  - `openspec/integrations/openharmony/readonly-probes.yaml`
  - `openspec/integrations/openharmony/device-observation-probes.yaml`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCProbeRegistryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationRegistryContractTests.swift`
  - 本 change `evidence/**`
  - 本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/**`、`Packages/ArkDeckKit/Sources/**`、
  `Packages/ArkDeckKit/Package.swift`、`ArkDeckApp/**`、`ArkDeck.xcodeproj/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`、
  `openspec/changes/archive/**`、`.github/**`、其他 change。
- Risk:low-medium（语义零变更；风险集中在哈希级联的完整性，由 CI fail-closed
  兜底；回退 = revert 单 PR）。
- Hardware required:no

### Deliverables

- 迁移后的两个 canonical registry 与两个 bundled 副本（`sourceSHA256`
  **逐项保持原值**）；
- 四个 receipt JSON 的 `source` 形态同步；
- 两个 pack `resources.json` 与 lock 的 SHA-256 级联更新；
- `HDCProbeRegistryContractTests` 的形态断言更新（**只改形态,不放宽强度**）；
- evidence run：迁移脚本、迁移前后每文件 blob 对照、`sourceSHA256` 不变的
  逐项证明、全量 suite 与 `check-sdd` 前后计数。

### Verification

- `ASP-SHAPE-001`：迁移后全部 registry/resource/receipt **零** `openspec/changes/`
  字面量；每条 provenance 具备 `sourceChange` + `sourceEvidence` +
  `sourceSHA256`；active-or-archive 解析对现存两个来源 change（chg-015 已归档、
  chg-024 未归档）**各**解析成功且恰一处命中——**一活一档两分支都必须实测**。
- `ASP-CASCADE-001`：lock、两个 `resources.json` 与契约测试的哈希断言全部
  一致；Swift 全量在**非 `/private/tmp`** 检出零失败；`check-sdd` 0/0/111；
  `sourceSHA256` 逐项与迁移前相等（= 只改引用未改内容的机器证明）。

## TASK-ASP-002 — 机械守卫：registry 内禁止仓内 change 路径

- Status:blocked（前置：① 本 change approval-only PR merge；② TASK-ASP-001
  done——守卫先于迁移落地会立刻把仓打红；③ 独立 readiness。）
- Platform:macos
- Requirements/AC:change-local `ASP-GUARD-001`
- Depends on:`TASK-ASP-001`
- In scope（r2 扩列）:
  - **先迁移**（ASP-001 移交的 4 处 / 2 文件，因其消费方在 `scripts/**`）：
    `openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml` 的
    `provenance.redactedManifests`（3 条裸字符串）与
    `openspec/integrations/rockchip/loader-transition/1.0.0/registry.yaml` 的
    `evidencePath`（1 条），迁为与 ASP-001 同族的 change-relative 形态；
    同步其消费方 `scripts/trace_capture/validate_registry.py`、
    `scripts/rockchip_loader_transition_probe/probe.py` 与
    `scripts/rockchip_loader_transition_probe/test_probe.py`，以及 lock 中
    trace-probes 的 SHA-256。
  - **后设卡**：在既有 SDD 守卫面新增一条检查——`openspec/integrations/**`
    与 `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/**` 下的
    registry/resource/receipt 文件内出现 `openspec/changes/` 字面量即 fail，
    报告文件与行；配**反证**（撤销该检查后以一处人造违例证明其必红）。
  - **顺序是二值约束**：守卫先于迁移启用会立刻把仓打红，二者必须同 PR 内
    先迁后卡。
- Out of scope:守卫之外的任何行为；registry 数据（属 ASP-001）；
  `check_pr_paths` / host_loop 面。
- Allowed paths（r2 扩列）:`scripts/check_sdd.py`、`scripts/test_check_sdd.py`、
  `scripts/trace_capture/validate_registry.py`、
  `scripts/rockchip_loader_transition_probe/probe.py`、
  `scripts/rockchip_loader_transition_probe/test_probe.py`、
  `openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml`、
  `openspec/integrations/rockchip/loader-transition/1.0.0/registry.yaml`、
  `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`、
  本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/` 其余文件、`openspec/integrations/` 其余文件、
  `Packages/**`、`.github/**`、其他 change。
- Risk:low（只加一条 fail-closed 检查；回退 = revert）。
- Hardware required:no

### Deliverables

- `check_sdd` 新检查 + 单元测试（正例：现状全绿；负例：人造违例必红）；
- evidence run：`check-sdd` 前后计数、反证记录。

### Verification

- `ASP-GUARD-001`（r2）：**先迁移**——`trace-probes` 与
  `loader-transition` 的 4 处迁完且其 `scripts/**` 消费方同步通过各自测试；
  **后设卡**——全仓 registry/resource/receipt 面 `openspec/changes/` 字面量
  为 0，仓全绿；人造违例 → `check-sdd` 报 error 并指名文件与行；撤销检查后
  该违例不再被拦（反证）。`check-sdd` acceptance ID 计数保持 111。

### Notes / handoff

维护者若在 approval 时决定把 CHG-2026-024 evidence 记录的另一处遗留
（canonical registry ↔ bundled 副本字节一致守卫）一并纳入，本任务
Allowed paths 与 AC 需在 readiness 前经 change revision 扩列；本文件不预先
扩张。

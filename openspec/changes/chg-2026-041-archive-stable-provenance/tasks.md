# CHG-2026-041 Tasks

> 两任务 host-only、零设备、零凭据。ASP-002 需 `scripts/**` 授权面，可在
> approval 时被裁掉而不影响 ASP-001。`Decision-Grade` 行由维护者亲笔
> （#577 载体先例），本文件不代写。

## TASK-ASP-001 — 定义 archive-stable provenance 并完成迁移与哈希级联

- Status:done（2026-07-28 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。实现载体 = #680 merge
  `fc1f453bf73b3cb1a5bb605ce8ba71300d82e8e4`：device-observation registry 及其
  bundled 副本的 `provenance.sourcePath` 迁为 `sourceChange` +
  `sourceEvidence`，并同步 pack manifest、lock 三条、两个 profile 的哈希引用；
  契约测试新增两条形态断言（迁移前该测试完全不解码 `provenance`，不补即
  无守卫），两项变异全杀（回退仓内路径 3 红、删 `sourceChange` 11 红）。
  flip base `fc1f453b…` recheck：(a) 链 #669 `38d891cd`、#671 `e6acbca5`、
  r1 #674 `6383f5b9`、r2 #675 `fd478664`、r3 #677 `16c22fae`、实现 #680
  `fc1f453b` 六 merge 全为 ancestors；(b) device-observation 一对
  `openspec/changes/` 字面量 = **0**、正副本仍同哈希
  `79814e45901ab7e4…`、`check-sdd` 0/0/111；实现期于**非 `/private/tmp`**
  检出实测 Swift **415 / 1 skipped / 0 failures**（413 + 新增 2）；
  (c) evidence = `evidence/runs/TASK-ASP-001/run.md` 在树；(d) 本 flip
  单文件；(e) 不声称：change 级 `verified` 为下一独立 PR；
  **CHG-2026-024 的归档死结自此解除**，其 archive 由独立 PR 走。
  移出面如实在案：`readonly-probes.yaml` + 副本 + 4 receipt 需 `Sources/**`
  （产品运行时 pin），trace/rockchip 4 处归 TASK-ASP-002。）
- Historical Status:ready（r3 = #677 merge
  `16c22fae`…；r1 #674 `6383f5b9`、r2 #675 `fd478664` 的条款除被 r3 显式
  窄化者外全程有效。原 r3 Status 正文如下作历史保留。）
- Historical Status:ready（r3 corrective readiness；r2 之后实现继续，实测又撞上**产品
  运行时 pin**：`readonly-probes.yaml` 的 SHA-256 被
  `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift`
  钉死并由 `HDCProduction.swift` 消费，而 `Sources/**` 是本 change 全局
  Out of scope。故 r3 把 ASP-001 **窄化到 device-observation 一对**——它恰是
  解开 CHG-2026-024 归档所需的全部，且实测**零产品消费方**。原 r2 文字如下续：
- Historical Status:ready（r2 corrective readiness；r1 的迁移面勘察不完整且其 AC 与
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
- Readiness（r3；audit base = protected `main`
  `fd47866`… 即 r2 #675 合入后的 head。r1 的形态设计、解析规则、正副本字节
  一致门、非 `/private/tmp` 验证要求原文有效；r2 的移交条款保留）：
  - **Production-pin discovery（实现中实测，2026-07-28）。**迁移
    `readonly-probes.yaml` 会改变其字节 → 打破三处**产品源码**常量：
    `HDCReadOnlyProbeRegistry.registrySHA256` / `.resourceManifestSHA256` /
    `.controlVectorSHA256`（`Sources/ArkDeckOpenHarmony/`，由
    `HDCProduction.swift` 消费），并连带打红 `HDCSupervisorContractTests`
    （亦不在授权内）。实测失败面 = 8 assertion / 3 test。
    **本 change 的 proposal 把风险描述为「纯数据与测试面，零 runtime 面」——
    该描述对 readonly-probes 不成立**，其迁移是产品改动而非文档改动。
  - **r3 窄化（唯一变化）。**ASP-001 的迁移面 = **device-observation 一对，
    恰 2 处字面量**：`openspec/integrations/openharmony/device-observation-probes.yaml`
    与其 bundled 副本。**实测其零产品消费方**（`Sources/**` 全无引用；
    唯一同名命中是不相关的 `RockchipDeviceObservation` 类型）。
  - **完整消费面（本次穷举，前三轮返工皆因少看一层）。**迁移该 registry 触及
    且**仅**触及：① canonical registry；② bundled 副本（须仍字节一致）；
    ③ `Fixtures/HDC/Probes/DeviceObservation/1.0.0/resources.json` 的
    `registryCopy` 哈希；④ `INTEGRATION-PROFILES.lock.yaml` 两条 SHA-256；
    ⑤ **`openspec/integrations/openharmony/profile.md`**（引用该哈希）；
    ⑥ **`openspec/platforms/macos/profile.md`**（引用该哈希）；
    ⑦ `HDCDeviceObservationRegistryContractTests.swift`（须**新增**新形态
    断言——该测试当前**完全不解码 `provenance`**，实测 `grep -c provenance`
    = 0，故迁移不会被它发现；不补断言等于无守卫）。⑤⑥ 为 r3 新增授权。
  - **移交（不在 ASP-001）。**`readonly-probes.yaml` + 其副本 + 4 个 receipt
    + `HDCProbeRegistryContractTests` 形态断言 + `HDCSupervisorContractTests`
    + `Sources/.../HDCReadOnlyProbeRegistry.swift` 三常量 +
    `HDCDeviceObservationRegistryContractTests` 的 sibling 哈希常量
    （`b0ac1564…`）→ **需要 `Sources/**` 授权，超出本 change 的 Out of
    scope，须另立 change 或经 change revision 扩列**；r2 已移交 ASP-002 的
    trace/rockchip 4 处不受影响。
  - **判据相应窄化。**`ASP-SHAPE-001` 的零字面量断言限定为**上述 2 处**；
    `sourceSHA256` 不变的证明对 device-observation **不适用**（其 provenance
    本就无该字段，内容锚是 lock/resources 哈希与两个 capture merge OID），
    改以「语义字段 diff 为空 + 正副本仍字节一致 + 两 profile 哈希同步」为
    等价判据。
  - **Source pins（r3 面，audit base 实测）。**
    `device-observation-probes.yaml` 与其副本同 blob
    `1130ca663f686d9f202f53ceb8814320ebc862bd`；
    `DeviceObservation/1.0.0/resources.json`
    `72618f79e12dcdc3ecd6c09537a28be2bfa8572e`；
    `INTEGRATION-PROFILES.lock.yaml`
    `129abc6216593d73e401167181f61924addf602f`；
    `HDCDeviceObservationRegistryContractTests.swift`
    `a7264626a6a93e06008ece9ec73fae32343c0291`；两 profile 见下 Allowed
    paths（其 blob 于实现开工时复核）。
  - **其余 r1/r2 条款有效**：形态设计、active-or-archive 解析规则、
    可重跑脚本要求、Swift 基线 413/1skip/0 与非 `/private/tmp` 验证、
    grade 注记。
- Historical Readiness（r2；audit base = protected `main`
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
- Allowed paths（r3）:
  - `openspec/integrations/openharmony/device-observation-probes.yaml`
  - `openspec/integrations/openharmony/profile.md`（r3 新增；仅同步该 registry 的
    SHA-256 引用）
  - `openspec/platforms/macos/profile.md`（r3 新增；同上）
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

- Status:ready（r1 implementation readiness；仅在维护者对本独立 readiness PR
  exact head review/merge 后生效，**且必须在 TASK-ASP-001 的 done PR #682
  合入之后**——若本 readiness 先于 #682 合入，其 `ready` 不生效，须待 #682。
  只授权一个实现交付：按下方契约先迁移 trace/rockchip 的 4 处、同步其三个
  `scripts/**` 消费方与 lock，**再**加带显式 deferred 排除表的 fail-closed
  守卫。不授权：`readonly-probes.yaml` 及其副本与 4 个 receipt 的迁移
  （需 `Sources/**`，本 change 全局 out of scope）、`Sources/**`、
  `Packages/**` 任何文件、`Decision-Grade` 代写。）
- Historical Status:blocked（前置：① approval #671；② TASK-ASP-001 done
  （#682，排队中）；③ 本 r1。②的**实质**约束（迁移先于守卫落地）已由实现
  #680 合入满足，形式上的 done 翻转以 #682 为准。）
- Readiness（r1；audit base = protected `main`
  `3e2e4ae63ea991c65c9be0b6ce88a9546403d01d`）：
  - **Approval boundary:pending human merge + 顺序门。**本 carrier 修改本文件
    的本任务段、verification.md 与 acceptance-cases.yaml（AC 措辞更正，见下），
    生效另需 #682 先行合入。
  - **守卫不可能无条件全仓（audit base 实测，r2 措辞需更正）。**当前全仓
    registry/resource/receipt 面 `openspec/changes/` 字面量 **16 处 / 8 文件**：
    本任务要迁的 **4 处**（`openharmony/trace-probes/1.0.0/registry.yaml` 3、
    `rockchip/loader-transition/1.0.0/registry.yaml` 1），以及**必须不动的
    12 处 / 6 文件**（`openharmony/readonly-probes.yaml` 4、
    `Fixtures/HDC/Probes/1.0.0/registry.yaml` 4、同目录 4 个 receipt 各 1）
    ——后者的 SHA-256 被产品源码 `HDCReadOnlyProbeRegistry.swift` 钉死并由
    `HDCProduction.swift` 运行时消费（r3 已记录），迁移需 `Sources/**`。
    **因此 r2 写的「全仓字面量为 0」不可满足**；r2 的 `ASP-GUARD-001` 措辞
    由本 PR 一并更正为「除显式登记的 deferred 面外为 0」（三方同步，
    change revision 3→4）。
  - **守卫形态:binary。**新检查须携一份**显式 deferred 登记表**，逐文件写明
    路径、**期望剩余出现次数**与原因（产品运行时 pin，待 `Sources/**` 授权的
    后续 change）。判据三条：① 表外任何 registry/resource/receipt 出现该
    字面量即 fail 并指名文件与行；② 表内文件的出现次数**多于**登记值亦 fail
    （防止借豁免夹带新债）；③ 表内文件的出现次数**少于**登记值时 fail 并提示
    更新登记表（防止 deferred 面被悄悄迁移却不更新账本）。
  - **Source pins:closed（audit base 实测 blob，8 项）。**
    `trace-probes/1.0.0/registry.yaml`
    `9c59c102784661fb1f50c31916e29cbeeb6bd457`；
    `rockchip/loader-transition/1.0.0/registry.yaml`
    `a9b489ee7a4ed6a3382d01b036fa4d5c7f821b1a`；
    `INTEGRATION-PROFILES.lock.yaml`
    `9297820f25b9276859c60ba6bd89ab399066dcd0`；
    `scripts/trace_capture/validate_registry.py`
    `526e2ec3d5048b43f930d71efc7bc7cfb84af2d5`；
    `scripts/rockchip_loader_transition_probe/probe.py`
    `54140eec7557858982be1b8768ae93047867306a`；同目录 `test_probe.py`
    `dbcc9ebb1c8fda8094da71972edd5b1d15fb3713`；`scripts/check_sdd.py`
    `215d604741dd9d17beccdf35e7b00715d062345e`；`scripts/test_check_sdd.py`
    `be8e394b59e36c8d8ccbfe882cde08fcab90bfcc`。
  - **两个消费方都在磁盘上解析路径（实测，勿假设是纯文本字段）。**
    - `validate_registry.py:196` 对 `provenance.redactedManifests` 每项做
      `REPO_ROOT / evidence_path` 并 `read_bytes()`；迁为 change-relative 后
      **必须**获得 active-or-archive 解析（`openspec/changes/<id 小写>/` 或
      `openspec/changes/archive/*-<id 小写>/` 恰一处存在，0/2+ loud fail），
      否则读文件即崩。
    - `probe.py:35` 的常量 `SOURCE_EVIDENCE_RELATIVE_PATH` 现为**仓根相对**
      的完整 `openspec/changes/...` 路径，`:63` 写入 provenance、`:230` 与
      registry 值比对、`:459` 传给下游。迁移须让**常量与 registry 同步改形**
      并保持 `:230` 的比对继续成立。
    - `test_probe.py:317` 以 `provenance["evidencePath"] = "unreviewed/source.md"`
      构造负例，随形态更名同步。
  - **lock 级联。**`trace-probes/1.0.0/registry.yaml` 的 SHA-256 在 lock 中被
    pin（audit base 实测 lock 值 `9d2a390b…` 与文件内容哈希一致），迁移后须
    同步；`rockchip/loader-transition` **不在 lock**（实测 0 命中），无级联。
  - **测试基线（audit base 实测，全 OK）。**`scripts/test_check_sdd.py` OK、
    `scripts/rockchip_loader_transition_probe/test_probe.py` OK、
    `scripts/trace_capture/test_registry.py` OK、`scripts/trace_capture/test_capture.py`
    OK；`check-sdd` 0/0/111。Swift 面不受本任务影响（不碰 `Packages/**`），
    实现须复跑确认仍为 **415 / 1 skipped / 0 failures**（**非 `/private/tmp`**
    检出）。
  - **反证要求（二值）。**① 撤销守卫后，一处人造违例不再被拦；② 保留守卫、
    把 deferred 登记表某文件的期望次数改小 → 必红；③ 迁移后各消费方测试
    仍 OK，且撤销 active-or-archive 解析 → `validate_registry` 必红。
  - **Concurrency/absence:closed at drafting（2026-07-28）。**remote
    `agent/*asp-002*` = 0；主 checkout 为共享副本，实现须用独立 worktree 并
    commit 前核 `git branch --show-current`。
  - **Grade 注记**：`Decision-Grade` 由维护者亲笔。
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

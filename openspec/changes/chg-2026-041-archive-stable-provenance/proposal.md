---
id: CHG-2026-041-archive-stable-provenance
revision: 6
status: verified # 2026-07-28 本 verification-closure PR；closure 段见文末
class: implementation-only
core_change_level: none
owner: lvye
platforms: [macos]
---

# Registry provenance 去路径化：让归档不再断链

## Why

**实测事实（2026-07-28，CHG-2026-024 归档前扫描）**：registry 用**精确仓内
路径**表达 provenance，导致其来源 change **永远归不了档**。

`openspec/integrations/openharmony/device-observation-probes.yaml` 的
`entries[].provenance.sourcePath` 写死
`openspec/changes/chg-2026-024-hdc-device-snapshot-registration/evidence/runs/TASK-I24-001/run.md`；
其 bundled 副本同样。`git mv` 会使两处失效，而修正它们会改变文件字节 →
连带 `INTEGRATION-PROFILES.lock.yaml` 的 SHA-256、pack `resources.json`
与契约测试哈希断言级联失效。CHG-2026-024 因此以 `verified` 状态滞留
（暂缓记录见其 proposal，PR #667）。

**这不是个例，是形态问题。** 全仓现存同型引用：

| 文件 | 引用数 | 指向 |
| --- | --- | --- |
| `openspec/integrations/openharmony/readonly-probes.yaml` | 4 | chg-015 的**已归档**路径 |
| `Packages/.../Fixtures/HDC/Probes/1.0.0/registry.yaml`（副本） | 4 | 同上 |
| `openspec/integrations/openharmony/device-observation-probes.yaml` | 1 | chg-024 的**活跃**路径 |
| `Packages/.../Fixtures/HDC/Probes/DeviceObservation/1.0.0/registry.yaml`（副本） | 1 | 同上 |
| `Packages/.../Probes/1.0.0/receipts/*.json` | 4 | 同 chg-015 归档路径 |

readonly-probes 那四条指向 `changes/archive/...`，说明历史上走的是「归档后
再手工改路径」——它证明该路线可行，也证明每一次归档都要付一次跨
integrations / Packages / lock / resources / 测试的协调改动，且改完的路径
仍然会被下一次目录重命名打断。

**更糟的是这个形态被测试固化**：`HDCProbeRegistryContractTests.swift:280`
断言 `entry.provenance.sourcePath.hasPrefix("openspec/changes/")`，第 419 行
再把 receipt 的 `source.path` 与之交叉比对。也就是说当前契约**要求**使用易断
的形态。

**关键观察**：同一个 `provenance` 块里已经有更稳定的标识——`acceptedBy` 的
PR 号，以及 chg-024 registry 里的 `sessions[].mergeOID`。路径字段是冗余的，
却是唯一的断链源。

## What changes

### In scope

- **定义 archive-stable 的 provenance 形态**：以 `sourceChange`（change id）
  + `sourceEvidence`（**相对 change 目录**的路径）+ 既有 `sourceSHA256`
  取代 `sourcePath`；`acceptedBy` / merge OID 保留。解析规则 = change 目录在
  `openspec/changes/<id>/` **或** `openspec/changes/archive/*-<id>/`
  恰一处存在——与 TASK-NAV-002 为测试面交付的 active-or-archive 解析同构
  （`scripts/host_loop/test_support.py`），此处把同一规则用于 registry 数据。
- **一次性完成迁移与哈希级联**：两个 canonical registry、两个 bundled 副本、
  四个 receipt JSON、`INTEGRATION-PROFILES.lock.yaml` 的相关 SHA-256、两个
  pack 的 `resources.json`，以及 `HDCProbeRegistryContractTests.swift` 的形态
  断言，在**同一个** PR 内保持一致；`sourceSHA256` 全部保持原值（内容未变，
  只改引用方式）。
- **机械防回归**：新增守卫，任何 registry/resource/receipt 内出现
  `openspec/changes/` 字面量即 fail，并配反证（撤销守卫必红）。
- **解锁 CHG-2026-024 归档**：本 change done 后，chg-024 的两条收口条件之一
  即告满足，其 archive 由独立 PR 走既有流程。

### Out of scope

- 任何 registry 的**语义**变更（family、argv、semanticMappings、authority、
  timeout/cancellation、effect 分类逐字不动）；
- `trace-probes` 与 `rockchip` 的 registry（实测无 `sourcePath`，不在迁移面；
  但新守卫对它们同样生效）；
- 产品 `Sources/**`、`Package.swift`、App/xcodeproj、Core/specs/contracts/
  baselines；
- chg-024 的 archive PR 本身；
- CHG-2026-022 消费侧接线。

## Risk

low-medium。**风险不在语义而在哈希级联**：五类文件的 SHA-256 必须在同一 PR
内同时正确，漏一处即 CI 红（而这正是设计上要的 fail-closed）。缓解：迁移由
可重跑的脚本完成而非手工编辑，且 readiness 钉死迁移前后每个文件的 blob，
`sourceSHA256` 不变可作为「只改引用、未改内容」的机器证明。

回退 = revert 单个 PR（纯数据与测试改动，无 runtime 面）。

## Tasks

- **TASK-ASP-001** — 定义形态并完成迁移与哈希级联（含契约测试形态断言更新）。
- **TASK-ASP-002** — 机械守卫：禁止 registry/resource/receipt 内出现
  `openspec/changes/` 字面量。**注记**：本任务需要 `scripts/**` 授权面；若
  维护者希望本 change 更窄，可在 approval 时只批 ASP-001，把守卫另立。
  同一授权面上还有一处**已记录的遗留**（CHG-2026-024 evidence）：canonical
  registry 与 bundled 副本的字节一致守卫亦无自动化，**是否一并纳入 ASP-002
  由维护者在 approval 时决定**，本 proposal 不替其扩张 scope。

两任务均 host-only、零设备、零凭据；`Decision-Grade` 由维护者亲笔。
propose 合入 ≠ 批准。

## r2 注记（2026-07-28，迁移面勘察补全；原文如实保留）

TASK-ASP-001 实现中实测发现 r1 的迁移面不完整：除 r1 钉定的 15 处 / 9 文件
外，`openspec/integrations/` 下另有 **4 处 / 2 文件**同类引用——
`openharmony/trace-probes/1.0.0/registry.yaml` 的 `provenance.redactedManifests`
（3 条裸字符串数组）与 `rockchip/loader-transition/1.0.0/registry.yaml` 的
`evidencePath`（1 条）。r1 起草时的扫描模式 `"source[A-Za-z]*": "openspec/changes/`
只认「`source*` 键 + 字符串值」，既看不见裸字符串数组元素，也看不见键名不同的
`evidencePath`；正确形态是直扫字面量再逐一归类。

由此 r1 的 `ASP-SHAPE-001`（「迁移后 `integrations/**` 下为 0」）与 ASP-001 的
scope 自相矛盾，无法自洽通过。r2 作三项更正、**形态设计零变化**：
① 该断言限定到 ASP-001 的 9 个具名文件；② 余下 4 处移交 TASK-ASP-002；
③ ASP-002 因此改为「**先迁移后设卡**」的二值顺序约束。

移交而非并入的理由是实测约束而非偏好：这 4 处的消费方在 `scripts/**`
（`trace_capture/validate_registry.py` 读 `redactedManifests`；
`rockchip_loader_transition_probe/probe.py` 与其 `test_probe.py` 读写
`evidencePath`），而 `scripts/**` 是 ASP-001 的 Forbidden path、恰为 ASP-002
的授权面。并入 ASP-001 会取消维护者在 approval 时保留的「ASP-002 可单独
裁掉」选项。

## r3 注记（2026-07-28，产品 pin 发现；原文如实保留）

r2 之后实现继续，实测撞上更硬的约束：`readonly-probes.yaml` 的 SHA-256 被
**产品源码**常量钉死——`Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift`
的 `registrySHA256`/`resourceManifestSHA256`/`controlVectorSHA256`，由
`HDCProduction.swift` 在运行时消费——迁移它会打破产品契约并连带打红
`HDCSupervisorContractTests`（实测 8 assertion / 3 test）。`Sources/**` 是本
change 的全局 Out of scope。

**本 proposal 的 Risk 段写「纯数据与测试面，零 runtime 面」——该判断对
readonly-probes 不成立**，如实更正于此：它的迁移是产品改动。

r3 因此把 ASP-001 窄化到 **device-observation 一对（恰 2 处字面量）**，实测
其**零产品消费方**；这恰好是解开 CHG-2026-024 归档所需的**全部**。
readonly-probes + 其副本 + 4 个 receipt + 相关测试与产品常量**移出本 change**，
需另立带 `Sources/**` 的 change 或经 revision 扩列；trace/rockchip 4 处仍按
r2 归 ASP-002。

**范围建议（供 approval 判断）**：本 change 的初衷是解 chg-024 的归档死结，
窄化后的 ASP-001 已完全达成该目标。移出的部分**当前不阻塞任何事**
（readonly 与 trace 指向的 change 早已归档，rockchip 指向的 chg-2026-026
短期不归档），属既有技术债而非活口。是否值得为它开一个触碰产品运行时 pin
的 change，建议单独判断，不必绑在本 change 上。

## r4 注记（2026-07-28，守卫判据可满足性更正；原文如实保留）

起草 TASK-ASP-002 readiness 时实测：全仓 registry/resource/receipt 面现有
`openspec/changes/` 字面量 **16 处 / 8 文件**——ASP-002 要迁的 4 处，加上
**必须留存的 12 处 / 6 文件**（readonly-probes 及其 bundled 副本与 4 个
receipt），后者的哈希是产品运行时 pin（r3 已记录），迁移需 `Sources/**`。

因此 r2 为 `ASP-GUARD-001` 写下的「迁移后全仓字面量为 0」**不可满足**——
守卫一旦无条件全仓启用，仓即刻变红。r4 改为「**显式 deferred 登记表以外**
为 0」，并要求该表逐文件登记期望出现次数、**双向**校验：多于登记值 fail
（防借豁免夹带新债），少于登记值亦 fail（防 deferred 面被悄悄迁移而账本
不更新）。这样豁免是**有账可查且会过期**的，而不是一个永久的例外洞。

## r5 注记（2026-07-28，trace-probes 亦为产品 pin；原文如实保留）

实现 TASK-ASP-002 时实测：`trace-probes/1.0.0/registry.yaml` 的内容哈希被
`Sources/ArkDeckOpenHarmony/TraceProbeAdapter.swift` 的
`public static let registrySHA256` 钉死，迁移其字节使
`TraceAdapterGoldenTests` 变红。与 r3 就 readonly 面确立的结论同型：这是
产品改动，需 `Sources/**`，而后者是本 change 的全局 Out of scope。

r5 因此把 ASP-002 的迁移面窄化为 **rockchip 一处**（实测无 Sources/Packages
pin、不在 lock），trace-probes 的 3 处并入 deferred 登记表，与 readonly 面
同批等待一个带 `Sources/**` 授权的后续 change；登记表由 6 文件 12 处扩为
**7 文件 15 处**。守卫与其双向校验机制不变——**守卫本就是本任务的主要价值，
它使这个形态不能再悄悄回来**。

**范围坦白**：本 change 的 readiness 已连改五版（r1→r5），四次都是同一根因
——迁移一个 hash-pinned 数据文件前，没有把「谁钉了它的哈希」查到
`Sources/`。其中 trace 这次尤其不该：该 pin 曾出现在 ASP-001 勘察期的一次
grep 输出里，是看到了没接上。教训已记录，通用规矩是：**凡迁移 registry/
fixture 类数据文件，先对其内容哈希在 `Sources`/`Tests`/`scripts`/lock 全量
反查，再定 scope。**

## Verification closure（2026-07-28）

两任务 done 于 protected `main` 在案；三条 change-local AC 的证据可复查。
本 PR 仅状态翻转 + 引用 + 一处 r6 措辞补正，零实现夹带。

- **任务链（十一 merge）**：propose #669 `38d891cd`；approval #671
  `e6acbca5`；ASP-001 readiness r1 #674 `6383f5b9`、r2 #675 `fd478664`、
  r3 #677 `16c22fae`；ASP-001 实现 #680 `fc1f453b`、done #682 `8ce5000`；
  ASP-002 readiness r4 #685 `5c935568`、r5 #688 `663eb777`；ASP-002 实现
  #689 `e345acf3`、done（本 closure 之前的独立 flip PR）。#684 = ASP-002 r4
  首版，因标题 TASK token 与 change 级文档冲突而 closed、未合入。
- **`ASP-SHAPE-001` = PASS**：device-observation 一对内 `openspec/changes/`
  字面量 = 0，每条 provenance 具 `sourceChange` + `sourceEvidence`；
  `HDCDeviceObservationRegistryContractTests` 补了两条形态断言（迁移前该
  测试完全不解码 `provenance`，不补即无守卫），两项变异全杀（回退仓内路径
  3 红、删 `sourceChange` 11 红）；active-or-archive 解析对**已归档**来源
  （chg-2026-015）与**未归档**来源（chg-2026-024）两分支各实测恰一处命中。
- **`ASP-CASCADE-001` = PASS**：pack `resources.json`、lock 三条与契约测试
  哈希断言一致，正副本仍字节相同；`check-sdd` 0/0/111；Swift 于**非
  `/private/tmp`** 检出 **415 / 1 skipped / 0 failures**。
- **`ASP-GUARD-001` = PASS**（r6 措辞）：先迁 rockchip 1 处（`evidencePath`
  → `evidenceChange` + `evidenceRelativePath`，`evidenceSHA256` 逐字节未动）
  并同步 `probe.py` / `test_probe.py`，**后**设卡；守卫扫描面实测 **7 文件 /
  15 处**，与 deferred 登记表逐文件精确相等、表外为 0；登记表**双向**校验
  （多于 = 夹带新债、少于 = 还债不更账、登记文件不存在，三者皆 fail）。
  四条反证全部如预期：人造违例 → `ERROR …registry.yaml: line 43 names a
  whole in-repo change path`，删掉 `main()` 里那一行调用、违例原样保留 →
  0 error（拦住它的确是新检查）；trace 登记值 3→2 → 必红；撤销
  active-or-archive 解析 → `test_probe` FAILED（5 failures / 2 errors）；
  **归档模拟**——把 chg-2026-026 移入 `archive/2026-07-28-…/` 后，迁移后形态
  31 OK 且解析器落在归档目录、evidence 哈希仍等于 registry pin，迁移前形态
  31 全红。acceptance ID 计数 111 不变。
- **本 change 的目的已达成**：`CHG-2026-024` 的归档死结在 ASP-001 落地时即
  解除，其 archive 由自身独立 PR 走既有流程，不在本 change 载体内。
- **遗留（不阻 verified，如实带入 archive）**：deferred 登记表内 **15 处 /
  7 文件**（readonly 面 12 + trace-probes 3）仍是**未偿债务**——其内容哈希
  被 `HDCReadOnlyProbeRegistry.swift` 与 `TraceProbeAdapter.swift` 钉死，
  迁移须由一个持 `Sources/**` 授权面的后续 change 重钉产品哈希后一并完成。
  守卫的「少于登记值也 fail」这一条保证那次迁移不能不更账。
- **过程如实在案**：本 change 的 readiness 连改六版，其中四次同一根因——
  迁一个 hash-pinned 数据文件前没把「谁钉了它的哈希」查到 `Sources/`。
  由此立的通用规矩（迁 registry/fixture 类数据文件前先对其内容哈希在
  `Sources`/`Tests`/`scripts`/lock 全量反查再定 scope）已写入 r5 注记，
  并在 ASP-002 实现期第一次照做——正是它证明了 rockchip 可迁、trace 不可迁。


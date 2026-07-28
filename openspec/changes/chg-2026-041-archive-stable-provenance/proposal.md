---
id: CHG-2026-041-archive-stable-provenance
revision: 1
status: approved
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

# CHG-2026-041 Tasks

> 两任务 host-only、零设备、零凭据。ASP-002 需 `scripts/**` 授权面，可在
> approval 时被裁掉而不影响 ASP-001。`Decision-Grade` 行由维护者亲笔
> （#577 载体先例），本文件不代写。

## TASK-ASP-001 — 定义 archive-stable provenance 并完成迁移与哈希级联

- Status:blocked（前置：① 本 change approval-only PR merge；② 独立 readiness
  PR 钉定迁移前每个受影响文件的 exact blob、迁移后期望形态、`sourceSHA256`
  不变的机器证明方式，以及 Swift/SDD 基线与二值 test matrix。）
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
- In scope:在既有 SDD 守卫面新增一条检查——`openspec/integrations/**` 与
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/**` 下的
  registry/resource/receipt 文件内出现 `openspec/changes/` 字面量即 fail，
  报告文件与行；配**反证**（撤销该检查后以一处人造违例证明其必红）。
- Out of scope:守卫之外的任何行为；registry 数据（属 ASP-001）；
  `check_pr_paths` / host_loop 面。
- Allowed paths:`scripts/check_sdd.py`、`scripts/test_check_sdd.py`、
  本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/` 其余文件、`openspec/integrations/**`、
  `Packages/**`、`.github/**`、其他 change。
- Risk:low（只加一条 fail-closed 检查；回退 = revert）。
- Hardware required:no

### Deliverables

- `check_sdd` 新检查 + 单元测试（正例：现状全绿；负例：人造违例必红）；
- evidence run：`check-sdd` 前后计数、反证记录。

### Verification

- `ASP-GUARD-001`：迁移后的仓全绿；人造违例（任一 registry 插入一条
  `openspec/changes/...` 路径）→ `check-sdd` 报 error 并指名文件；撤销检查
  后该违例不再被拦（反证）。`check-sdd` acceptance ID 计数保持 111。

### Notes / handoff

维护者若在 approval 时决定把 CHG-2026-024 evidence 记录的另一处遗留
（canonical registry ↔ bundled 副本字节一致守卫）一并纳入，本任务
Allowed paths 与 AC 需在 readiness 前经 change revision 扩列；本文件不预先
扩张。

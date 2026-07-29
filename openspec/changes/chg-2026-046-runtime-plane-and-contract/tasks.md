# Tasks

> 本 change 采用其自身交付的垂直 PR 模型:本任务的实现、测试、文档与
> evidence 由一个实现 PR 交付,状态翻转随该 PR 完成,不再有独立
> readiness-only / done-only 载体。

## TASK-RTC-001 — MU-1 垂直交付:治理两平面 + Runtime API v2 + Capability + Catalog v1

- Status:ready
- Grade:D1(治理文本 + 纯契约代码 + catalog 数据与生成器;零设备执行、
  零 E2 面变更、零既有安全门放宽)
- Platform:macos(契约保持 Foundation-neutral)
- Requirements:兼容实现,不主张 canonical Core Requirement;治理文本变更
  以 `openspec/governance/enforcement.md` 2.2.0 版本化
- Acceptance:`RTC-GOV-001`、`RTC-API-001`、`RTC-CAP-001`、`RTC-CAT-001`、
  `RTC-COMPAT-001`
- Depends on:本 proposal PR 合并(即批准)
- Scope(四个子面,不拆分为独立 PR):
  1. **T01 治理**:AGENTS.md / project.md / enforcement.md 两平面分离、
     D0/D1/D2 分级成文、废止状态-only PR 形态、host_loop 边界成文;
  2. **T02 API v2**:`RuntimeOperationRequest` 2.0.0 + 治理字段结构性排除
     + `PublishedOperationBundleManifest` + 稳定错误码 + v1 adapter;
  3. **T03 Capability**:`RuntimeCapability` 模型 + durable store +
     E0/E1/E2 策略解析 + 原子消耗;
  4. **T04 Catalog**:`Catalog/` 六 operation + schema + `scripts/
     catalog_gen` 生成器 + `ArkDeckCore` 生成常量 + check_sdd drift family。
- Verification:见 `verification.md`;全部为 contract/unit/脚本层,
  无硬件 evidence 主张
- Stop conditions:任何既有测试无法在不弱化断言的前提下保持通过;
  发现需要修改 `openspec/specs/**` 或 `workflow-step-registry.yaml`;
  发现需要放宽 E2/D2 既有门槛——任一命中即停,登记 blocked 并说明
- Hardware required:no
- Allowed paths:
  - `AGENTS.md`
  - `openspec/project.md`
  - `openspec/governance/enforcement.md`
  - `openspec/changes/chg-2026-046-runtime-plane-and-contract/**`
  - `Catalog/**`
  - `Packages/ArkDeckKit/**`
  - `scripts/catalog_gen/**`
  - `scripts/check_sdd.py`
  - `scripts/test_check_sdd.py`
  - `scripts/README.md`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/contracts/**`、`openspec/verification/**`(全局)、
    `openspec/integrations/**`、`openspec/platforms/**`、
    `openspec/baselines/**`
  - `scripts/host_loop/**`、`scripts/check_pr_paths.py`、
    `scripts/automation_config.json`
  - `.github/**`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(治理文本改写影响后续全部流程解释;契约代码为纯新增,
  回归面主要在 check_sdd 新 family 与既有套件的共存)

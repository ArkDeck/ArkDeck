# CHG-2026-031 Verification Plan

> Change:CHG-2026-031-macos-session-settings@r2
> Status:planned
> Core baseline:CORE-2.1.0（零 Core delta）

## Environment

- macOS signed Sandbox Debug build，当前 Xcode/Swift toolchain；
- Swift package contract tests 使用 `mkdtemp`/test temporary directory，禁止指向用户
  Application Support、home 或真实自定义根；
- Session fixture 包含 valid finalized、active/partial、pinned、expired、symlink、
  identity mismatch、damaged metadata/manifest、unknown size 与 fault injection；
- UI fixture 只产生 presentation，delete/process/device dispatch port 数为 0。

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| `SSET-CONFIG-001` | contract | 精确默认值；typed save/reload；损坏值具名失败；custom bookmark 仅在 scope/path 验证后可用，stale/mismatch 要求重新选择且不回退 | `TASK-SSET-001` run |
| `SSET-CATALOG-001` | contract + fault injection | 只索引安全 finalized Session；pin/generation 持久化；partial/symlink/mismatch/corrupt/unknown 保留且形成 conservative pressure | `TASK-SSET-001` run |
| `SSET-RETENTION-001` | contract + App-process production composition revalidation | plan 顺序正确；未经 fresh confirmation 删除数为 0；apply 后按实际 rescan 更新 shared coordinator；ArkDeckApp composition root 持有唯一 runtime 且 App plan-only Rockchip Session consumer 实际使用其 root/coordinator；standalone CLI 不冒充 App consumer | `TASK-SSET-001` run + CHG-2026-026 `TASK-RKFUI-002` merged evidence + `TASK-SSET-001R` run |
| `AC-ART-006-02` | contract | expired ordinary 先删、再按 completedAt；pinned 永不删；仍超安全目标或结果不确定时 heavy writer blocked | `TASK-SSET-001` run |
| `AC-STO-001-01` | contract | custom/default 不同 path 但同 volume 时仍由真实 volume identity 聚合 | `TASK-SSET-001` run |
| `AC-STO-003-01` | contract | shared coordinator 在同卷保持最多一个 heavy writer，retention block 不能被新 facade/host 绕过 | `TASK-SSET-001` run |
| `AC-STO-004-01` | fault injection | quota 不冒充物理预留；ENOSPC/外部占用仍走既有 stop/finalize 语义 | `TASK-SSET-001` run |
| `SSET-UI-001` | signed XCUITest + composition contract | Settings 可访问、可校验、可选择/重置/pin/预览/取消/确认；危险动作二次确认；fixture 无 production delete path | `TASK-SSET-002` run |

## Negative and recovery tests

- UserDefaults：missing/version drift/wrong type/zero/overflow/quota ≤ margin；
- bookmark：missing/stale refresh failure/path mismatch/scope denied/root replaced；
- catalog：symlink at every level、duplicate ID、identity mismatch、invalid manifest、
  partial Session、metadata corruption、size overflow/read failure；
- plan/apply：pin after preview、settings/root/catalog generation drift、volume drift、
  deletion fault after one candidate、App termination before/after confirmation、rescan fail；
- composition：独立 coordinator 绕过尝试、fixture facade dispatch attempt、root fallback
  attempt，全部 fail closed；
- privacy/secret scan：bookmark bytes、home path、Artifact content 与设备标识不进入 log/
  evidence；测试临时目录不误报为真实用户数据。

## Evidence classification

- Swift contract/fault tests：`contract`；
- signed Sandbox XCUITest：`platform`；
- 所有 Session 删除测试：`simulation`/temporary fixture；
- real user data deletion、real device/hardware：`not run`，不得据此声明。

## Deviations

任何自动删除、schema/Core delta、真实用户目录验证、entitlement 扩集或 production
root 不可达都不是隐式 deviation；对应 task 立即 blocked 并修订 change。

## r2 production-composition gate

- r2 只选择修复路线，不产生 PASS：CHG-2026-026 `TASK-RKFUI-002` 仍须先按自己的
  approved change 与独立 readiness 交付 App-process plan-only facade/Session consumer。
- 该 readiness 必须显式 pin CHG-2026-031 r2、#436 runtime/evidence，并把同一
  `SessionStorageApplicationRuntime` 的 App composition root→Rockchip consumer
  contract 加入其 allowed scope/evidence；本 r2 不能替代该 change 的维护者判断。
- `TASK-SSET-001R` 只在 cross-change task done 后复验合入版：同一 runtime identity/
  configuration epoch、validated root、shared coordinator/admission、owned Session/plan
  Artifact、failure-path zero create，以及 fixture zero delete/process/device port。
- App Group/shared UserDefaults、跨进程 bookmark/IPC、CLI 读取 App container 或仅构造
  未消费 runtime 均不在通过路径；出现任一需要新 ADR/change。
- standalone CLI 继续回归既有 composition，但 evidence 必须明确它不受 App-owned
  settings runtime 控制，不得作为 `SSET-RETENTION-001` App reachability 证明。
- TASK-SSET-002 的后续 readiness 必须把同一 App-owned runtime 固定为 Settings facade
  的生产依赖；`TASK-SSET-001R` 不以尚未实现的 Settings facade 作为前置。

## Result gate

- [ ] 三个 task 均满足各自门禁；TASK-SSET-001R 有 merged revalidation/evidence，
      TASK-SSET-001/001R/002 各有独立 done PR
- [ ] 四条 change-local AC 与四条适用 canonical AC 均有可复查 PASS
- [ ] Full Swift、signed UI、SDD、allowed-path、secret/privacy checks 全绿
- [ ] Simulation/fixture 未记为真实用户数据或硬件 evidence
- [ ] 独立 verification PR 只翻状态并引用具体 run

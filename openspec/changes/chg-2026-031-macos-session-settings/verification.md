# CHG-2026-031 Verification Plan

> Change:CHG-2026-031-macos-session-settings@r1
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
| `SSET-RETENTION-001` | contract + production composition | plan 顺序正确；未经 fresh confirmation 删除数为 0；apply 后按实际 rescan 更新 shared coordinator；production SessionStore 使用同一 settings root | `TASK-SSET-001` run |
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

## Result gate

- [ ] 两个 task 均有 merged implementation/evidence 与独立 done PR
- [ ] 四条 change-local AC 与四条适用 canonical AC 均有可复查 PASS
- [ ] Full Swift、signed UI、SDD、allowed-path、secret/privacy checks 全绿
- [ ] Simulation/fixture 未记为真实用户数据或硬件 evidence
- [ ] 独立 verification PR 只翻状态并引用具体 run

# CHG-2026-036 Verification Plan

> Change:CHG-2026-036-macos-bundled-rockchip-component@r2
> Status:planned
> Core baseline:CORE-2.1.0（零 Core delta）

## Environment

- protected `main` Git objects 与 GitHub exact review/merge metadata；
- ADR-0003 与 archived CHG-2026-035 exact decision/evidence；
- accepted source/license/dependency/distribution record；
- two isolated clean builders with pinned macOS/Xcode/SDK/compiler/build tools；
- declared arm64/x86_64（或经 TASK-BRC-001 accepted 的 exact architecture set）与
  minimum macOS；
- Developer ID/notary release environment；clean-host/VM snapshots；
- signed Sandbox App + exact nested component + sanitized test files；
- exact DAYU200/RockUSB topology 只用于 `TASK-BRC-005` E0，零 mutation/E1/E2。

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| `BRC-SUPPLY-001` | `documentReview` | source/GPL/dependency/SBOM/CVE/update/rollback/distribution envelope 由明确 owner 接受，所有后继 input machine-pinned | `TASK-BRC-001` run + distribution record |
| `BRC-REPRO-001` | `platform` clean-build comparison | two clean builders 对 exact inputs 产生一致 unsigned identity/approved normalization；无 ambient Homebrew/PATH/network/cache dependency | `TASK-BRC-002` run + registry/SBOM/build receipts |
| `BRC-HANDOFF-002` | `platform` workflow/artifact inspection | component workflow 可按需 dispatch 且 unsigned 输出保留 30 天；构建输入/逻辑/component identity 零变化，一次 dispatched run 复现已接受的 SHA-256 且 expiry 约 30 天 | `TASK-BRC-002R` run + dispatched run artifact metadata |
| `BRC-PACKAGE-001` | `platform` package inspection | nested location/identifier/min OS/arch/exact child entitlements/inside-out Developer ID/HR/notary/staple 全部 exact match | `TASK-BRC-003` run + signed package receipts |
| `BRC-COMPOSITION-001` | `contract` + source reachability | callers 无法选择 executable/hash/argv/env/receipt/authority；typed leases、intent/outcome/fault/reconcile 完整，external fallback 不可达 | `TASK-BRC-004` run + contract/fault tests |
| `BRC-SANDBOX-E0-001` | `platform` + `realHardware` E0 | signed App 分离证明 child launch、file lease 与 RockUSB read-only；所有 mutation/E1/E2/destructive counters = 0 | `TASK-BRC-005` sanitized receipts |
| `BRC-DISTRIBUTION-001` | `platform` clean-host/VM | Developer ID/notarized DMG 可在 clean host 验证 supply-chain tuple、install/E0/update/rollback，零 mixed-version reachability | `TASK-BRC-006` release/VM receipts |
| `BRC-HANDOFF-001` | `documentReview` | six tasks/evidence closed；Core/HDC/CHG-2026-026/hardware matrix 未静默变化，下一步是独立 CHG-2026-026 revision | task runs + final diff/trace audit |
| `AC-FLASH-001-01` | strict parser/identity contract + E0 | unsupported/unknown/malformed/multi-device 不被表现为空设备成功，bundled tool identity exact | BRC-004/005 |
| `AC-FLASH-005-01` | production reachability audit | plan-only/execute-disabled 与 E0/未来 execute 明确分离，不把 component 存在视为执行成功 | BRC-004/006 |
| `AC-FLASH-008-01` | file lease/stream fault contract | image/key/output access 与 stream/backpressure/partial failure bounded 且可诊断 | BRC-004/005 |
| `AC-FLASH-012-01` | semantic result contract | exit/stdout/stderr/typed postcondition 合成唯一结果，unknown 不变成功 | BRC-004/005 |
| `AC-FLASH-013-01` | diagnostics/distribution review | component identity、阶段、恢复动作可解释且无敏感数据 | BRC-001/003/005/006 |
| `AC-FLASH-015-01` | authority/effect audit | 本 change 不可取得 E2；真实 binding/destructive dispatch = 0 | BRC-004/005/006 |
| `AC-JOB-002-01` | crash/fault contract | effect 前 durable intent；失败写 durable outcome 或 unknown | BRC-004 |
| `AC-JOB-003-01` | restart/reconcile contract | restart reconstructs state without guessing or replay | BRC-004/006 |
| `AC-JOB-005-01` | process contract/source audit | exact product-owned executable + typed argv；no shell/PATH/caller env | BRC-002/004/005 |
| `AC-JOB-006-01` | unknown-effect/update fault matrix | child crash/mixed version/unknown effect enters recovery and never auto-replays | BRC-004/006 |
| `AC-UX-007-01` | signed Sandbox/package negative tests | permission/install/signing failures actionable；零 silent elevation/rule/group/ACL mutation | BRC-001/003/005/006 |

## Negative and recovery tests

- Source/license/dependency/recipe/SBOM/registry/hash/architecture/minimum-OS drift；
- ambient Homebrew/PATH/header/library/cache/network input and non-reproducible output；
- missing/wrong nested path, identifier, signature, entitlement, Hardened Runtime,
  architecture, notarization or staple；
- caller-supplied executable/hash/argv/env/receipt/authority, external/PATH/shell/
  download/copy/symlink fallback；
- wrong/missing file lease、TOCTOU、permission denial、partial output、backpressure、
  timeout、cancel、child crash、App crash、USB disconnect；
- no/malformed/multi-device/unsupported `ld`, identity drift before/after intent；
- update/rollback mixed App-component tuple, crash after intent, unknown outcome and
  restart reconciliation；
- secret/privacy scan for credential、notary token、bookmark、absolute user path、
  raw device ID/log、image/key content or unreviewed binary。

## Evidence classification

- supply-chain/distribution acceptance 与 final handoff：`documentReview`；
- reproducible build、package/sign/notary、contract tests、clean-host/VM：
  `platform`（contract/fake subresults separately labelled）；
- actual DAYU200/RockUSB E0 only：`realHardware`，仅证明 read-only E0 observation；
- simulation/fake 不计入 package、Sandbox、USB 或 hardware support；
- no task in this change may produce `destructive` evidence。

## Deviations

任一 Core/spec/locked-contract、App entitlement、HDC bundling、helper/XPC/distribution
architecture、CHG-2026-026 task、hardware support 或 destructive scope 变化都不是允许
deviation；必须停止并走 proposal revision/new change。无法满足 mandatory gate 时
结论为 blocked，不启用 fallback。

## Result gate

- [ ] 七个任务（含 r2 的 TASK-BRC-002R）都有独立 approval/readiness/evidence/done ancestry
- [ ] 八条 change-local AC（含 `BRC-HANDOFF-002`）与全部适用 canonical AC 有可复查 evidence
- [ ] source/license/dependency/SBOM/distribution owner 与 release retention closed
- [ ] reproducible build、nested signature/notary、typed composition、E0/file access、
  clean-host/update/rollback evidence closed
- [ ] Simulation/fake 未计入 signed package、USB 或硬件支持
- [ ] mutation/E1/E2/destructive/privilege/system-change dispatch 全为 0
- [ ] Core/spec/contracts、HDC external-first、CHG-2026-026 与 hardware matrix 零
  未声明变化
- [ ] SDD、tests、allowed-path、diff、secret/privacy checks 全绿
- [ ] 独立 verification PR 只翻状态并引用具体 merged evidence

# Baseline Traceability Index

> Core baseline：CORE-2.1.0
> Status：requirements and AC defined; per-change evidence tracked in change ledgers
>
> 更新规则（2026-07-20 成文,账本对齐 PR）:平台列仅在对应平台 change 达到 change 级
> `verified` 时翻转;单任务 done/单 AC passed 的证据由各 change 的 verification.md
> acceptance matrix 与 evidence/ 承载,不提前汇入本表。CHG-2026-021 的 verification
> closure 经维护者 review/merge 后,Trace 的 macOS canonical contract/parserGolden 面
> 翻转为 `verified`;其余未达同等 change gate 的平台列保持 `notStarted`。

每个 Requirement 的 Scenario 位于同一 `spec.md`，是验收事实源。本索引只记录验证套件和平台状态，不复制 AC 文本。

| Requirement range | Source | Planned test/evidence family | macOS | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| REQ-HDC-001…010 | `specs/toolchain-hdc-server/spec.md` | TEST-HDC-SUPERVISOR / TEST-HDC-AUTH / EVD-*-HDC | notStarted | notStarted | notStarted |
| REQ-DEV-001…008 | `specs/device-targeting-auth/spec.md` | TEST-DEVICE-BINDING / TEST-RECONNECT / EVD-*-TRANSPORT | notStarted | notStarted | notStarted |
| REQ-WF-001…002 | `specs/workflow-journal-recovery/spec.md` | TEST-WORKFLOW-EFFECT | notStarted | notStarted | notStarted |
| REQ-JOB-001…008 | `specs/workflow-journal-recovery/spec.md` | TEST-JOB-STATE / TEST-JOURNAL / TEST-RECOVERY | notStarted | notStarted | notStarted |
| REQ-NFR-001…002 | `specs/workflow-journal-recovery/spec.md` | TEST-CLOCK / TEST-STREAMING | notStarted | notStarted | notStarted |
| REQ-ART-001…006 | `specs/session-artifact-storage/spec.md` | TEST-ARTIFACT / TEST-MANIFEST / TEST-PRIVACY | notStarted | notStarted | notStarted |
| REQ-STO-001…005 | `specs/session-artifact-storage/spec.md` | TEST-STORAGE-COORDINATOR / TEST-ENOSPC | notStarted | notStarted | notStarted |
| REQ-DUMP-001…008 | `specs/ui-dump/spec.md` | TEST-DUMP-PARSER / TEST-DUMP-WORKFLOW / EVD-HW-DUMP | notStarted | notStarted | notStarted |
| REQ-TRACE-001…009 | `specs/trace/spec.md` | TEST-TRACE-ADAPTER / TEST-PARAM-RESTORE / EVD-HW-TRACE | verified | notStarted | notStarted |
| REQ-DEBUG-001…007 | `specs/debug-workbench/spec.md` | TEST-HILOG-ROTATION / TEST-DEBUG-COMMANDS / EVD-HW-DEBUG | notStarted | notStarted | notStarted |
| REQ-FLASH-001…015 | `specs/flashing/spec.md` | TEST-FLASH-PLAN / TEST-FLASH-RECOVERY / EVD-HW-FLASH | notStarted | notStarted | notStarted |
| REQ-UX-001…007 | `specs/desktop-ux-observability/spec.md` | TEST-VIEWMODEL / TEST-HISTORY / TEST-A11Y / TEST-DEVICE-ACCESS | notStarted | notStarted | notStarted |
| REQ-DIAG-001…002 | `specs/desktop-ux-observability/spec.md` | TEST-DIAGNOSTICS / TEST-EXPORT-PRIVACY | notStarted | notStarted | notStarted |
| REQ-I18N-001 | `specs/desktop-ux-observability/spec.md` | TEST-I18N / platform smoke | notStarted | notStarted | notStarted |

## Safety-critical direct mappings

| Requirement | Mandatory evidence |
| --- | --- |
| REQ-HDC-003、REQ-HDC-010 | external/unknown automatic lifecycle call counter = 0；manual lifecycle impact/critical-job/stale-confirmation/audit contract |
| REQ-HDC-008 | authorized 与 encrypted 状态独立；无 evidence 安全降级 |
| REQ-DEV-002/003/004/005/006 | binding revision journal + USB/TCP/UART rebind contract tests |
| REQ-WF-002 | Core minimum effect 不可被 Profile 降低 |
| REQ-JOB-002/003/006/007 | crash-window fault injection、critical cancellation、abandon durable ordering |
| REQ-ART-002 | raw hash invariance |
| REQ-STO-002/003/004/005 | headroom、同卷 heavy admission、external ENOSPC、crash/replug |
| REQ-FLASH-005 | full plan + device mutation dispatch = 0 |
| REQ-FLASH-006 | no real connectKey/process + simulated evidence classification |
| REQ-FLASH-008/009/010/012/013 | critical process/power/rebind/postflight/recovery evidence |
| REQ-FLASH-014 | exact real hardware matrix evidence |
| REQ-FLASH-015 | standard Agent/CI real destructive dispatch = 0；controlled lab exact plan/target authorization mismatch/expiry dispatch = 0；owner-attested run + approved hardware evidence |
| REQ-UX-007 | permissionDenied/offline/unauthorized separation；sudo/driver/udev/group/ACL mutation call counter = 0 |

当测试落盘时，每项必须扩展为具体 `TEST-*` 和 `EVD-*`，不得只保留范围级映射。

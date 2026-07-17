# M1 Change Review Gate

> Status：r1 passed；r2 passed；r3 HDC readiness/design amendment pending maintainer review
> Reviewed：r1 于 2026-07-15 由维护者经 PR #14 合入；r2 于 2026-07-16 经 PR #22
> 合入，merge commit `eb9b9dc64ab422a51a518066f70b728e9ff5ba24`。V2 语义为合并即批准。
> 原 r1 blocked 理由已全部解除:CORE-1.0.0 已 ratify(main `c76a492`,PR #3);
> V1 approval/claim guard 已由 V2 git-native 治理取代(受保护 main + sdd-guard,
> 见 `governance/enforcement.md`);M0A 分发决策已交付
> (`docs/adr/0001-macos-v1-distribution.md`,main `f27574a`,PR #13)。

- [x] Change class is platform and declares no Core/spec delta
- [x] Design does not intentionally relax Core behavior
- [x] Scope excludes every realHardware acceptance and every real-device path；M1-006 只读消费
  CHG-005 approved/versioned/hash-pinned HDC fixtures，不在 CHG-002 内自建 golden 判 pass。
- [x] Verification matrix is complete and binary(6 个 platform 行 + 62 个 Core AC,gate 明确)
- [x] M0A distribution decision record exists(ADR-0001 选定非 Sandbox Developer ID 单一路径;Runtime/Storage ports 按该方向实现,Sandbox 研究原型不进入 v1 契约)
- [x] Ratified `CORE-2.0.0` 已由 PR #21 合入，两个 resume-marker 出口、
  `AC-JOB-001-07` 与 111 条全局 Core AC 已进入 current spec/conformance。
- [x] r2 的 scope 为 62 个 Core AC + 6 个 platform AC，且
  `scripts/check-sdd.sh` 通过（0 error、0 warning、111 acceptance IDs）。
- [x] r2 仅重定向 platform implementation scope 并修正 task state，不修改
  Core spec/contract、Swift 实现或 platform conformance claim。

## r3 review gate

- [x] proposal/design/spec-impact/scope/verification/acceptance-cases 均标识 revision 3，
  `MAC-M1-HDC-001` 的 method/expected result 与 expanded verification matrix 一致。
- [x] 原 design 的 blanket UI non-goal 已在 change-level r3 中精确修订；唯一 UI 例外是
  in-scope HDC Scenario 明文要求的 diagnostics/safety surface，通用功能 UI 仍排除。
- [x] M1-005 原占位条目已标记 blocked，并明确 production
  `DurableSessionAuditAppending`/`SessionManifestPublishing`、reopen/replay 与 confirmation
  contract；不得预设未交付接口。
- [x] M1-006 对 success/failure/healthy/version semantic family 只接受 CHG-005 approved
  pinned resource，resource registration/`Bundle.module` smoke evidence 由 I5-001 负责。
- [x] AC-HDC-003-01 的 diagnostics/confirmed recovery options 与 AC-HDC-009-01 的 read-only
  capability display 已加入 XCUITest/platform closure，不再只验证零 lifecycle counter。
- [x] r3 draft 不执行 M1-005/M1-006，不产生 implementation evidence，不修改 Core/contract、
  platform conformance 或 release claim。
- [ ] 维护者已 review 并合入 r3；在此之前 r3 scope、task contract 与 readiness gate 不生效，
  M1-005/M1-006 均保持 blocked。

任务状态以 `tasks.md` 为唯一事实源(V2:原 immutable task packets 已废止)。本文件记录历史与
r3 review gate，不替代维护者 review/merge。

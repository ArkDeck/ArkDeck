# M1 Change Review Gate

> Status：r1/r2/r3 passed；r4 execution-boundary scope/dependency amendment pending maintainer review
> Reviewed：r1 于 2026-07-15 由维护者经 PR #14 合入；r2 于 2026-07-16 经 PR #22
> 合入，merge commit `eb9b9dc64ab422a51a518066f70b728e9ff5ba24`；r3 经 PR #35
> 合入，merge commit `11eb5cbe69bc9089fd870d6397f698f4c93dd299`。V2 语义为合并即批准。
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
- [x] 维护者已 review 并合入 r3（PR #35）；r3 scope 与 task contract 已生效。

## r4 review gate

- [x] amendment 只修改 CHG-002 治理 artifacts；无 Swift、Xcode、entitlement、profile、lock、
  fixture、contract、Core spec、evidence 或任务状态修改。
- [x] `scope.yaml` 只新增既有 `PORT-FILE-ACCESS-001`、`PORT-TOOL-TRUST-001`、
  `PORT-DEVICE-ACCESS-001`；Core/platform AC 集合与 pass/fail 语义不变。
- [x] package dependency closure 精确为 App → Core/Workflows、Workflows →
  Core/OpenHarmony/Storage、OpenHarmony → Core/Process；App/Workflows 均不能绕过 Adapter
  直接调用 Process。
- [x] `ArkDeckContractTests.swift` 的未来实现授权仅限 dependency table、App import contract
  与必要机械格式化；既有 HDC/Process cases 不在该文件内迁移或改写。
- [x] Core/Process cross-deliverable scope 分别只允许 durable Job toolchain intent 与原子
  descriptor/inode-bound launch gate；Requirement/AC/schema/contract 与其他 Process 行为不变。
- [x] verified integration profile/lock 是只读依赖；platform profile scope 只允许映射其中
  identity、authorization、health/version、subserver capability 等 side-effect-classified
  read-only probe 及机械 platform-lock 元数据；integration mapping、golden、mutating probe、
  conformance/release 状态均禁止修改。
- [x] signed Sandbox/XCUITest 是仓库 fake/read-only platform evidence；不运行真实 HDC/设备，
  不替代 Developer ID、公证、真机、完整 platform conformance 或 ADR-0001 分发结论。
- [ ] 维护者已 review 并合入 r4；在此之前 r4 新增 paths/dependencies 不构成 M1-006 实现授权。

任务状态以 `tasks.md` 为唯一事实源(V2:原 immutable task packets 已废止)。本文件记录历史与
r4 review gate，不替代维护者 review/merge。

# M1 Pre-Task Review Gate

> Status：r1 passed；r2 CORE-2.0.0 retarget 在本修订 PR 经维护者 review/merge 后生效
> Reviewed：r1 于 2026-07-15 由维护者经 PR #14 合并签署(V2:合并即批准)。
> 原 r1 blocked 理由已全部解除:CORE-1.0.0 已 ratify(main `c76a492`,PR #3);
> V1 approval/claim guard 已由 V2 git-native 治理取代(受保护 main + sdd-guard,
> 见 `governance/enforcement.md`);M0A 分发决策已交付
> (`docs/adr/0001-macos-v1-distribution.md`,main `f27574a`,PR #13)。

- [x] Change class is platform and declares no Core/spec delta
- [x] Design does not intentionally relax Core behavior
- [x] Scope excludes every realHardware acceptance and every real-device path；parserGolden 仅包含本 change 内仓库 fixture 覆盖的 `AC-HDC-005-01`（见 proposal）
- [x] Verification matrix is complete and binary(6 个 platform 行 + 62 个 Core AC,gate 明确)
- [x] M0A distribution decision record exists(ADR-0001 选定非 Sandbox Developer ID 单一路径;Runtime/Storage ports 按该方向实现,Sandbox 研究原型不进入 v1 契约)
- [x] Ratified `CORE-2.0.0` 已由 PR #21 合入，两个 resume-marker 出口、
  `AC-JOB-001-07` 与 111 条全局 Core AC 已进入 current spec/conformance。
- [x] r2 的 scope 为 62 个 Core AC + 6 个 platform AC，且
  `scripts/check-sdd.sh` 通过（0 error、0 warning、111 acceptance IDs）。
- [x] r2 仅重定向 platform implementation scope 并修正 task state，不修改
  Core spec/contract、Swift 实现或 platform conformance claim。

任务状态以 `tasks.md` 为唯一事实源(V2:原 immutable task packets 已废止);本 gate 通过后任务方可 ready。

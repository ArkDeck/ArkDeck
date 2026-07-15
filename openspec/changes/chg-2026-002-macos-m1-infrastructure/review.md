# M1 Pre-Task Review Gate

> Status：passed  
> Reviewed：2026-07-15 由维护者经本 PR 合并签署(V2:合并即批准)。
> 原 blocked 理由已全部解除:CORE-1.0.0 已 ratify(main `c76a492`,PR #3);
> V1 approval/claim guard 已由 V2 git-native 治理取代(受保护 main + sdd-guard,
> 见 `governance/enforcement.md`);M0A 分发决策已交付
> (`docs/adr/0001-macos-v1-distribution.md`,main `f27574a`,PR #13)。

- [x] Change class is platform and declares no Core/spec delta
- [x] Design does not intentionally relax Core behavior
- [x] Scope excludes all realHardware/parserGolden acceptance and every real-device path(parserGolden 仅限仓库 fixture case,见 proposal)
- [x] Verification matrix is complete and binary(6 个 platform 行 + 61 个 Core AC,gate 明确)
- [x] M0A distribution decision record exists(ADR-0001 选定非 Sandbox Developer ID 单一路径;Runtime/Storage ports 按该方向实现,Sandbox 研究原型不进入 v1 契约)
- [x] Ratified Core baseline and all referenced contracts pass the SDD guard(`check_sdd: 0 error(s), 0 warning(s), 110 acceptance IDs`)

任务状态以 `tasks.md` 为唯一事实源(V2:原 immutable task packets 已废止);本 gate 通过后任务方可 ready。

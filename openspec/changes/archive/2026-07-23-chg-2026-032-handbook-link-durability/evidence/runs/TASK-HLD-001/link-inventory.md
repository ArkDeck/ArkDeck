# TASK-HLD-001 逐条改写对照表 — 2026-07-23

> 由脚本从改写日志生成；`定位 blob` 均以 `git rev-parse HEAD:<path>` 于
> base `a7ee3f88634972cea4f3bb6622d2f6dab6ea6e06` 实测取得，未由短 hash 补全。

| # | AF 项 | 目标 change | change 目录内路径 | 定位 blob（完整 40-hex） | 括号形式 |
| --- | --- | --- | --- | --- | --- |
| L01 | `AF-001` | CHG-2026-026 | `evidence/runs/TASK-RKFUI-001/run.md` | `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3` | ID + 路径 + blob |
| L02 | `AF-001` | CHG-2026-006 | `tasks.md` | `779ff6ac060ab7ba82ddaf955b65702ec52285db` | 仅 blob（文字已含 ID+文件名） |
| L03 | `AF-001` | CHG-2026-022 | `proposal.md` | `63fa348e8f08276d17b1655532714d5da3a67482` | 仅 blob（文字已含 ID+文件名） |
| L04 | `AF-001` | CHG-2026-028 | `proposal.md` | `d7718251c074f3b23bb32f8703c863efc9912245` | 仅 blob（文字已含 ID+文件名） |
| L05 | `AF-002` | CHG-2026-022 | `review.md` | `d03118ab83cbeb278910c08e55573094edbd5169` | 仅 blob（文字已含 ID+文件名） |
| L06 | `AF-003` | CHG-2026-025 | `review.md` | `197e4adc47f75444a54eefadf00e58b4681e5202` | 仅 blob（文字已含 ID+文件名） |
| L07 | `AF-004` | CHG-2026-026 | `evidence/runs/TASK-RKFUI-001/run.md` | `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3` | ID + 路径 + blob |
| L08 | `AF-005` | CHG-2026-008 | `evidence/runs/TASK-UD-REDACTOR-001/run.md` | `172ea48fba64819d0bf0743816323b8da68b6ec3` | ID + 路径 + blob |
| L09 | `AF-005` | CHG-2026-026 | `evidence/runs/TASK-RKFUI-001/run.md` | `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3` | ID + 路径 + blob |
| L10 | `AF-006` | CHG-2026-028 | `proposal.md` | `d7718251c074f3b23bb32f8703c863efc9912245` | 仅 blob（文字已含 ID+文件名） |
| L11 | `AF-007` | CHG-2026-026 | `evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md` | `659f99f470cea5f03984de6ea28ce1395e391287` | ID + 路径 + blob |
| L12 | `AF-007` | CHG-2026-028 | `evidence/runs/TASK-MECH-001/run.md` | `f5e51fad2f2a429748126eee27ab61df282c2f23` | ID + 路径 + blob |
| L13 | `AF-010` | CHG-2026-022 | `review.md` | `d03118ab83cbeb278910c08e55573094edbd5169` | 仅 blob（文字已含 ID+文件名） |
| L14 | `AF-011` | CHG-2026-026 | `verification.md` | `f4aea707ded798680aacb7811a4786247a94dac8` | 仅 blob（文字已含 ID+文件名） |
| L15 | `AF-013` | CHG-2026-022 | `review.md` | `d03118ab83cbeb278910c08e55573094edbd5169` | 仅 blob（文字已含 ID+文件名） |
| L16 | `AF-015` | CHG-2026-026 | `evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md` | `659f99f470cea5f03984de6ea28ce1395e391287` | ID + 路径 + blob |
| L17 | `AF-016` | CHG-2026-028 | `evidence/runs/TASK-MECH-001/run.md` | `f5e51fad2f2a429748126eee27ab61df282c2f23` | ID + 路径 + blob |
| L18 | `AF-016` | CHG-2026-022 | `review.md` | `d03118ab83cbeb278910c08e55573094edbd5169` | 仅 blob（文字已含 ID+文件名） |
| L19 | `AF-017` | CHG-2026-008 | `tasks.md` | `abaee6a12290108f4daeac9f84a3ff6700971433` | 仅 blob（文字已含 ID+文件名） |

合计 **19 条**，落在 **11 个目标文件**。

## 取值命令

```text
git rev-parse HEAD:<openspec/changes/<chg-dir>/<inner-path>>
```

每个 blob 均以该命令于 implementation base 实测；无一由短 hash 补全（`AF-016` 防复发条款）。

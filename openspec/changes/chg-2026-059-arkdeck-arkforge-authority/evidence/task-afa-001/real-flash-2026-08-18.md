# AFA-AC-6/7/8 — 真机九分区 + 读域 + postflight（2026-08-18，real）

机器事实：本目录 [`EVD-AFA-DAYU200-20260818-001.json`](EVD-AFA-DAYU200-20260818-001.json)
（`hardware-evidence.schema.json` 6.0.0，已入
`openspec/verification/hardware-matrix.md` verified 行）。

一句话：`flash.dayu200` 首次端到端 `succeeded`——ArkDeck 物化计划、签发 23 张
单次 StepPermit、应答管控请求；`arkforged` 写九分区（写前 revalidate + 写线
摘要比对）、回读三态判定（2 Verified / 1 结构性 Failed / 6 TypedSkip）、自发
复位；postflight `exact-published-profile-and-bound-hdc`，设备答出被写入 bundle
声明的 `OpenHarmony-7.0.0.37`（AFA-AC-8 的"期望值来自写入镜像"原则成立）。

- 分类：**real**（真机 DAYU200，binding revision 4，destructive）。
- job：ArkDeck `job-a4b7d539571082b1958ebaaf2c14bd2c` / arkforged
  `JOB-000001A013991062`；台架一手存储路径与各 SHA-256 见 JSON。
- backend 注记：当日 daemon 为 fixed-tool 时代构建（AFA-AC-6 的 `wlx` 观测点
  即该面）；次日 vendor 运行时被 CHG-2026-063 移除，原生面复验为
  `EVD-NRU-DAYU200-20260819-001`（chg-2026-063 evidence）。
- 跨仓：ArkForge `docs/evidence/runs/2026-08-19-dayu200-green-flash-and-native-cutover.md`、
  ledger `AD-033`。

尚无记录：`crash-no-replay-<date>.md`（AFA-AC-9，写入中途 SIGKILL 未做）、
`cancel-not-safe-<date>.md`（AFA-AC-10 真机半未做）。

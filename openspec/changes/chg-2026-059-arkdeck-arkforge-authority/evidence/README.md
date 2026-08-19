# Evidence — CHG-2026-059

按 task 分子目录。每条记录**如实分类** simulation / real，不得把 plan-only
记成真机通过。

~~~text
evidence/
└── task-afa-001/
    ├── permit-vectors-swift.md        # AFA-AC-2：Swift 侧复现三组向量的输出
    ├── permit-adversarial.md          # AFA-AC-3/4：七项否定用例 + 重传
    ├── control-port-secret-scan.md    # AFA-AC-5：receipt/journal/UI 三处扫描
    ├── real-flash-<date>.md           # AFA-AC-6/7/8：真机九分区 + 读域 + postflight
    ├── crash-no-replay-<date>.md      # AFA-AC-9：写入中途 SIGKILL 后的 journal
    └── cancel-not-safe-<date>.md      # AFA-AC-10：写入中途取消被拒，非 unconfirmed
~~~

## 记录状态（2026-08-19）

`task-afa-001/` 已有首批 real 记录：
[`real-flash-2026-08-18.md`](task-afa-001/real-flash-2026-08-18.md)
（AFA-AC-6/7/8，机器事实
[`EVD-AFA-DAYU200-20260818-001.json`](task-afa-001/EVD-AFA-DAYU200-20260818-001.json)，
已入 `openspec/verification/hardware-matrix.md` verified 行）。
AFA-AC-2/3/4/5 由 ArkDeckKit contract tests 持续守卫。**尚缺**：
`crash-no-replay-<date>.md`（AC-9）与 `cancel-not-safe-<date>.md`（AC-10 真机半）。

## 跨仓引用

本 change 的**依据**在 ArkForge 仓，不复制到这里，以免两份漂移：

| 内容 | 位置（ArkForge 仓） |
|---|---|
| 2026-08-15 真机彩排（读域三态、九条写入降解、设备写入 0） | `docs/evidence/runs/2026-08-15-dayu200-flash-rehearsal.md` |
| 2026-08-18/19 首过与原生换轨（两次全量 `succeeded` + backend 归属；AD-033） | `docs/evidence/runs/2026-08-19-dayu200-green-flash-and-native-cutover.md` |
| AD-006/AD-016…AD-020 证据条目 | `docs/evidence/ledger.md` |
| AF-V2 验收现状（§6 后记：第一验收项已通过，余项逐条标注） | `docs/evidence/AF-V2-acceptance.md` |
| permit 向量的生成与守卫 | `crates/arkforge-authority-api/tests/permit_vectors.rs` |
| 控制动作映射表与 ArkDeck action 归属表 | `adapters/arkforge-arkdeck-adapter/src/control.rs` |
| 签名/entitlement/打包契约与三份工具的可出厂性（AD-023） | `docs/decisions/AFD-0003-arkforged-signing-packaging.md` |

引用时请记 ArkForge 侧的 commit：本 change 写作时为
`26b0d86 docs(AF-V2.5): write the acceptance document while it still says "not accepted"`；
2026-08-16 的基线复核（design 第 9 节）对着 `d637a2e feat(AD-022): prove the bound tool
runs, not just that its bytes match` 加上其后的 AFD-0003 / AD-023 一批改动。

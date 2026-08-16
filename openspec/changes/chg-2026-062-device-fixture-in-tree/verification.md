# Verification Plan

> Change:CHG-2026-062-device-fixture-in-tree@r1
> Status: proposed；本文件不声称任何 merge 结论。下表标注「已实测」的条目是在 fixture
> 尚未入库、仍位于未跟踪工作目录时取得的真实结果，用以证明该 Task 可交付；入库 PR
> 仍须重跑并附 evidence。

| AC | Method | Pass condition |
|---|---|---|
| DFX-AC-1 | 仓库内 hvigor `assembleHap` + `git diff --cached` 扫描 | 产出 `entry-default-unsigned.hap`；diff 中无签名材料、无构建产物、无 `oh_modules`、无绝对路径 |
| DFX-AC-2 | `MODE = crashProbe` 部署后观察 HiLog 与进程 | 出现 `crash probe armed` 与 `crash probe firing`；进程在约 12 s 后消失 |
| DFX-AC-3 | `MODE = traceWorkload` 部署后读 `/proc/<pid>/stat` 两次 | 出现 `crash probe disabled: fixture is in traceWorkload mode`；进程存活 >30 s；单核占用约 2–3% |
| DFX-AC-4 | `agentd update` 后 `agentd status` + `operation list` | `workspaceProjectPath` 为新路径且 `ready`；`workspace.sign-openharmony-hap@1` 为 `available` |
| DFX-AC-5 | `artifact import-hap → sign → debug.hap@1` | 三个 job 全部 terminal success |

## 已实测（fixture 入库前，位于未跟踪目录时取得）

- **DFX-AC-1**：清空 `signingConfigs` 后 `assembleHap` 成功，只产出 unsigned HAP；
  暂存 68 个文件，扫描 `keyPassword|storePassword|-----BEGIN|/Users/` 命中 0 处。
- **DFX-AC-2**：`crashProbe` 模式部署后进程在约 12 s 后消失；HiLog 留下
  `F A00000/ArkDeckCrashProbe: crash probe firing`。
- **DFX-AC-3**：`traceWorkload` 模式部署后 HiLog 出现
  `I A00000/ArkDeckCrashProbe: crash probe disabled: fixture is in traceWorkload mode`；
  进程存活 >35 s，8 秒窗口内 21 个 CPU tick，约合单核 2.62%。
- **DFX-AC-4**：`agentd update --workspace-project <仓库内路径>` 连同 `--harness-model-*`
  重传后成功；`workspaceProjectPath` 为新路径、`ready: true`、daemon SHA 未变、
  `workspace.sign-openharmony-hap@1` 仍为 `available`。
- **DFX-AC-5**：`import-hap` → `sign`（`job-f39207bb…`）→ `debug.hap@1`
  （`job-63454075…`）全部 succeeded。

## 负例矩阵

- 只传 `--workspace-project` 而不重传 `--harness-model-*` → 必须被
  `Harness local CLI working directory must be the validated demo-app project` 拒绝（已实测）；
- 声明本 Task 的 diff 触及 `tests/**` 以外的生产路径 → `check_pr_paths.py` 必须拒绝；
- 签名口令或私钥进入 diff → review 前必须被发现；
- 重新引入可与 `MODE` 并存的模式布尔量 → 视为回归。

## 未覆盖

- fixture 不进入任何 CI 编译车道，因此本 change 不产生 CI 时长或缓存影响；
- 崩溃 journey 的端到端复验属 GJ-5 既有验证范围，不在本 change 内重复声称。

# Tasks

## TASK-DFX-001 — Bring the device fixture in tree under a single mode selector

- Status:ready（路径权限尚未获批；在维护者 merge 本 change 之前，任何交付 PR 都不得
  声明本 Task）
- Platform:macos
- Requirements:DFX-REQ-001, DFX-REQ-002, DFX-REQ-003
- Acceptance:DFX-AC-1..DFX-AC-5
- Depends on:无（不依赖任何未合并的 Task）
- Golden Journey:GJ-5 Bounded AI Debug Loop
- Base-tree path task:无——本 Task 请求的正是此前不存在的 `tests/**` 权限，
  因此它必须先经维护者批准合入，才能被后续交付 PR 使用
- Production reachability:`WorkspaceOperationsProvider.waterFlowDemo → workspace.build-openharmony@1
  → workspace.sign-openharmony-hap@1 → debug.hap@1`
- Hardware required:yes（DAYU 200；部署与模式验证需要真机）
- Allowed paths:
  - `tests/**`
  - `openspec/changes/chg-2026-062-device-fixture-in-tree/**`
  - `evidence/runs/TASK-DFX-001/**`

### 交付内容

1. 把既有 fixture 工程按原样纳入 `tests/waterflow-demo/`，不改变 Runtime 已 pin 的任何
   identity：`entry@default` target、`entry/build/default/outputs/default/entry-default-unsigned.hap`
   产物路径、`com.example.waterflowdemo` / `EntryAbility`、崩溃签名
   `SIGABRT+WaterFlowCrashProbe_RecoverBack`。
2. 把 crash probe 与 trace workload 收敛为 `entry/src/main/ets/fixture/FixtureMode.ets`
   中的单一互斥选择器 `MODE`，默认 `crashProbe`。
3. `build-profile.json5` 的 `signingConfigs` 提交为空数组；`.gitignore` 覆盖构建产物、
   `oh_modules`、`local.properties` 与一切签名材料。
4. README 记录 Runtime 耦合点，以及重指 workspace 时必须同时重传 `--harness-model-*`
   这一非显然约束。

### 明确不做

- 不修改 Runtime、Provider、Catalog、operation 或 capability 逻辑；
- 不改变 `bundleName`；
- 不把 fixture 接入任何 CI 编译车道。

## 验收

- **DFX-AC-1**：`tests/waterflow-demo` 可用仓库内的 hvigor 调用构建出
  `entry-default-unsigned.hap`，且工作树中不存在任何签名材料或构建产物被跟踪。
- **DFX-AC-2**：`MODE = crashProbe` 时进程在启动约 12 s 后 abort，HiLog 出现
  `crash probe armed` 与 `crash probe firing`。
- **DFX-AC-3**：`MODE = traceWorkload` 时进程存活超过 30 s，HiLog 出现
  `crash probe disabled: fixture is in traceWorkload mode`，且进程稳定占用单核约 2–3%。
- **DFX-AC-4**：`agentd update --workspace-project tests/waterflow-demo`（同时重传
  `--harness-model-*`）之后，`agentd status` 报告新的 `workspaceProjectPath` 且 `ready`，
  `workspace.sign-openharmony-hap@1` 保持 `available`。
- **DFX-AC-5**：`artifact import-hap → workspace.sign-openharmony-hap@1 → debug.hap@1`
  可从新路径完成部署，job 全部 terminal success。

## 负例

- 声明本 Task 的 diff 若触及 `tests/**` 以外的生产路径，`check_pr_paths.py` 必须拒绝；
- 任何签名材料或 `keyPassword`/`storePassword` 进入 diff，必须在 review 前被发现并拒绝；
- `MODE` 之外再引入可独立开关的模式布尔量，视为回归——两种用途必须互斥。

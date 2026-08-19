# TASK-AND-002 — run r1（2026-08-19 05:18–05:40 UTC）

> headless 外部 agent 会话第一跑：取证半环 + 负向用例 **PASS**，修复腿被产品缺陷
> **诚实阻断**（0/5 干净样本）。缺陷已在同任务内修复（见「暴露的缺陷与修复」），
> r2 复跑见 `run-r2.md`。本文件不宣称 GJ-5 任何状态翻转。

## 会话形态

- headless 外部 agent（Claude Agent SDK 会话），无人值守；宿主侧仅允许
  `arkdeck` CLI 与只读工具；任务书明令 `task.*` 归零。
- Target `TGT-958780b2ffb7`（DAYU200，binding revision 4，OpenHarmony-7.0.0.37）；
  catalog digest `d76ad7750eeb39423de804fffca2ff262edec39fac41638b487571f2cd9bad9e`。
- 台账快照：HTASK 56 前==56 后（无任何 task 平面活动）；durable job
  1184 → 1185（+1 = 本会话自己的一次 deliberate retry，见下）。

## 已闭合：复现与根因（真机证据链）

`FixtureMode.ets:29` 置 `MODE = FixtureMode.crashProbe`，`EntryAbility.
onWindowStageCreate` 因此武装 `CrashProbe.ets` 的 12 000 ms 定时器，到点执行
`triggerNativeCrash()`（`CrashProbe.ets:30:16`）。本构建以 **jscrash**（TypeError:
`Cannot read property triggerNativeCrash of undefined`）形态死亡而非设计中的
cppcrash——install-readback 证明部署包 `nativeLibraryFileCount: 0`，
`libcrashprobe.so` 未随包，native 模块未注册（`ModuleName:crashprobe
Reason:app lib path not registered`）。武装即崩溃的因果两种形态同源。

| 证据 | Artifact |
| --- | --- |
| armed 行 hilog（`crash probe armed: aborting in 12000 ms`） | `ART-abe3c66ee1db91087a5be6f813d1485d`（job-bbae17bd） |
| firing 行 + 崩溃（+12 000 ms 整） | 同上 hilog 与 faultlogger 记录 |
| jscrash 记录 `jscrash-com.example.waterflowdemo-20010045-20170820204529` | `ART-d37318f31f99954e5e810aac2923bbda`（job-214d06c7） |
| crash index + liveness（UNHEALTHY / targetProcessNotRunning） | `ART-ee4ef979bef05784b14e0216654c26d7`、`ART-98818375a6dbc0f3732cb003ee204adf`（job-e34a547a） |
| 派生 crash-signature（`status: answered`） | `ART-08dd70f8e140044a2fb740f7d702e4e6`（job-ee1b6c9e） |
| 部署字节核对（deployedArtifactSha256 == signed.hap） | `90691be325eb7bd0e82ff745588115208c1f8d8a1c4f29f2ce627578d5900a01` |

机制教训（进 r2 任务书）：崩溃在启动后 12 s 才发生，默认「停止+卸载」的
debug.hap 流程观测不到它；必须 `postRunAbilityState: running` + `cleanupPolicy:
retain` 才能见证（round 1 因此空手，round 2 抓到）。

## 已闭合：AND-AC-6 负向用例（防陈旧闸与决策宿主无关）

- 请求：`workspace.apply-patch@1`，真实补丁 lease
  （`ART-108b4f4f2da5520ebe28e6700f1b642d`，sha `1958e6bf…`），
  `expectedWorkspaceRevision` 故意取 2026-08-15 的陈旧值 `952a688b…`。
- 拒绝原文：`rejected(invalidInput, "typed plan preflight failed before
  authorization: workspace.revisionConflict:952a688b8c80!=701c5bd95612")`，
  CLI exit 1，无 jobId。
- 零派发证明：durable job 计数拒绝前 1184 == 拒绝后 1184；台账中最新
  `workspace.apply-patch@1` job 仍为 2026-08-11。
- 附加隔离证明：同一请求仅改 revision 为新鲜值后，落在**authorization** 闸
  （`rejected(authorizationRequired, …)`）——防陈旧闸（更早）与授权闸
  由一对只差一个字段的请求分离实证。

## 诚实阻断：修复腿 0/5

- 自主源码修复的引擎既定路线 = `workspace.prepare-isolated-copy@1` →
  `evolution-*` 派生 profile → runtime default policy 授权（主树 standing
  grants 已全部于 2026-08-04/05 过期，符合设计）。
- 该制备在真机环境**确定性失败**：`EvolutionWorkspaceManager.copyIsolatedTree`
  对**绝对**符号链接目标无条件拒绝（相对分支有「解析后在源树内」判据，绝对
  分支没有），而 hvigor 2026-08-17 构建在 demo 树留下恰一条绝对链接
  （`entry/build/default/outputs/default/symbol/release/arm64-v8a` →
  同树 `intermediates/libs/default/arm64-v8a`；位置经维护者会话实测校正，
  agent 初报差一层目录）。两次失败 job（job-6ca5c668、job-0c013b26 单次
  deliberate retry）各留一个空 taskRoot，revision/scope 检查均已通过，
  拒绝可复现。
- 次生缺陷：`RuntimeOwnedWorkspaceDispatcher.dispatch` 把带树内相对路径的
  typed 错误塌缩成裸字符串 `workspace isolation refused`——「没测到」族
  （错误细节存在但不可见）。
- agent 依任务书在诚实边界停下：不写仓库、不铸授权、单次重试后如实报告。

## 暴露的缺陷与修复（同任务垂直交付，随本 PR）

1. `EvolutionWorkspaceManager.copyIsolatedTree`：绝对/相对符号链接统一为同一
   判据（解析后须在源树内）；被采纳的绝对链接在重建时**改写为等价相对链接**
   ——「副本不得引用主树」不变量保持，且新增「删除主树原文件后副本仍可读」
   的自包含断言。原「绝对一律拒绝」契约测试改写为
   `testEvolutionWorkspaceRewritesAbsoluteInSourceSymlinkToARelativeLink`，
   另增树外绝对链接具名拒绝用例。
2. `RuntimeOwnedWorkspaceDispatcher`：`EvolutionWorkspaceError` 透传 typed
   细节（仅树内相对路径/refs/revisions/reason token，无宿主路径）；新增端到端
   测试 `testIsolationRefusalNamesTheOffendingEntryWithoutHostPaths` 同时断言
   「具名」与「无宿主路径」。
- 定向测试 24/24 全绿；修复后 daemon 由维护者以既有签名流程于
  2026-08-19 14:12（本地）部署（codesign timestamp 为证）。

## 纪律面

- `task.*` 调用数：**0**（HTASK 台账 56==56 + 会话 transcript 机械核验）。
- raw 设备命令：**0**（无 hdc/git；设备只经 typed job）。
- 仓库文件写入：**0**（全部写入位于会话专属 scratch）。
- 预算：debug rounds 2/8；E1 mutation jobs 3/12；同一失败步重试 1/2。
- 会话遗留设备状态：崩溃构建仍安装、进程已死（`retain` 为观测所必需）；
  faultlogger 记录留存。r2 的部署流程会覆盖安装。

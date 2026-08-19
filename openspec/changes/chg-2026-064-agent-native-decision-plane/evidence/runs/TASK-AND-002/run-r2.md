# TASK-AND-002 — run r2（2026-08-19，修复后 daemon）：REAL_DEVICE_PASS

> headless 外部 agent 会话第二跑，在一次会话内闭合完整修复腿闭环：
> 复现 → 分析 → 隔离副本修补 → 重建 → 签名 → 部署 → **五个干净样本** → 负向用例。
> 循环内人工步骤 **0**，`task.*` 调用 **0**。GJ-5 按 proposal「判据重述」节
> 记 `REAL_DEVICE_PASS`（当前 catalog digest
> `d76ad7750eeb39423de804fffca2ff262edec39fac41638b487571f2cd9bad9e`）。

## 会话形态与底座

- headless 外部 agent（Claude Agent SDK 会话），任务书与 r1 同构；宿主侧只许
  `arkdeck` CLI 与只读工具。r1 的三条机制教训（12 s 崩溃窗需 `running`+`retain`
  观测、隔离副本是自主修复既定路线、`import-workspace-patch` 属许可面）注入
  任务书；根因分析、补丁设计、全部执行仍由会话独立完成。
- Target `TGT-958780b2ffb7`（DAYU200，binding revision 4）；daemon 为携
  r1 修复的构建（维护者 2026-08-19 14:12 本地签名部署，codesign timestamp 为证）。
- durable job 台账 1185 → 1210（25 个 job 全数在下表）；HTASK 台账 56 == 56。

## 根因（较 r1 深一层：设备侧共因）

app 侧缺陷同 r1：`FixtureMode.MODE = crashProbe`（`FixtureMode.ets:29`）使
`EntryAbility.onWindowStageCreate` 的 `loadContent` 回调调用 `armCrashProbe()`
（`EntryAbility.ets:33`），12 000 ms 定时器到点执行 `triggerNativeCrash()`
（`CrashProbe.ets:30`）。**设备侧共因**（r2 新证）：该 DAYU200 镜像的
`const.product.cpu.abilist` 为 `default`（损坏值），BMS 因此不为任何应用注册
native library——install-readback `cpuAbi:""`、`nativeLibraryPath:""`、
`nativeLibraryFileCount:0`；`libcrashprobe.so` 导入得 `undefined`，定时回调抛
未捕获 `TypeError: Cannot read property triggerNativeCrash of undefined`，
faultlogger 记为 jscrash（`…-215039`，`Foreground:Yes`）。armed→firing 两行
hilog 相距恰 12 000 ms（设备钟 21:50:27.651 → 21:50:39.652）。

复现证据束：`ART-84593f18…`（install-readback）、`ART-c111c0d9…`（hilog）、
`ART-bc3a46f6…`（liveness UNHEALTHY/targetProcessNotRunning）、
`ART-a3190402…`（jscrash 记录）、`ART-768d1284…`（crash-signature，answered）。

## 修复（隔离副本路线，r1 修复的制备闸首次生产实证）

- `workspace.prepare-isolated-copy@1` **成功**（job-f7bbc8f5），派生
  `evolution-360b54f898e2575df90f`——r1 阻断此步的绝对 symlink 缺陷修复
  生效于生产 daemon 的直接证据。
- 补丁经 `artifact import-workspace-patch` 导入（`ART-31b592b4…`，
  sha `46474c13…`，606 字节）后由 `workspace.apply-patch@1` 应用
  （job-86ac5cd6，revision `701c5bd9…` → `aed6966b…`）。**补丁形态优于 r1
  草案**：只删除武装调用及其 import（`EntryAbility.ets` 两处，共 -3 行），
  不翻转 `MODE`——翻转会启用 traceWorkload 的 500 ms 全量重载驱动、改变
  demo 行为，被会话自行判为非最小修复而拒绝。fixture 两文件与 WaterFlow
  行为零触碰。
- 重建（job-3f713416，unsigned `ART-db936f4f…`）→ 签名（job-a712f938，
  signed `ART-bc933650…`，sha `bc1d92a0…`）→ 部署。

## 五个干净样本（部署字节 = 修补构建，五样全 HEALTHY，faultlogger 冻结在修复前两条）

| 样本 | 启动 job | 崩溃窗后观测 job | liveness（HEALTHY/RUNNING） | crash-index（不变） |
| --- | --- | --- | --- | --- |
| 1 | job-f8f77c24 | job-af11b551（+~32 s） | `ART-dc9b4bfe…` | `ART-831a7a81…` |
| 2 | job-a2f8fd37 | job-d168fbc3（+~20 s） | `ART-073b25aa…` | `ART-92003723…` |
| 3 | job-1ef639ec | job-ca1d5513（+~21 s） | `ART-c033be1a…` | `ART-5a689bb5…` |
| 4 | job-7fda73a9 | job-c085acc2（+~21 s） | `ART-61c42aa0…` | `ART-f7fe28ea…` |
| 5 | job-703dfd61 | job-1a352554（+~20 s） | `ART-b9b243a4…` | `ART-4a01a79b…` |

样本 1 的 install-readback 把部署字节钉到
`bc1d92a0f2d43376e5262dc15b11bd36d9403761d5b79904014b1680bc30c8dc`
（= 修补后 signed.hap）。崩溃窗 12 s，每样观测 ≥20 s。

## 负向用例（AND-AC-6，第二次独立通过）

- 请求：`workspace.apply-patch@1` @ `evolution-360b54f8…`，同一补丁 lease，
  `expectedWorkspaceRevision` 取已被 `aed6966b…` 取代的 `701c5bd9…`
  （applied-patch 记录 `ART-7aa1af28…` 载明其为 previousWorkspaceRevision）。
- 拒绝原文（CLI exit 1）：`rejected(invalidInput, "typed plan preflight failed
  before authorization: workspace.revisionConflict:701c5bd95612!=aed6966b7d36")`。
- 零派发：job 台账前后 1210 == 1210，全量 jobId 集合 diff `LEDGER-IDENTICAL`；
  无 capability 消耗。防陈旧闸在 admission、先于授权、与决策宿主无关——两跑
  三个不同 revision 组合一致。

## 预算与纪律（会话自报 + 编排会话机械复核）

- debug rounds 6/8（1 复现 + 5 复验）；E1 mutation job 11/12；同一失败步
  原样重试 0。
- `task.*` 调用 **0**：① HTASK 台账 56==56（diff 为空）；② transcript 内
  `arkdeck task` 字符串命中仅 1 处 = CLI usage 帮助文本（未执行）；③ 会话
  全部 Write/Edit 目标经枚举均在其专属 scratch（补丁与 request JSON），
  仓库文件写入 **0**。
- raw 设备命令 **0**（无 hdc/git）。申报的偏差：一次复合命令含 shell 内建
  `cd`（只读定位源码），未执行白名单外程序。

## 如实登记的环境残留（非本补丁引入，不冒充绿）

- `workspace.run-tests@1` 失败（job-57f7bcc2，`workspace.testsFailed`
  exit 255）：hvigor `UnitTestArkTS` 解析不到 `@ohos/hypium`——当日树内
  无 `oh_modules` 依赖库（`--untracked-files=all` 为空），2026-08-15 最后一次
  成功跑在旧目录布局 + 本地库仍在时。失败面为宿主侧单测；补丁触碰文件集
  （恰 `EntryAbility.ets`）与之不相交；无已发布 operation 安装 ohpm 依赖，
  会话未越权改装。跟进项：为 demo-app 恢复依赖库或发布 typed 依赖安装面。
- 首次 analyzer 调用喂了 faultlog 记录体，`unreadable: ledgerHeaderAbsent`
  ——analyzer 合约要 crash-index 形态；第二次即 `answered`。诚实三态在生产
  路径工作正常。
- 设备终态：修补构建已安装、进程存活（`retain`+`running`）；faultlogger 保留
  修复前两条历史 jscrash。补丁向主树的晋升走维护者 review PR（本会话许可面外）。

## 判据映射

- AND-AC-4 ✅（一次会话闭合含修复腿闭环，循环内人工 0，复验以设备 readback/
  产物为证）；AND-AC-5 ✅（纯已发布面、task.* 0、E1 均对应 admission 铸造/
  核销的 capability、三层预算在位：agent 会话预算 / capability 预算 /
  allowed-paths+revision 准入）；AND-AC-6 ✅（具名拒绝 + 零派发，两跑复现）。
- GJ-5：`REAL_DEVICE_PASS`（重述判据，当前 catalog digest）。旧判据（内嵌
  宿主）的历史 PASS 记录不改写。

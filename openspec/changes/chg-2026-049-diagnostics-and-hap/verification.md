# CHG-2026-049 Verification Plan

> 产品闭环兼容说明（2026-07-30）：当前 E1 生产路径由 Runtime 按已发布
> Catalog 自动签发 durable capability，不再等待人工文件或 review；target、
> binding、typed inputs、plan digest、lineage 与 `outcomeUnknown` 门保持。
> 下文 r2 的人工 capability 步骤是历史计划；E2 不变。

> Change:CHG-2026-049-diagnostics-and-hap@r9
> Status:planned
> Core baseline:CORE-2.1.0 (canonical Core AC not claimed)

## Environment

- contract/fake 面:protected-main checkout,macOS arm64;fixture 工具
  (`ArkDeckFakeHDCFixture`)经 descriptor 绑定 dispatcher 真实 spawn;
- realHardware 面:Device Runtime Agent + DAYU200 + 安装态 HDC 3.2.0f;
  Agent 执行全部 host Runtime 调用,人类仅作为 `physicalAssistant`;
  `DHA-HW-002` 另需维护者经 merged PR 签发的 E1 RuntimeCapability;
- 设备原始日志/trace/dump 永不入仓;E2 面对本 change 全程禁止。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `DHA-AGENT-001` | one-shot Agent runner contract + fake daemon integration | Agent 经 typed daemon API 完成 doctor→adopt→submit/wait→artifact query;不接触 HDC/argv/shell;需要设备信任或目标选择时产出 structured humanAction 并可恢复;receipt 如实记录 executor/authority/job/binding,Agent surface 无 capability 管理入口 | contract |
| `DHA-ART-001` | artifact 模型契约 + 安全负向 + GC/quota 矩阵 | 元数据完整(含 hash/privacy/retention/binding snapshot);客户端只能按 ID/lease 访问,路径不可指定;path traversal/symlink 逃逸被拒;GC 不删 active/pinned;quota 逼近时拒新采集而非破坏既有;`observe.device@1` 四 artifact 真正落盘且可读 | contract |
| `DHA-CAP-001` | capture.diagnostics@1 编排契约 + effective-effect/部分失败/取消/预算矩阵 | 不含 remote trace 的 plan 走 E0;选择 remote trace/cleanup 的 plan 在 dispatch 前升为 E1且缺 capability 零 dispatch;产物缺失逐项标注;cancel/预算/cleanup debt 均有界 | contract |
| `DHA-HAP-001` | debug.hap@1 编排契约 + E1 授权/补偿矩阵 | install 成功仅由 **package readback** 判定、start 成功仅由 **process/ability readback** 判定(exit 0 + 无 readback ⇒ 不得 succeeded);缺/错 capability fail-closed;失败按 cleanup policy 补偿;unknown 即停后续 mutation 并 reconcile;HAP 只能来自 artifact lease | contract |
| `DHA-HW-001` | Device Runtime Agent:真机 E0 capture.diagnostics@1 | Agent 一次执行产出只读 artifact 集合并经 `artifact.*` 读取;receipt 记录 executor=agent/default-readonly authority;除结构化 physical assistance 外零人工 host 命令 | realHardware(Agent 执行后补记) |
| `DHA-HW-002` | Device Runtime Agent + 维护者签发的 E1 capability:真机 debug.hap@1 | Agent 一次执行 install→start→capture→stop;readback 齐全;capability 消耗一次;缺 capability 零 dispatch;人类不代跑 host CLI | realHardware(Agent 执行后补记) |
| `DHA-GJ4-PROFILE-001` | v2 profile/Catalog/Provider drift contract + real archive summary | archive 与 17 members 的 size/SHA-256 全匹配；Catalog 只开放 dayu200@1/@2；Provider 对 v2 exact 九分区成功，换序和跨版本 archive 拒绝 | contract + realInput |
| `DHA-GJ4-PLAN-002` | RuntimeJobEngine.planOnly + job.plan wire contract | 复用生产 materialization 产出 digest/选中步骤；不建 Job、不创建/安装/消费 capability、dispatch=0；错误 plan 同样零副作用 | contract + realInput |
| `DHA-GJ4-HANDOFF-003` | v2 human handoff + trusted execute profile selection contract | human execute 生成 v2 exact commands 且 dispatch=0；authorized path 只按 archive pins 选择 profile，unknown/member drift 拒绝；executor 在授权消费前拒绝无匹配 profile | contract + realInput |
| `DHA-GJ4-TRIGGER-004` | versioned Bash trigger source contract + host-only negative execution | wrapper 固定 v2 archive/tool/plan/step-set，chat 需 full digest + AUTH-ID；CI、截断 digest、non-TTY interactive 全部在 host prerequisites 前阻断；唯一执行委托为 typed trusted executor | contract |

## `DHA-AGENT-001`

- runner 只组合 `ArkDeckAgentClient` 的 health/target/job/artifact typed
  方法;无 executable、argv、shell、raw HDC 或任意路径输入;
- 单次 run 最多提交一个已发布 operation,具有总 timeout、轮询上限与
  cancellation;不是多轮 AI debug loop;
- unauthorized/offline 或多候选返回 closed `humanAction`(trustDevice /
  selectTarget / physicalReconnect),持久化 resume token;恢复后沿同一
  target/binding 继续,不得重建或猜选;
- receipt 至少记录 executor=`agent`、operation@version、jobID、
  targetID/binding revision、catalog digest、E0 default-policy reference
  或 E1 capabilityID、humanAction 时间线、terminal state;
- agent-facing surface 只允许 capability reference/list/inspect/use,
  不允许 install/create/modify/revoke 或提交 capability JSON。

## `DHA-ART-001`

- 元数据:每个 artifact 具 ID、session/job/step、media type、size、
  SHA-256、created time、provider、target binding snapshot、source
  operation@version、privacy class、retention deadline;
- 访问面:`artifact.list/inspect/read/export` 只接受 artifact ID;
  任意路径参数在协议层不存在(结构性);`read` 有界;
- 安全负向:`../` 穿越、symlink 逃逸、跨 session 覆盖各一条红路径;
- 生命周期:GC 跳过 active job 引用与 pinned;retention 到期可回收;
  quota 逼近 → 新采集被拒且既有 artifact 完好;
- redaction:默认对 token/credential/host path 做基础脱敏,原始高敏
  artifact 显式标记且需授权访问;
- `observe.device@1` 端到端后四 artifact(device-facts/tool-facts/
  binding-snapshot/manifest)可 list/inspect/read,manifest 含 catalog
  digest 与 provider/tool/device facts。

## `DHA-CAP-001`

- 授权先于 dispatch:引擎按实际选中步骤的最大 effect 生成 plan effect;
  `traceCategories` 为空/缺省且无 remote temp/cleanup → E0;
  `traceCategories` 非空、remote capture 或 cleanup 被选中 → E1,
  无匹配 capability 时所有 provider dispatch 计数为 0;
- 编排:preflight → hilog → ui-dump → trace → receive → 校验 → 索引 →
  cleanup → finalize,步骤顺序与 catalog 声明一致;
- **部分成功**:trace 缺失时 `capture-summary.json` 与 job 结果逐项标注
  该 artifact 状态,整体不得记 succeeded-with-all;
- cancel:运行中取消 → 停止仍在跑的采集、在安全边界收取已完成 artifact、
  状态为 cancelled(非 failed 亦非 succeeded);
- 预算:超总 byte budget → 有序截断并标注,或失败;两种都不得写满磁盘;
- 远端:temp 路径由 provider 铸造;清理失败 → cleanup debt 记录并可被
  后续 reconcile 消费(测试驱动一次消费)。

## `DHA-GJ4-PROFILE-001`

- 候选 archive 固定为 size `730769584`、SHA-256
  `6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e`；
- 对实际 gzip tar 单遍汇总，17 个 member 的 name/size/SHA-256 必须与
  `dayu200@2` pin 全等；缺失、额外、重复或任一 byte/hash 漂移均 blocked；
- Catalog `flash.dayu200@1.deviceProfile` 与 `profiles` 同时列出 v1/v2；v1 默认行为不变；
- Provider 对 v2 Artifact exact facts 只接受九分区 offset 顺序；reverse order 与
  v2 lease + v1 profile 各一条负向，均在 action/lowering 前拒绝。

## `DHA-GJ4-PLAN-002`

- `job.plan` 接受完整 typed request file，调用与 submit 相同的 input validation、
  target facts、Artifact lease binding、provider action/lowering materialization；
- 返回 `executionMode=planOnly`、catalog/plan/request digest、target binding 与选中步骤，
  且 `jobAdmitted=false`、`dispatchDisposition=notDispatched`；
- plan-only request 携 capability reference 必须拒绝；成功与失败均不产生 Job、
  capability/usage/idempotency 记录，也不调用 `RuntimeProcessDispatching.dispatch`；
- real-input gate 使用 sealed facts 与“调用即失败”的 dispatcher；执行期间禁止
  USB/HDC/RockUSB，禁止 E2 capability 与真实 Flash，结果分类为 realInput/hostOnly，
  不得记为 realHardware。

## `DHA-GJ4-HANDOFF-003`

- human execute 显式选择 `dayu200@2` 后，execute plan 的 archive、plan digest 与 step-set
  digest 必须来自 v2；handoff 只能含 `ld`、`ppt`、九条顺序固定的 `wlx` 与 `rd`，
  ArkDeck dispatch snapshot 保持 0；
- authorization-ID 路径拒绝 caller-supplied `--device-profile`，trusted fact port 只按实际
  archive size/SHA-256 选择 published profile，并对 17 个 member 再校验；未知 archive
  与任一 member hash 漂移均为 `archiveValidationFailed`；
- admitted execute plan 必须在 persistence、authorization consumption 与 staging 前匹配
  executor 的 published profile 集合；无匹配时关闭 reservation，零 destructive intent；
- real-input CLI gate 只能运行到 non-TTY policy-blocked human handoff，验证 v2 execute
  digest/commands 后停止；不得连接设备、读取 standing authorization 或执行 handoff 命令。

## `DHA-GJ4-TRIGGER-004`

- script source contract 逐字断言 7.0.0.35 archive/tool SHA-256、execute plan digest 与
  step-set digest，且最终 delegation 只包含 fixed ArkDeck binary、`flash execute`、archive、
  durable-binding topology 与 strict authorization ID；禁止 `eval`、`sudo` 或直接执行 tool；
- `--chat-trigger` 必须携完整 exact plan digest，截断或任一 byte 漂移均在 archive、binding、
  defaults 与 binary 读取前退出 2，`READY` 不得出现；
- `CI=true`/GitHub Actions 即使持 exact digest 也在同一位置拒绝；interactive trigger 在无 TTY
  时同样拒绝；以上 contract 进程不连接 USB/HDC/RockUSB，不产生任何 device dispatch；
- 正式执行仍由 protected-main resolver fresh 解析 `AUTH-ID`。聊天只表示本次触发意图，缺失、
  过期、超次或任一 plan/target/tool fact 不一致时 trusted host 保持零 destructive dispatch。

## `DHA-HAP-001`

- 成功判定:构造"install exit 0 但 package readback 查不到"→ 结果不得
  succeeded(红路径);"start exit 0 但进程不存在"→ 同上;
- 授权:无 capability → 零 dispatch;capability scope 不含 `debug.hap@1`
  或 target 不匹配 → 拒绝;过期/撤销/耗尽 → 拒绝;一次授权覆盖整个
  recipe(不逐 step 消费多次);
- 输入:HAP 只能来自 artifact lease;本地任意路径被拒;
- 补偿:install 后 start 失败 → 按 cleanup policy 停止/卸载/恢复,并
  记录补偿结果;
- unknown:任一 mutation 步 unknown → 立即停止后续 mutation、进入
  reconcile、零自动重放。

## DHA-HW-001 / DHA-HW-002

- Device Runtime Agent 启动/连接 daemon,执行 doctor、target
  list/adopt、job submit/wait/status 与 artifact query;人工复制粘贴这些
  host 命令不能满足本 AC;
- 人类 `physicalAssistant` 只可完成设备屏幕信任、多候选物理确认或
  拔插,每次均作为 structured humanAction 记录;不成为 executor;
- `DHA-HW-002` 的 E1 capability 由维护者经 merged PR 签发,Agent 不得
  创建/修改/批准;Agent 只引用 capability ID,receipt 如实记录消耗;
- `DHA-HW-001` 使用不选择 remote trace 的 E0 plan;remote-file trace/
  cleanup 的真机执行必须另持 E1 capability,不得混入 E0 证据;
- 连接键/序列号脱敏入仓;raw 采集产物留 daemon 私有目录;
- 任一步失败如实记 blocked-attempt,不降级、不以 fixture 顶替。

## `DHA-RES-001` 残留被记录,两条路径同等

- 方法:scripted dispatcher 让 `cleanup-uninstall` 的 readback 判定为
  `uninstallIneffective`,分别在(a)正向路径与(b)补偿路径(先让 `start-ability`
  失败以触发 `compensateDebugHAP`)下断言:该 job 出现一条未结清残留记录,
  其持久化 action 就是 `.uninstallPackage(<bundle>)`,理由非空;
  且既有远端路径债务的记录行为逐条不变(同一套测试对 `cleanup-remote-staging`
  失败仍断言原有记录)。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —
  `testIneffectiveUninstallIsRecordedAsResidueOnTheForwardPath` 与
  `…OnTheCompensationPath` 分别断言两条路径都记录残留:`bundleName` 为该 bundle、
  `identity` 为 `bundle:<name>`、`remotePath` 为空(bundle 残留不指向路径)、
  `stepID` 为 `cleanup-uninstall`、理由非空。既有远端路径债务的行为由
  `testCleanupDebtCanBeQueriedAndExplicitlyContinued`、
  `testUnknownCleanupContinuationNeverResendsMutation` 与原生库那条继续覆盖,
  全部不变(仅调用点改用 `identity:` 标签)。

## `DHA-RES-002` `succeeded` 不再读作"设备干净"

- 方法:上述 job 的终态仍为 `succeeded`(主目的完成),但其状态必须携带未结清
  残留计数 > 0;清理成功的对照组该计数为 0。断言 `JobStateMachine` 的转移表
  与终态集合**零变化**(不新增 `succeededWithResidue` 之类)。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —
  `testSucceededCarriesItsOutstandingResidueCount`:脏运行 state 仍为
  `succeeded` 且 `outstandingResidueCount == 1`,干净对照组为 0;同一测试断言
  `JobState(rawValue: "succeededWithResidue") == nil`,即可见性来自计数而非
  新终态。计数由引擎在记录/结清时从债务台账**重算**(不是就地加减),
  所以它与 `cleanup-debt list` 看到的一致。

## `DHA-RES-003` 结清由 readback 判定,且不接受任意目标

- 方法:`cleanupDebt.continue` 对 bundle 残留重跑持久化的精确 action;
  (a) readback 说包已不在 → 残留结清、计数归零;
  (b) readback 说包仍在 → 不得结清,记录保留;
  (c) 传入未登记的 bundle/路径 → 拒绝(与远端路径残留同一条查表键语义,
  调用方不能借此指定任意卸载目标)。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —
  `testBundleResidueSettlesOnlyWhenTheReadbackSaysItIsGone`:包仍在时不结清、
  记录保留;包已不在时由 readback 直接结清(不重发 mutation),
  `identity` 回 `bundle:com.example.demo`。
  `testContinueRefusesAnIdentityThatIsNotInTheLedger`:未登记的 identity 被拒,
  且拒绝路径上没有第二次 `uninstallPackage` 下发。
  实现层面,`.uninstallPackage` 的 reconcile readback(`readPackagePresence`,
  desiredPresence=false)与重试后的 verify 都早已是 readback 判定(D2),
  r3 未放宽其中任何一条。

## `DHA-MULTI-001` 附加租约是唯一开关,单包路径逐字节不变

- 方法:(a) 不带 `additionalHapArtifactLeases` 的请求,其 `send-hap` /
  `install-hap` / `cleanup-remote-staging` 的**完整 argv** 与 r4 之前逐 token
  相等(单文件 `bm install -p <file> -r`),授权面与选中步骤集不变;
  (b) 带附加租约时,三条腿分别变为 `[mkdir -p <dir>, file send ×N]`、
  `bm install -p <dir> -r`、`[rm -f ×N, rmdir <dir>]`,逐 token 断言;
  (c) 断言全仓 lowering **不含 `rm -rf`**。
- Evidence:实现 PR 内测试 + 全量套件结果。
- **结论(2026-07-31):PASS** —
  `testSinglePackageArgvIsUnchangedWithoutAdditionalLeases` 逐 token 断言三条腿
  与 r4 之前相同(`file send <local> <owned.hap>`、`bm install -p <owned.hap> -r`、
  `rm -f <owned.hap>`);`testMultiPackageLowersToOneDirectoryAndOneInstall` 断言
  目录形为 `[mkdir -p <dir>, file send ×2]`、`bm install -p <dir> -r`、
  `[rm -f ×2, rmdir <dir>, ls -ld <dir>]`,并逐条断言 argv 不含 `-rf`。
  `testStagedPackagePathsRejectCallerShapedNames` 断言包名来自 artifact ID,
  `../../etc/passwd` 这类被拒。

## `DHA-MULTI-002` N 条租约逐条过绑定校验,任一不符零 dispatch

- 方法:附加租约中混入一条绑定到**另一 target identity / 另一 binding
  revision** 的 artifact,断言请求在 dispatch 前被拒(`invalidInput` 类),
  provider dispatch 计数为 0、capability 消耗为 0;正例断言 N 条全部匹配时
  send 的顺序与租约顺序一致(entry 在先)。
- Evidence:实现 PR 内测试。
- 结论:pending。

## `DHA-MULTI-003` 多模块真机安装(pending-hardware)

- 方法:已接管设备上一次 `debug.hap@1`,输入为 entry + feature 两个签名 HAP
  的租约:`package-readback` 判定安装成功、应用可启动、清理后
  `bm dump -n` 判定包已不在且 job-owned 目录已被 `rmdir` 移除。
- 前置条件:**需要一套多模块签名 HAP**;仓内与当前设备都没有。在拿到之前
  如实保持 pending。上次窗口只证明了"目录里放一个 HAP 可装",**不构成**本条
  的证据。
- **结论(2026-07-31):PASS** —— 素材前置当天解除(给 WaterFlowLayoutDemo 手加
  `feature1` 模块并用其既有签名配置构建,详见 evidence)。真机
  `job-42c0ab9d8cceb99709cb8dfd26474510`:`send-hap` 判 verified 且带
  `packageCount`、install 经 `package-readback` 判定、start/stop/uninstall 齐全、
  `cleanup-remote-staging` 判 `cleaned`,`outstandingResidueCount: 0`。
  **设备读回 `installed modules: ['entry', 'feature1']`** —— 两个模块作为一个应用
  从一个目录装成。窗口结束设备已还原。

## `DHA-SHOT-001` 截图 argv 与 owned 后缀

- 方法:contract 测试断言 `capture-screenshot` 的**完整 argv** 为
  `["-t", <connectKey>, "shell", "snapshot_display", "-t", "png", "-f", <owned>.png]`
  —— 逐 token,`-t png` 必须在场(设备按后缀校验类型,缺它会被拒);断言 owned
  path 以 `.png` 结尾且由 provider 自铸;缺 connectKey fail closed。
- Evidence:实现 PR 内测试 + 全量套件结果。
- **结论(2026-07-31):PASS** —
  `testScreenshotLowersToTheTypedPNGFormAndItsReadback` 逐 token 断言
  `["-t", <key>, "shell", "snapshot_display", "-t", "png", "-f", <owned>.png]`
  与随后的 `ls -l`,并断言 owned path 以 `.png` 结尾;
  `testOnlyTheScreenshotReceivePinsAMagic` 断言只有截图的接收腿带 PNG 魔数,
  组件树那条不带。

## `DHA-SHOT-002` 未请求即逐字节不变,请求则升 E1

- 方法:(a) 不带 `uiScreenshot` 的请求,其选中步骤集、plan effect 与授权路径与
  r5 之前相同,`screenshot.png` 不得 published;(b) 带 `uiScreenshot: true` 时
  effect 升 `deviceMutation` 并走既有 capability 路径。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —
  `testScreenshotInputIsWhatRaisesTheEffect`:不带 `uiScreenshot` 时零 dispatch、
  authority 为 `defaultReadOnlyPolicy`、capability store 为空、`screenshot.png`
  不得 published;带上时 authority 为 `runtimeCapability`、effectCeiling
  为 `deviceMutation`。

## `DHA-SHOT-003` 三层判定与魔数把关(含真机)

- 方法:contract 面断言 (a) 设备侧 `ls -l` size = 0 → `.failed`;
  (b) 落地文件魔数不是 `89 50 4E 47 0D 0A 1A 0A` → `.failed` 且**不发布**;
  (c) 正常路径 → `screenshot.png` published 且字节即收到的字节。
  真机面:一次 `capture.diagnostics@1` 带 `uiScreenshot: true` 的 Agent 执行,
  产物可解析为 PNG、远端临时文件被清理、人工步骤 0。
- Evidence:实现 PR 内测试 + `evidence/runs/TASK-DHA-004/run-r5.md`。
- **结论(2026-07-31):PASS** —
  contract:`testReceivedScreenshotMustBeginWithThePNGMagic`(HTML/JPEG/截断三种
  非 PNG 前缀均判 `unexpectedFormat`)、`testNonPNGScreenshotIsNotPublished`、
  `testZeroByteScreenshotFailsOnTheDeviceReadback`(设备侧 size=0 即止,接收腿
  不再运行)、`testScreenshotPublishesTheReceivedPNG`。
  真机:`job-27e4878abde3c50814b6a788929e94a5` 三步全 verified,导出产物
  449,756 字节、魔数正确、720×1280,设备无残留。

## `DHA-CRASH-001` 两条 argv 与只读 effect

- 方法:contract 测试断言两步的**完整 argv** 为
  `["-t", <k>, "shell", "hidumper", "-s", "1201", "-a", "-p Faultlogger"]` 与
  `[..., "-a", "-p Faultlogger -f <name>"]`(`-p`/`-f` 整体是**一个** argv 元素);
  断言这一腿被选中时 plan effect **仍为 readOnly**、授权仍走 `defaultReadOnly`、
  capability 消耗为 0 —— 与 trace/组件树/截图三条腿相反。
- Evidence:实现 PR 内测试 + 全量套件结果。
- **结论(2026-07-31):PASS** —
  `testCrashLedgerLowersToTheTwoFaultloggerForms` 逐 token 断言两条 argv
  (`-p Faultlogger` 与 `-p Faultlogger -f <name>` 各为**一个** argv 元素);
  `testCrashLedgerStaysReadOnly` 与 `testCrashLedgerCaptureStaysE0` 分别在 action
  层与 job 层断言 readOnly / `defaultReadOnlyPolicy` / capability store 为空。
  真机复核:两次运行均 `actualEffect: E0`。

## `DHA-CRASH-002` `crashLogName` 收窄且不可为路径

- 方法:负例断言 `../`、含 `/`、超长、空串、非 `*crash-` 前缀的取值在
  **admission 阶段**即拒(`invalidInput`),零 dispatch;正例断言实测过的真实条目名
  (`jscrash-<bundle>-<uid>-<timestamp>`)被接受且逐 token 进入 argv。
- Evidence:实现 PR 内测试。
- **结论(2026-07-31):PASS** —
  `testFaultLogNameRejectsAnythingPathShaped` 断言 `../`、含 `/`、绝对路径、
  含空格、空串、超长、大写前缀全部被拒;`testPathShapedCrashLogNameIsRefusedAtAdmission`
  断言路径形取值在 **admission 阶段**即拒且零 dispatch。正例覆盖实测过的真实条目名
  与 `appfreeze-` 形态(见下 pattern 偏离说明)。

## `DHA-CRASH-003` 空列表是正常结果,取不到才是失败

- 方法:(a) stdout 含 `No fault log exist.` → 判 verified,`crash-index.txt`
  如实发布该内容(不是 missing、不是失败);(b) stdout 含 `invalid parameters.`
  → 判 `.failed` 且**不发布** `crash-log.txt`;(c) 正常单条 → 发布,内容即收到的字节。
  真机面:一次带 `crashLogs: true` 的 Agent 执行取回索引。
- Evidence:实现 PR 内测试 + `evidence/runs/TASK-DHA-005/run-r6.md`。
- **结论(2026-07-31):PASS** —
  contract:空列表判 verified 且如实发布设备原话(`No fault log exist.`)、
  `invalid parameters.` 判 `.failed` 且不发布、正常单条发布收到的字节。
  真机:`job-0a7bc0f8…` 取回索引(245 B,列出一条),把该条目名喂给第二次请求
  `job-62961c6f…` 取回 109,119 B 的单条,内容以 `Generated by HiviewDFX` 开头。
- **对提案的偏离**:r6 的 pattern `^[a-z]+crash-…` 会拒绝 `appfreeze-…`。
  实现放宽为只约束形状 `^[a-z]+-[A-Za-z0-9._-]{1,180}$`(无分隔符),理由与证据
  见 evidence;安全属性不变(仍不可能是路径或 shell 片段)。

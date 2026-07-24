# TASK-SSET-001 run — Settings、retention catalog 与 production storage wiring

- Date:2026-07-24；executor:agent。
- Classification:host-only implementation/contract fixture；hardware required:no。
- Real effects:真实设备 dispatch = 0、真实用户 Session 读取/删除 = 0、网络调用 = 0。
- Environment:macOS 26.5.2 (25F84)、Xcode 26.6 (17F113)、Apple Swift 6.3.3。
- Readiness merge:`e9406075cb6ac1401447d2f90c22ffc488a05512`，唯一 parent =
  `39af11ec9e5862a2edddfe73c35bcb3acd010656`；开工时 readiness diff/pins/新增路径
  absence 按 `tasks.md` 逐项复核通过。最终实现 base 快进到 protected `main`
  `5737c1b7127f2cbe98cfb953434b4a0dfe11498d`；新增提交仅修改
  CHG-2026-030 `tasks.md`，与本任务 allowed paths 零重叠。

## 实现与生产接线

1. Settings/root:
   - versioned 单 envelope 持久化
     `schemaVersion/generation/rootSource/expectedRootPath/totalQuotaBytes/
     safetyMarginBytes/retentionDays` 与 bookmark，fresh generation = 0；
   - 默认值精确为 20 GiB / 2 GiB / 90 天；partial、wrong-type、unknown-version、
     越界值、generation overflow/CAS drift 均 fail closed 且不覆写；
   - custom root 仅接受 read-write app-scoped bookmark；resolve 固定
     `.withSecurityScope/.withoutUI`，验证 expected standardized path、owner/safe
     directory、owner write/search mode、descriptor-anchored create/unlink 可写探针与
     security-scope 成功；stale refresh 只有 replacement bookmark、generation 更新与
     原子持久化全部成功才提交，否则统一为 `requiresReselection`。所有 terminal path
     对称 stop，失败不回退默认根。
2. Retention catalog:
   - 固定 `YYYY/MM/sessionID`，全层使用 descriptor/openat、`O_NOFOLLOW`、
     `fstatat(...AT_SYMLINK_NOFOLLOW)`；locked identity/manifest 的 session/job
     必须一致，`completedAt` 由 `SessionManifestDocument` 暴露的 typed `Date`
     提供；
   - locked RFC3339 的闰秒、大小写 T/Z、±23:59 offset 与纳秒小数不被 Foundation
     格式器缩窄；catalog 用固定 UTC 纳秒格式保持 typed Date 往返；
   - 完整 size walk 拒绝 symlink、FIFO、socket、hardlink、unsafe ownership/mode、
     跨卷、read/stat fault 与 overflow；未知对象只进入 preserved-unknown，
     `unknownPressure=true`，不进入 deletion candidate；
   - root-local versioned/atomic metadata + owner-only lock，catalog/pin generation
     CAS；新 finalized Session 显式注册。缺失、损坏、duplicate（含 valid + invalid
     同 ID）、identity/time mismatch 均不重建为 unpinned，并保留既有 pin entry；
   - locked manifest 已判定 `status=planned/executionMode=planOnly` 为合法 terminal
     finalized Session，catalog 不再把它误记为 unknown；lock 使用 durable initialized
     marker，首次操作为 register/updatePin 失败或进程在 metadata 初始化前退出时，后续
     scan 仍可辨认 fresh root，不以 lock 文件“曾存在”误判 corrupt。
3. Planning/apply/admission:
   - shared runtime 绑定 settings/catalog generation、standardized root、root/volume
     identity、ordered deletion IDs 与 projected bytes；confirm/cancel/apply 不持久化；
   - settings 持久化、catalog metadata 写入、retention admission、claim admission 与
     Session root 创建共享 process-local configuration epoch。scan 后 token 在
     `activeSessions` await 之后复核，coordinator 拒绝 stale block update/admission；
     claim 在根创建期间持有同一 fence，配置已变化则零 Session 创建并释放 unbound
     claim headroom；
   - active bound claim、普通缺 manifest 的 unfinalized partial、pinned/unknown 永不
     删除；expired-first、随后 completedAt 升序；
     apply 前任一 settings/catalog/root/volume drift 均为 zero delete-port call；
   - apply 开始即设置独立 conservative admission block；普通 facade refresh 无法
     清除。部分删除、throw、post-apply rescan failure 保持阻断；仅成功实际 rescan
     且无 bytes/unknown/active pressure 才解除。
4. Production composition:
   - 保持同步 public `RockchipFlashExecutionHost()` 与 CLI source 不变；
   - Rockchip production SessionStore 改用 validated settings root lease，同 process
     host 使用 singleton runtime 的 shared `HostStorageCoordinator`；
   - heavy writer admission 在 Session 创建前执行，volume identity 再核验；成功
     terminal persistence 后注册 finalized Session。既有 tool bookmark、Keychain
     provenance、binding、storage claim 与 device authorization 路径未改。
   - 上述 production composition 只证明独立 `arkdeck` CLI 进程内的
     `SessionSettingsStore → RockchipFlashExecutionHost` wiring。当前 App bundle
     `UserDefaults.standard`、app-scoped bookmark 与独立 CLI 进程没有共享 domain/
     App Group，也没有真实 Flash consumer 在 App 进程内；因此本 run **不**把
     “App Settings → CLI production consumer”记为已可达。

## Contract/fault matrix

`SessionSettingsContractTests` 共 17 项，均只在
`FileManager.default.temporaryDirectory` 下创建 owner-only root，使用唯一
ephemeral UserDefaults suite 并在 defer 中清理；bookmark 使用 deterministic fake。
覆盖：

- exact defaults、save/reset、partial/wrong type、unknown/corrupt、generation overflow；
- bookmark reopen/stale refresh/path mismatch/scope denial/lease stop；
- stale replacement 的 generation overflow/persistence fault 均映射
  `requiresReselection`、原 envelope 不覆写、零 default fallback；
- owner `0500` root 与 descriptor write-probe denial 在保存前拒绝；
- 首次 catalog、pin CAS、finalized registration、metadata 缺失/损坏/time drift；
- 合法 terminal plan-only Session 正常索引；fresh root 首操作 register 后可继续 scan；
- year/month/session 全层 symlink、FIFO、Unix socket、hardlink、valid+invalid duplicate
  ID、identity/manifest mismatch、measurement fault 与 overflow；
- RFC3339 leap second、±23:59 offset、纳秒 completedAt 往返；
- expired/oldest ordering、pin/unknown sentinel 保护、confirm/cancel；
- settings/catalog/root/volume drift 的 delete call count = 0；
- 第二次 deletion 注入失败、post-apply rescan failure、coordinator bypass 后仍阻断；
- live bound `StorageClaim` 对应 Session 与普通 missing-manifest partial 经实际
  retention confirm/apply 后仍存在，只有 ordinary candidate 被删除；
- scan 期间 settings 更新 + newer block 的确定性竞态，以及 claim admitted 后配置更新；
  stale scan 不清新 block，stale claim 零 Session 创建且 headroom 回收；
- sessions root 在 prepare 后、claim 前或 claim 后/Session 创建前被同卷替换时，
  root inode/volume 复核均拒绝，零 Session 创建且 unbound claim 回收；
- real Workflows facade → real `SessionStore` production composition 与 shared coordinator。

测试中的所有 deletion/apply 均仅作用于上述临时 fixture；未解析默认 Application
Support、用户 home、workspace 未跟踪 fixture/log 或现有自定义 root。

## 最终验证

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter SessionSettingsContractTests
PASS — 17 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit \
  --filter SessionArtifactStorageContractTests
PASS — 60 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit
PASS — 382 tests, 0 failures, 1 expected manual sleep/wake harness skipped

ARKDECK_PYTHON=/tmp/arkdeck-sdd-venv-031/bin/python scripts/check-sdd.sh
PASS — 0 errors, 0 warnings, 111 acceptance IDs

python3 scripts/test_check_pr_paths.py
PASS — 21/21

swift format lint --strict <seven TASK-SSET-001 Swift files>
PASS

git diff --check
PASS
```

全量 Swift 输出中的 device/HDC/process 测试均为既有 contract fake/synthetic seam；
其中既有 ProcessExecutor 回归会启动受控的本机 synthetic child-process fixture。
TASK-SSET-001 专用 suite 未启动外部进程；全部验证均未接触真实设备、HDC production
server、flash、erase、format、update、网络或 production tool。

## 中间失败与修正

以下均如实保留，未记作最终 PASS：

1. 首次在 filesystem sandbox 内执行 Swift build 时，因用户 clang cache 不可写失败；
   按仓库环境约定在 sandbox 外用同一正式命令复验通过，属于执行环境失败。
2. 首次全量回归为 376 tests / 1 failure：新增 typed `completedAt` 使用了更窄的
   `ISO8601DateFormatter`，误拒 locked contract 接受的 leap second + 大 offset；
   改为复用 locked component validation 的 typed Date 转换后，原失败 suite 60/60、
   review remediation 前全量 376/376 通过。
3. 新增纳秒 timestamp 回归向量首次暴露 catalog 毫秒格式化截断，测试进程因候选为空
   后访问 fixture 下标而 signal 5；改为固定 UTC 纳秒 metadata 往返并加入正式覆盖，
   review remediation 前专用 suite 11/11 通过。
4. Unix socket fixture 首版使用过长 AF_UNIX path；改为在系统临时目录短路径 bind 后
   原子移动进临时 Session，最终 socket preserved-unknown contract 通过。
5. review remediation 首版 scoped coordinator admission 的内部 overload 调用误选到
   public overload，竞态回归在 admission 处递归等待同一 configuration fence；调用栈
   采样确认后将内部入口改为独立 `admitUnchecked`，最终新增竞态测试与全量均通过。

## Diff、隐私与范围

- Allowed source/test diff:
  `SessionManifest.swift`、`SessionRetentionCatalog.swift`、`HostStorage.swift`、
  `RockchipFlashExecutionHost.swift`、`SessionSettings/**`、
  `SessionSettingsContractTests.swift` 与本 run。
- `tasks.md` 未修改，TASK-SSET-001 仍为 `ready`；本 implementation/evidence PR
  不翻 `ready → done`，也不声明 change verified、App UI 已可达或 App 配置已被
  独立 CLI consumer 消费。
- Forbidden diff:0；`Package.swift`、App/Xcode、CLI、locked schema、
  `RetentionAndExport.swift`、`SessionLayout.swift`、`SessionStorageTypes.swift`、
  `RockchipFlashExecution.swift` 与既有 test files 均未修改。
- 开工前既有未跟踪 `ArkDeckFakeHDCFixture-M1-006`、
  `Packages/ArkDeckKit/log/`、`log/` 保持 untouched 且不入提交。
- changed-file secret/privacy scan 对绝对用户 home 前缀、GitHub/AWS token 与
  private-key header 零命中；evidence 不含 bookmark bytes、绝对用户路径、
  Artifact 内容、设备标识或 secret。

## AC candidate 结论与遗留

- `SSET-CONFIG-001`:library contract candidate PASS；App→CLI product reachability
  未成立，不以同进程注入 store 代替。
- `SSET-CATALOG-001`:candidate PASS。
- `SSET-RETENTION-001`:**BLOCKED（production reachability）**。同进程
  Workflows→Rockchip consumer 的 generation/root/coordinator contract 已通过，但
  proposal/design 要求 App-owned runtime；当前 App 与独立 SwiftPM CLI 不共享
  preferences/security-scope capability，现有 TASK-SSET-002 也没有真实 Flash host
  consumer 的 allowed path。必须先由独立 scope-remediation PR 选择并批准：
  将真实 Host consumer 放进 App process、引入受签名/entitlement 约束的共享载体，
  或显式收窄本 change 的 production reachability。
- `AC-ART-006-02`、`AC-STO-001-01`、`AC-STO-003-01`、
  `AC-STO-004-01`:contract candidate PASS。

不在本实现 PR 静默改变的规格/恢复边界：

- sessions root 中 `.DS_Store` 等不合形对象继续按 pin 要求 preserved-unknown 并阻断；
  allowlist 是规格决策，不在代码层自行放宽。
- 普通 missing/unfinalized partial（含失败/中断后尚未完成 recovery 的 Session）继续
  阻断，直至 recovery/人工处置；合法 finalized plan-only 已不再误阻断。
- finalized registration 的瞬时持久化失败仍缺少带内 durable retry/维护者恢复流程；
  `retentionDays` 也仍无 UI 上限。这两项需在 SSET-002 或独立 maintenance change
  明确，不在本 review fix 扩 scope。

因此 TASK-SSET-001 不具备 done/verified 候选条件；先完成上述 scope remediation，
再决定 production wiring 实现任务与 SSET-002 的依赖/allowed paths。

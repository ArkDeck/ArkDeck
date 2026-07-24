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
     directory 与 security-scope 成功，stale refresh 原子更新 generation；所有
     terminal path 对称 stop，失败不回退默认根。
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
     同 ID）、identity/time mismatch 均不重建为 unpinned，并保留既有 pin entry。
3. Planning/apply/admission:
   - shared runtime 绑定 settings/catalog generation、standardized root、root/volume
     identity、ordered deletion IDs 与 projected bytes；confirm/cancel/apply 不持久化；
   - active/partial/pinned/unknown 永不删除；expired-first、随后 completedAt 升序；
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

## Contract/fault matrix

`SessionSettingsContractTests` 共 11 项，均只在
`FileManager.default.temporaryDirectory` 下创建 owner-only root，使用唯一
ephemeral UserDefaults suite 并在 defer 中清理；bookmark 使用 deterministic fake。
覆盖：

- exact defaults、save/reset、partial/wrong type、unknown/corrupt、generation overflow；
- bookmark reopen/stale refresh/path mismatch/scope denial/lease stop；
- 首次 catalog、pin CAS、finalized registration、metadata 缺失/损坏/time drift；
- year/month/session 全层 symlink、FIFO、Unix socket、hardlink、valid+invalid duplicate
  ID、identity/manifest mismatch、measurement fault 与 overflow；
- RFC3339 leap second、±23:59 offset、纳秒 completedAt 往返；
- expired/oldest ordering、pin/unknown sentinel 保护、confirm/cancel；
- settings/catalog/root/volume drift 的 delete call count = 0；
- 第二次 deletion 注入失败、post-apply rescan failure、coordinator bypass 后仍阻断；
- real Workflows facade → real `SessionStore` production composition 与 shared coordinator。

测试中的所有 deletion/apply 均仅作用于上述临时 fixture；未解析默认 Application
Support、用户 home、workspace 未跟踪 fixture/log 或现有自定义 root。

## 最终验证

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter SessionSettingsContractTests
PASS — 11 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit \
  --filter SessionArtifactStorageContractTests
PASS — 60 tests, 0 failures

CI=true swift test --package-path Packages/ArkDeckKit
PASS — 376 tests, 0 failures, 1 expected manual sleep/wake harness skipped

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
   最终全量 376/376 通过。
3. 新增纳秒 timestamp 回归向量首次暴露 catalog 毫秒格式化截断，测试进程因候选为空
   后访问 fixture 下标而 signal 5；改为固定 UTC 纳秒 metadata 往返并加入正式覆盖，
   最终专用 suite 11/11 通过。
4. Unix socket fixture 首版使用过长 AF_UNIX path；改为在系统临时目录短路径 bind 后
   原子移动进临时 Session，最终 socket preserved-unknown contract 通过。

## Diff、隐私与范围

- Allowed source/test diff:
  `SessionManifest.swift`、`SessionRetentionCatalog.swift`、`HostStorage.swift`、
  `RockchipFlashExecutionHost.swift`、`SessionSettings/**`、
  `SessionSettingsContractTests.swift` 与本 run。
- `tasks.md` 未修改，TASK-SSET-001 仍为 `ready`；本 implementation/evidence PR
  不翻 `ready → done`，也不声明 change verified 或 App UI 已可达。
- Forbidden diff:0；`Package.swift`、App/Xcode、CLI、locked schema、
  `RetentionAndExport.swift`、`SessionLayout.swift`、`SessionStorageTypes.swift`、
  `RockchipFlashExecution.swift` 与既有 test files 均未修改。
- 开工前既有未跟踪 `ArkDeckFakeHDCFixture-M1-006`、
  `Packages/ArkDeckKit/log/`、`log/` 保持 untouched 且不入提交。
- changed-file secret/privacy scan 对绝对用户 home 前缀、GitHub/AWS token 与
  private-key header 零命中；evidence 不含 bookmark bytes、绝对用户路径、
  Artifact 内容、设备标识或 secret。

## AC candidate 结论与遗留

- `SSET-CONFIG-001`:candidate PASS。
- `SSET-CATALOG-001`:candidate PASS。
- `SSET-RETENTION-001`:candidate PASS。
- `AC-ART-006-02`、`AC-STO-001-01`、`AC-STO-003-01`、
  `AC-STO-004-01`:contract candidate PASS。

遗留边界：App Settings scene、真实 picker/signed bookmark reopen 与点击清理的 UI
reachability 属于尚未 ready 的 TASK-SSET-002；本 run 不执行、不预判。TASK-SSET-001
最终状态与 change verification 仍须按独立 D0 PR/verification gate 由维护者确认。

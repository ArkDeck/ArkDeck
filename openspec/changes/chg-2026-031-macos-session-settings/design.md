# CHG-2026-031 Design

## 0. Invariants

1. DEC-006 默认值精确为 20 GiB / 2 GiB / 90 天及 Application Support `Sessions`。
2. pinned、active/partial、身份不一致或无法完整计量的 Session 永不进入 deletion
   candidates；不确定性使 heavy-writer admission 保守阻断。
3. 清理必须由用户审阅 exact plan 后二次确认；production 没有自动/静默删除入口。
4. preview 不是结果。只有 apply 成功且重新扫描确认后，admission 才能解除。
5. 自定义输出根只能来自有效 read-write security-scoped bookmark；失效或 path mismatch
   不回退、不迁移、不续写。
6. 本 change 不产生任何 device authority/effect，也不削弱既有 Flash/HDC gate。

## 1. Settings contract

`SessionSettingsSnapshot` 是 immutable、`Sendable` 的 product value：

- `generation`：每次成功持久化递增，用于使旧 preview 失效；
- `sessionsRoot` 与 `rootSource(defaultApplicationSupport | userBookmark)`；
- `totalQuotaBytes`，默认 `20 * 1024^3`；
- `safetyMarginBytes`，默认 `2 * 1024^3`；
- `retentionDays`，默认 90。

保存条件是 `totalQuotaBytes > safetyMarginBytes > 0`、`retentionDays > 0` 且所有
换算无 overflow。UserDefaults 缺失时使用 DEC-006 默认；存在但 version、类型、范围或
字段不合法时返回具名 configuration error，不把损坏配置与“首次运行”混同，也不静默
覆写原值。

默认根由 `FileManager` 的 user-domain Application Support URL 派生，禁止用字符串展开
`~`。目录以 owner-only 权限创建/复核。选择自定义根时同时保存 bookmark bytes 与
expected standardized path；reset 是显式用户动作，清除两者并产生新 generation。

## 2. Persistent file access

`SessionRootAccessLease` 封装 bookmark resolution、
`startAccessingSecurityScopedResource()` 与对称 stop。resolve 规则：

1. bookmark 必须使用 `.withSecurityScope` + `.withoutUI`；
2. stale bookmark 只有在解析 URL 与 expected path 相同、scope 成功且 replacement
   bookmark 可生成时才原子刷新；
3. path mismatch、非 file URL、非绝对 path、scope 获取失败或目录安全检查失败均返回
   `requiresReselection`；
4. lease 被 production Session creation/retention 操作持有到操作结束。

UI 只把 `NSOpenPanel` 返回的用户选择 URL交给 facade；UI 自身不保存裸 path 作为授权。

## 3. Retention catalog

新增 Storage-owned `SessionRetentionCatalog`，在打开的 sessions root 下只接受
`YYYY/MM/sessionID` 三层目录。它拒绝/隔离 symlink、层级逃逸、重复 Session ID、identity
不匹配、缺失/非法 locked manifest 和不安全文件类型。

对有效 finalized Session：

- 从 `SessionManifestDocument` 的 locked canonical document 读取 typed
  `completedAt`；不另写第二份来源事实；
- 以当前 `retentionDays` 计算 `expiresAt = completedAt + days`，并用 versioned、
  atomic retention metadata 保存 `sessionID/completedAt/expiresAt/isPinned/
  policyGeneration`；
- 设置变化时只重算 `expiresAt/policyGeneration`，保留 pin；
- 使用不跟随 symlink、overflow-saturating 的目录计量得到 `sizeBytes`。

首次索引仓库既有 finalized Session 时默认 `isPinned=false`，因为此前产品不存在 pin
设置入口；一旦 metadata 存在，缺失/损坏/不一致不再猜测为 unpinned，而是把该 Session
分类为 preserved-unknown。active/partial Session 计入当前用量或 unknown pressure，
但不成为删除候选。

metadata 放在所选 sessions root 的 ArkDeck-owned catalog 文件中，原子替换且 owner-only；
它不改 locked manifest schema。用户 pin/unpin 同样通过 catalog generation compare-and-
swap；旧 UI snapshot 不能覆盖较新状态。

## 4. Retention planning, apply, and admission

`SessionStorageApplicationRuntime` 是 App process 内唯一 shared actor，持有 settings
snapshot、root access lease、一个 `HostStorageCoordinator` 和当前 catalog generation。

refresh 数据流：

```text
settings generation
  → root access lease
  → secure catalog scan + current bytes/unknown pressure
  → SessionRetentionController.plan
  → preview + conservative admission update
```

- 若 current bytes 已超过 `quota - safetyMargin`、存在 unknown pressure，或上一轮 apply
  后尚未成功 rescan，runtime 先阻断该 volume 的新 heavy writer。
- preview 固定 settings generation、catalog generation、root identity、volume identity
  和 ordered deletion IDs；pin/setting/root/catalog 任一变化都使确认失效。
- confirm 后才调用 `SessionRetentionController.apply`。成功返回后必须重新 scan；
  只有实际 current bytes 不高于 safety target 且无 unknown pressure 才解除阻断。
- apply 部分失败、App crash、卷重挂或 rescan 失败时保持阻断并展示真实 remaining state；
  不把计划释放量当成实际释放量。

`RockchipFlashExecutionHost` 的生产组合从该 runtime 获取 immutable execution context，
使用其 sessions root lease 与 shared coordinator。现有 `StorageClaimRequest`、真实 volume
snapshot、heavy-writer exclusivity、revalidation 和 device authorization 均保持；settings
不能构造 Storage claim 或 Flash authority。

## 5. App UI

macOS `Settings` scene 包含：

- Output：当前根、Choose Folder、Use Default；
- Storage：总配额、安全余量、保留天数与 validation；
- Retention：current/projected bytes、ordered candidates、pinned/unknown counts、
  heavy-writer 状态；
- Sessions：对有效 finalized Session pin/unpin；
- Review Cleanup：exact deletion list 与预计释放量；Confirm Delete 二次确认。

UI view model 只调用 `SessionSettingsApplicationProviding`。fixture facade 只能由显式
`--ui-test-session-settings` 参数选择，presentation-only fixture 的
`retentionApplyIsProductionComposed=false`，不得拥有 Storage controller、bookmark 或
filesystem delete port；production facade 标志为 true。按钮只有 production facade 且
当前 preview/generation 有效时才可 dispatch。

## 6. Data and compatibility

- 新增 macOS-local settings schema v1 与 retention metadata v1；不进入 Core registry。
- manifest/journal/snapshot/Artifact schema 零修改；`SessionManifestDocument` 最多新增
  validated read-only timestamp exposure。
- 首次打开旧根只建立 catalog metadata，不改 Session 内容。非法 Session 被隔离于清理
  候选之外并显示。
- 切换输出根不移动旧 Session。每个根保留自己的 catalog；切回时重新 resolve、scan 和
  admission。

## 7. Authority and production reachability

- Production composition root：App 的 `Settings` scene 通过
  `SessionSettingsApplicationFacade.make()`；Session 写入通过
  `RockchipFlashExecutionHost.init()` → `RockchipProductionExecutionComposition.make()`。
- Authority 产生点：host 文件删除 authority 只来自当前 security-scoped/default-root
  lease + generation-bound user cleanup confirmation。Storage/Flash claim 与设备
  authorization 仍由原有生产端口产生，Settings 不能构造。
- Effect dispatch point：本 change 唯一新增 effect 是
  `SessionRetentionController.apply` 的 host-local Session deletion；其前后分别是 exact
  preview/confirmation 与 post-apply rescan。无 device effect dispatch。
- Fake/simulation 与 production：UI fixture facade 不含 delete port 且 production flag
  为 false；contract tests 只对临时目录装配真实 Storage controller。正例不会证明真实
  用户目录已被删除，也不会被记为 hardware evidence。
- Facts/provenance：completedAt 来自 locked manifest，pin 来自 generation-bound catalog，
  size/root/volume 由 Storage filesystem probes 生产，user confirmation 只批准已绑定
  preview。调用方不能用 UI 文本同时构造这些 facts 与证明。

## 8. Failure, recovery, security, and alternatives

- bookmark/root/volume drift、catalog parse/measurement error、generation mismatch、
  partial apply 和 post-apply rescan failure 均保留数据并保持 admission blocked。
- App termination 后不恢复“已确认”状态；重新打开必须重新 scan 和 preview。
- 日志只记录 source 类别、generation、相对 Session ID、计数/字节与具名错误，不记录
  bookmark bytes、完整 home path、设备标识或 Artifact 内容。
- 拒绝“UI 直接读写 UserDefaults + Rockchip 继续硬编码根”的方案，因为会形成两个事实源。
- 拒绝启动时自动 apply，因为本 revision 要求用户查看 exact deletion list；未来若需
  后台自动清理，必须独立 change 明确触发、通知与 crash/recovery 语义。
- 不需要新 ADR；若实现发现需要修改 locked schema、自动删除或 Core retention 语义，
  本 change 保持 blocked 并另起 Core delta。

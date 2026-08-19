# TASK-SPT-001 — 删除 ArkDeck 侧设备地址（2026-08-19）

## 变更

- `RockchipMappedPartition`：删除 `offsetSectors` 字段与 public init 参数、
  九个 FA-001 钉值、`init` 里的「按 offset 升序」自检（该自检是全部 Sources
  中该字段唯一读点）；类型 doc comment 改写为覆写范围声明语义，指明地址与
  写序权威在 arkforged（写前对设备自身分区表实测）。
- `DeviceProviderAdapters.flashBundle`：`partitionPlan` 校验逻辑零改动，
  补注其含义（覆写范围确认回声，非寻址指令）。
- 测试：两处夹具（Dayu20070035 / CompleteOverwriteRecovery）原以 profile
  钉值合成 parameter.txt，改为显式合成序列（`(index+1)*0x2000`）——归档
  declared 表本就与设备地址无关，conformance 只比名字；provider 契约测试的
  offsets 钉值断言删除，名单/写序断言保留。

## 验证

- `offsetSectors` 在 Sources/Tests 仅存于归档 introspection 的
  `RockchipDeclaredPartition`（parameter.txt 归档事实，SPT-AC-1 的豁免面）。
- `swift test --package-path Packages/ArkDeckKit --parallel`：**1726/1726，
  exit 0**（首跑 APIBaseline 失败为本地 `.build` 缓存引用 #1403 已删文件，
  清缓存后全绿——非 API 破坏；`RockchipMappedPartition` 为 package 类型，
  外部消费者基线不受 init 签名影响）。
- admission 行为不变：partitionPlan 比对逻辑逐字未动（SPT-AC-2）。

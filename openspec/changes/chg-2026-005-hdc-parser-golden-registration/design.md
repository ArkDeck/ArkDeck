# HDC parser golden registration design

> Status:draft
> Change:CHG-2026-005-hdc-parser-golden-registration@r2
> Core baseline:CORE-2.0.0

## Boundary

本 change 建立两类都可 review 的 fixture lineage：

```text
M0A failure candidate constants
  -> versioned raw fixture bytes
maintainer-approved authoritative / controlled-human raw inputs
  -> standalone success + healthy/checkserver + version raw fixture bytes
both
  -> per-file SHA-256 entries in Integration lock
  -> identical shared-input entries in Core conformance
  -> exact family mappings in versioned OpenHarmony integration profile
  -> read-only consumption by TASK-M1-006 parserGolden tests
```

不修改 `HDCSemanticOutputParser`、`ProcessSemanticEvaluating`、output marker、
classification precedence 或 raw-output retention 行为。

## Fixture pack

- 根路径:
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/`
- 输入 lineage:
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/HDCFixtures.swift`
  @ SHA-256
  `22be193bc03f84fa1484be87128c40b8031a7b9fdbb5478b65c429a046680c7b`
- failure 仅提取已有 `exitZeroFailure` 与 `largeOutputFailureTail` 字节；generated large
  progress payload 不是 semantic golden；
- standalone success、healthy/checkserver、version 必须逐字节来自维护者认可的
  authoritative source 或 controlled-human capture。仓库中的 parser marker 常量、
  test-only 状态对象或 Agent 新写字符串都不构成真实 output provenance；
- hang/slow/crash/oversized 是 process/fault vectors，不是 supported semantic family；其
  M1-006 证据必须单独分类，不能替代任何 golden。
- 任务实现后，pinned raw fixture 路径转为只读 forbidden path；改变字节必须走
  新 integration change/version。

## Registry consistency

Integration lock 是 adapter/fixture 版本登记；Core conformance shared inputs 必须重复
精确的 fixture ID/version/path/hash，以便任意 conformance run 都能发现未登记
或已漂移字节。实施时须升级 Integration lock 与 `OPENHARMONY-TOOLS` profile version，
并使 profile supported family 集合与 pinned fixture 集合精确闭合；未登记 output 仍为
unknown/unsupported。

## SwiftPM resource access

Golden pack 是 `ArkDeckContractTests` target 中第一批非 Swift raw files。I5-001 与 fixture
登记在同一个实现 PR 中负责 `Packages/ArkDeckKit/Package.swift` 接线：只允许在该 test
target 增加 `.copy("Fixtures/HDC/Golden")`，不得顺带改变其他 product、target 或
dependency。

`.copy` 是此版本化 pack 的结构约束：resource bundle 必须保留
`Golden/<version>/<file>` 目录树，使 registry path 可直接定位，且允许未来多个版本存在
同名文件。不得改用会把未处理 raw files 拍平到 bundle 顶层的 `.process`；目录层级丢失或
同名资源冲突均须 fail closed。

所有 fixture tests 统一通过 `Bundle.module` 读取资源并按 registry path/hash 校验；禁止
使用 `#filePath` 回退到 repository checkout。I5-001 必须用 `swift build --build-tests` 证明
SwiftPM 没有 unhandled-file warning，并用 dedicated resource test 证明 bundle 中的资源集合、
bytes 与 pinned hash 精确一致。M1-006 只读复用该 resource contract，不再次拥有或修改
Golden resource declaration。

## Failure behavior

- 任一 success/health/version 输入缺失或 provenance 未获维护者认可：I5-001/M1-006
  保持 blocked，不生成替代字符串；
- 字节 lineage 无法证明、hash 不一致或登记不完整：不合入，M1-006
  保持 blocked；
- 实现期间发现需新增 marker/family：停止并修订本 integration change；
- 后续 M1-006 测试观测与 pinned expected classification 不同：AC 结论
  failed，不改 fixture 迎合实现。

---
id: CHG-2026-069-published-surface-truth
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-069 — 已发布面即真相:收回六个永拒值与一个无 lowering 的 operation

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected
> `main` 后,Task 方可开始实现 PR。

## 背景

外部 agent 唯一能读的东西就是已发布面。它不会读 `RuntimeJobEngine.swift`,
也不会读 PRODUCT-LOOP 的冻结清单——它读 `operation.list` / `operation.describe`
返回的 enum 与 operation 名册,并把里面的每一项当作「可以提交」。

发布面上今天有两类东西不满足这个假设:一类是发布了但引擎在授权前无条件
拒绝的 enum 值,一类是发布了但没有任何 provider lowering 的 operation。
两者都不是 bug——引擎的拒绝是诚实的,`operationNotSupported` 也是诚实的——
问题在于**诚实发生得太晚**:agent 已经构造了请求、发起了往返,才被告知这
条路不存在,而错误看起来像是它自己填错了参数。

## 实测事实(2026-08-20,逐条一手复核)

### 一、六个已发布但永远被拒的 enum 值

`RuntimeJobEngine.validateSupportedPlanInputs`(`RuntimeJobEngine.swift:6281`)
在 `validateInputs`(schema 层,`:7305`)之后、授权之前无条件拒绝:

| operation | 字段 | 发布的 enum | 永拒值 | 拒绝点 |
| --- | --- | --- | --- | --- |
| `debug.hap@1` | `installPolicy` | installOrReplace \| **installFresh** | `installFresh` | `:6335` |
| `debug.hap@1` | `cleanupPolicy` | uninstall \| retain \| **restorePrevious** | `restorePrevious` | `:6340` |
| `debug.hap@1` | `portForwardProfile` | none \| **debugger-default** | `debugger-default` | `:6345` |
| `deploy.native-library.app-owned@1` | `restartProfile` | restartAbility \| **restartProcess** \| **none** | 非 `restartAbility` 的一切 | `:6324`(补集式) |
| `capture.diagnostics@1` | `redactionProfile` | standard \| **strict** | `strict` | `:6307` |

审查报告记为五个,实为**六个**:`capture.diagnostics@1` 的
`redactionProfile="strict"` 是同族的第六个,复核时补入。

`debugger-default` 对一个做调试的 agent 尤其像正确答案——它是
`portForwardProfile` 两个取值里唯一非空的那个。

**连带发现(报告未及):删值之后,五个字段里有四个退化为单值 enum,且该
单值恰是字段的 `default`。** 收窄后各字段的剩余取值:

- `installPolicy` → `["installOrReplace"]`(= default)
- `cleanupPolicy` → `["uninstall", "retain"]`(仍是真选择)
- `portForwardProfile` → `["none"]`(= default,且语义是「什么都不做」)
- `restartProfile` → `["restartAbility"]`(= default)
- `redactionProfile` → `["standard"]`(= default)

也就是说这四个字段存在的唯一理由,就是提供那个不工作的值。它们该留该删
是本 change 必须一并裁决的第三个问题(见 design.md §3),不能装作没看见。

### 二、`deploy.native-library.system@1`:发布了,但没有任何执行路径

- **零 provider lowering**:`DeviceProviderAdapters.swift` 的白名单不含它,
  落 `default` → `operationNotSupported`。发布面的诚实性没有被违反,但
  这条诚实只在提交之后才说出口。
- **零 artifact 发布映射**:对全部 25 个 operation 做
  `catalog.artifacts[required] ⊆ artifactMapping ∪ finalizeArtifacts` 的机械
  覆盖计算,**唯一缺口就是它**——`backup-receipt.json`、`publish-report.json`、
  `verification-report.json` 三个 required artifact 全无映射。
- `PRODUCT-LOOP.md` §20 已把 system `.so` 明确列为冻结项。
- 却仍占用 **8 处**手工名册(2 个 profile、1 个 operation JSON、2 个生成物、
  1 个生成器测试、2 个 Swift 测试)。

一个 `effect: destructive`、`authorization: runtimeCapability`、11 步(含
`remount-writable`、`atomic-replace`、`rebootDevice`)的 operation 挂在发布面
上而无人能执行,是发布面能承载的最贵的一种假话。

## 目标

1. 发布的每一个 enum 值都能走到授权闸;引擎里针对被删值的手写拒绝分支
   随之变成死码并删除。拒绝仍然发生,但发生在 schema 层
   (`input <key> value is outside its enum`),早一层,且理由属于 schema
   而不属于一段散文。
2. 发布的每一个 operation 都有 provider lowering;`operation.list` 从 25
   条变 24 条。
3. `artifactMapping` 全目录覆盖成为可断言事实(AR-15 在本 change 之后即可
   转绿,不必再为唯一的缺口开例外)。

## 诚实边界

- **这是破坏性修改**:收窄已发布输入域 + 删除已发布 operation。语义上
  没有任何调用方失去能力(六个值本就 100% 被拒,该 operation 本就 100%
  `operationNotSupported`),但**错误码会变**:从 `invalidInput` 带散文
  理由,变成 `invalidInput` 带 schema 理由;从 `operationNotSupported`
  变成 `unknownOperation`。
- **`catalogDigest` 会移动。** 按 PRODUCT-LOOP §6,既有 `REAL_DEVICE_PASS`
  是相对它取值时的 digest 的;本 change 合入后需要按 §6 处理受影响的真机
  验收记录。实现 PR 必须与任何其他 digest 变更**串行**,两次 bump 会在
  生成物冲突且互相作废。
- **操作者前置(AI 做不到的一步)**:`deploy.native-library.system@1` 一旦
  删除,将来若重新发布,`@1` 版本号会与线上 journal 里可能存在的历史引用
  冲突。实现 PR 开工前须由操作者在活机器上确认零引用:
  `rg 'deploy.native-library.system' <state-dir>`。这不是形式主义——它决定
  的是「删除」还是「留版本号只删实现」。

## 影响面

`Catalog/operations/`(2 改 1 删)、`Catalog/profiles/`(2 改)、
`Catalog/generated/effect-authorization-matrix.md`(生成物)、
`Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift`
(生成物)、`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
(删死码分支)、`scripts/catalog_gen/test_generate.py`、
`Packages/ArkDeckKit/Tests/`(名册与负向用例)。

零 `openspec/contracts/**` delta、零安全内核触碰、零 provider 行为改动。

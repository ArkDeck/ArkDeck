# Design — CHG-2026-069

本文件的作用是把三个**需要维护者裁决**的问题摆清楚,每个都给出选项、
代价与推荐。AI 不替这三条做决定。

## §1 裁决一:六个永拒值怎么收(AR-12)

### 方案 A — 从 Catalog enum 删掉这六个值(推荐)

发布面只发布能走到授权闸的值。引擎里对应的手写分支删除,拒绝由
`validateInputs` 的 enum 检查承担(`RuntimeJobEngine.swift:7341`,
`input <key> value is outside its enum`)。

- **收益**:双真相消失。发布面与执行面之间不再需要一份人工维护的
  「其实不行」清单。`operation.describe`(AR-08 已落地)投影出的 enum
  从此就是可提交集。
- **代价**:未实现语义的设计记录从 Catalog 消失,需要另存一处(见下)。
- **错误码变化**:同为 `invalidInput`,理由从散文变成 schema 判定。

### 方案 B — 保留值,在字段 schema 上加 `unimplementedValues: [...]`

生成器下发,`operation.describe` 投影,agent 可以读到「这个值存在但
未实现」。

- **收益**:设计记录留在发布面上,agent 能区分「不存在」与「还没做」。
- **代价**:**双真相没有消失,只是搬了个家。** 因此方案 B 若被采纳,
  必须同车加一条契约测试,断言 `unimplementedValues` 的并集与
  `validateSupportedPlanInputs` 的拒绝集**逐字相等**——否则两份名单迟早
  分叉,而分叉的方向一定是发布面说能、引擎说不能。
- 额外代价:schema 字段是发布面的一部分,加一个字段就是加一份长期契约。

### 推荐

**方案 A**,未实现语义写进对应 operation JSON 的 `notes`(它已经是发布面
的一部分、已被 `operation.describe` 投影,承载「将来也许做」不需要新造
字段)。方案 B 的价值在 agent 能读到 roadmap,但一个 agent 拿到
「未实现」和拿到「不存在」的下一步动作是同一个:换一条路。

## §2 裁决二:`deploy.native-library.system@1` 删还是搬(AR-13)

### 方案 A — 从 `Catalog/` 删除(推荐)

发布面不承载「将来也许做」。11 步的编排设计随 git 历史保留,任何时候
`git show` 可取回。

### 方案 B — 把 JSON 移进 `openspec/`(设计文档位)

保留可读的设计记录,但明确不在发布面上。

### 推荐

**方案 A**。它的 11 步编排(remount-writable / atomic-replace / rebootDevice)
是有价值的设计,但价值在于「将来做 system `.so` 时的起点」,而 git 历史
就是起点。若维护者希望有一份不必翻历史的记录,方案 B 的搬运成本极低,
两者都不影响本 change 的其余部分。

### 无论哪个方案,都需要操作者先做一步

`@1` 版本号与线上 journal 的历史引用可能冲突(见 proposal「诚实边界」)。
实现 PR 开工前须在活机器上确认零引用。若**非零**,则本裁决改为第三种:
保留 reference 与版本号、只删步骤与 artifact 声明,发布面上留一条明确
标记为「已退役」的条目——那是另一种设计,需要回到本 change 再裁决一次。

## §3 裁决三(实测中新发现):四个退化为单值的字段留不留

删值之后,`installPolicy` / `portForwardProfile` / `restartProfile` /
`redactionProfile` 各自只剩一个取值,且恰是它们的 `default`。一个 agent
对这四个字段唯一能做的事,就是把默认值再写一遍。

### 为什么不能顺手删掉字段

`validateInputs` 对**未声明的输入键直接拒绝**
(`RuntimeJobEngine.swift:7317`,`input <key> is not declared by <ref>`)。
所以删字段比删值破坏性更大:今天一个显式传 `redactionProfile: "standard"`
的调用方**完全合法**,删字段之后它会被拒。删值不会伤到任何现存的合法
调用,删字段会。

### 三个选项

1. **保留字段不动**(推荐)。它们是向前兼容的扩展点:将来实现
   `installFresh` 时,把值加回 enum 即可,不需要重新发布字段。代价是
   `operation.describe` 里会出现四个「只有一个选项」的字段。
2. **保留字段,并在 `notes` 里说明它当前只有一个取值、为何保留。**
   推荐 1 的加强版,成本一行文字。
3. **删除字段**。发布面最干净,但破坏现存合法调用,且将来实现时要重新
   发布字段。

### 推荐

**选项 2**。单值 enum 看起来冗余,但它编码了一件真事:这个维度存在、
当前只有一个安全答案。把它删掉,等于把「这里将来会有选择」这条信息也
一起删掉,而重新发布字段比重新发布值贵。

## §4 两个 Task 的先后与 digest 串行

- `TASK-PST-001`(收 enum)与 `TASK-PST-002`(退役 operation)**各自**都会
  移动 `catalogDigest`。两者必须串行合入,且与仓内任何其他 digest 变更
  串行——并发的两次 bump 必然在
  `RuntimeOperationCatalogGenerated.swift` 与
  `effect-authorization-matrix.md` 冲突,且互相作废对方的真机验收基线。
- AR-15 的 `artifactMapping` 全目录覆盖断言必须排在 `TASK-PST-002`
  **之后**:今天全目录唯一的覆盖缺口就是被退役的这个 operation,先加断言
  会一上来就红。

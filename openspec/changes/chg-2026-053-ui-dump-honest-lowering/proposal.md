---
id: CHG-2026-053-ui-dump-honest-lowering
revision: 2
status: approved # r1 已交付;r2 携 approved 落地:维护者 review + merge 本 PR 即批准(enforcement 批准语义)
class: capability
owner: lvye
platforms: [macos]
---

# capture-ui-dump 诚实执行:windowInventory 取代不可执行的 componentTree lowering

> 恰四类声明:本 change 修改已发布 operation(`capture.diagnostics@1`)的
> step actionRef,属「对已发布 operation 的修改」,按 `PRODUCT-LOOP.md` §22 与
> AGENTS.md 控制平面条款走 OpenSpec change + PR 审批,并与 GJ-1 交付同车。
> 本 change 不产生 readiness/verification/archive 后续载体:任务随实现 PR 翻转
> done,verification 结论写入同 PR,归档冻结(PRODUCT-LOOP §20)。

## Why(根因)

`arkdeck-diagnostics/componentTree` action 的契约输入只有 `byteBudget`
(`openspec/contracts/catalogs/diagnostics-stdout.yaml`),而仓内全部真机验证过的
组件树 dump 形态(CHG-2026-008,`scripts/ud_capture/capture.py` R1/R2/R3、
`openspec/contracts/catalogs/dump-recipes.yaml`)都要求 `windowId`。也就是说:
**已发布的 componentTree action 在生产上不存在诚实的单命令 lowering**。

当前生产代码把它 lower 成 `shell hidumper -s componentTree`——`componentTree`
不是 hidumper 服务名,真机上该命令输出错误文本;自 #798 起真实字节会被如实
写入 `ui-dump.json`,即 GJ-1 的 UI Dump artifact 内容是错误文本而非 UI dump。
这同时命中 PRODUCT-LOOP §3-7(把未实现的能力对外标记为可用)与 §8
Availability First。

## What(同车交付面)

1. **契约新增 `windowInventory` action**(`diagnostics-stdout.yaml` 与
   `workflow-step.schema.json` 的 stdout 分支同步,参数面与 componentTree
   相同 = 仅 byteBudget):`captureRemoteStdout`/stdout。语义 = 全窗口清单,
   对应 CHG-2026-008 真机验证过的 INV-1 形态
   `hidumper -s WindowManagerService -a -a`,无需额外输入。
2. **`capture.diagnostics@1` 的 `capture-ui-dump` 步骤 actionRef 切换**
   `arkdeck-diagnostics/componentTree` → `arkdeck-diagnostics/windowInventory`
   (`Catalog/operations/capture.diagnostics.v1.json` + 重新生成
   `RuntimeOperationCatalogGenerated.swift`,catalog digest 随之更新)。
   journal 记录的 action 身份与真实执行的命令自此一致(CHG-2026-050 教训:
   不得拿相邻 action 顶替)。
3. **componentTree 全链 fail closed 背线**:provider `captureAction` 与
   `.captureUIDump(.componentTree)` lowering 均以机器可读原因拒绝
   (缺 windowId 契约,无诚实 lowering),零 dispatch、零垃圾 artifact。
   componentTree action 保留在契约中,待后续以 windowId 输入修订后启用。
4. **windowInventory 真实 lowering**:
   `-t <connectKey> shell hidumper -s WindowManagerService -a -a`。
5. **测试面按 PRODUCT-LOOP §11 落到 argv 层**:contract 测试断言完整真实
   argv(含 `-t`),而非仅 typed action 等值;componentTree 负例断言拒绝。

## r2(2026-07-31):组件树按其真实产物形态交付

### r1 的诊断不完整,今天被真机推翻了一半

r1 判 componentTree fail closed,理由写的是"全部真机验证过的组件树 dump 形态都要
`windowId`,而契约不带"。**该理由不成立**。2026-07-31 在 DAYU200(OH 3.2 /
hdc 3.2.0f)实测 `[R]`:

```text
shell which uitest        -> /bin/uitest
shell uitest dumpLayout -p /data/local/tmp/<f>.json      # 不带 -w、不带 -d
  -> DumpLayout saved to:/data/local/tmp/<f>.json
shell ls -l <f>.json      -> -rw-r--r-- 1 root root 26143 …
```

产物是 `{attributes, children}` 的 JSON 树(该次 42 节点),节点属性含
`bounds`、`bundleName`、`abilityName`、`clickable`、`text`、`description` 等。
即**存在 windowId-free 的组件树路线**,r1 少看了一层。

真正的阻塞是**产物形态,以及它带来的 effect 等级**:

1. `capture-ui-dump` 的 `kind` 是 `captureRemoteStdout`,而 dumpLayout 写设备文件;
2. 更关键的是该步骤声明 `effect: readOnly`,**往设备写文件是 deviceMutation**。
   第 2 条不是 lowering 能藏起来的 —— 藏起来就等于绕过副作用授权平面,正是
   `PRODUCT-LOOP.md` 开篇禁止的事。D10 那种"把 readback 塞进同一个 step 的进程
   序列里"的办法在这里用不了:那招只添只读命令,不改声明的 effect。

所以这一条必须走 Catalog 变更,而不是又一次 provider 内部修补。

### What(r2 交付面)

1. **`capture.diagnostics@1` 新增三个 optional 步骤**:`capture-ui-tree`
   (`captureRemoteFile` / `deviceMutation` / `bestEffortCleanup`)、
   `receive-ui-tree`(`receiveFile` / `readOnly`)、`cleanup-ui-tree-temp`
   (`cleanupOwnedRemotePath` / `deviceMutation`)。三者均无 `actionRef`——
   文件型步骤按 kind 映射,与既有 trace 腿一致,故**不动**
   `openspec/contracts/catalogs/**`。
2. **新增输入 `uiComponentTree: boolean, default false`**,并新增声明产物
   `ui-tree.json`(`application/json`、`privacy: sensitive`、`required: false`)。
3. **effect 随输入升级**,形态与 `traceCategories` 完全一致:未请求时计划
   effect 与今天逐字节相同(E0、`defaultReadOnly`);请求时升 `deviceMutation`,
   走 `standingCapability` / `defaultPolicyIssuance` 既有路径。
4. **provider**:新增 typed action lower 为
   `-t <k> shell uitest dumpLayout -p <provider-owned remote path>`(不带
   `-w`/`-d`),接收与清理复用已落地的 `.receiveOwnedArtifact`(D4 的
   `HostLandingExpectation`,按落地文件的大小与 SHA-256 判定)与
   `.cleanupOwnedRemotePath`;`HDCUIDumpRequest.Scope.componentTree` 的
   fail-closed 分支随之退役,由这条真实路线取代。
5. **窗口清单不受影响**:`capture-ui-dump` 仍是 windowInventory / stdout /
   readOnly,`ui-dump.json` 语义不变。组件树是**新增的第二个产物**,不是替换。

### 一个必须写进提案的实现约束(否则必然返工)

`ui-tree.json` 是 JSON 且含屏幕文本(上文实测有 `text`/`description`),属
`privacy: sensitive`。而 `RuntimeArtifactStore.publishFile` **刻意拒绝**
`text/*` 与 `application/json` —— 文件型发布跳过脱敏。因此组件树**不得**复用
D4 给 `trace.htrace` 铺的 `fileBackedArtifacts` 路径(那条路对二进制 trace 是对的,
对含文本的 JSON 是错的),必须:收到文件 → 有界读入 → 走会脱敏的 `publish`。
两条腿看起来像,发布路径必须不同。

### 真机状态

命令面已是 `[R]`(上文);**ArkDeck 的 lowering 与端到端未经真机**——实现 PR 后
需要一次设备窗口复验,期间按既有 fail-closed 语义(收不到文件=`.unknown`、
空文件=`.failed`)运行。记为台账 D1 的后续行,不得以本提案的 `[R]` 冒充
实现已验证。

## Out of scope

- `-w <windowId>` 的 window-scoped 深层 dump(r2 只交付整屏 windowId-free 形态);
- 组件树与窗口清单的关联分析(两个产物各自独立发布,关联留给消费方);
- 基于组件树的 UI 输入(`uitest uiInput`);
- hilog `-x` 快照与 durationSeconds 的语义对齐;
- `openspec/specs/ui-dump/spec.md` 的 recipe 语义(不变;本 change 只改
  runtime step 绑定到当下可诚实执行的子集)。

## 平台影响

macOS runtime plane only;Windows/Linux not started,不受影响。

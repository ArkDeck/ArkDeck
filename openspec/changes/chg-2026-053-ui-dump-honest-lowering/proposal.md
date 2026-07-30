---
id: CHG-2026-053-ui-dump-honest-lowering
revision: 1
status: approved # 携 approved 落地:维护者 review + merge 本 PR 即批准(enforcement 批准语义)
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

1. **契约新增 `windowInventory` action**(`diagnostics-stdout.yaml`):
   `captureRemoteStdout`/stdout,required_inputs `[byteBudget]`。语义 = 全窗口
   清单,对应 CHG-2026-008 真机验证过的 INV-1 形态
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

## Out of scope

- componentTree 的 windowId 契约修订与 window-scoped 深层 dump(后续垂直任务);
- hilog `-x` 快照与 durationSeconds 的语义对齐;
- `openspec/specs/ui-dump/spec.md` 的 recipe 语义(不变;本 change 只改
  runtime step 绑定到当下可诚实执行的子集)。

## 平台影响

macOS runtime plane only;Windows/Linux not started,不受影响。

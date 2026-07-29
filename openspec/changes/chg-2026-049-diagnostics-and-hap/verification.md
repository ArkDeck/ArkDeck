# CHG-2026-049 Verification Plan

> Change:CHG-2026-049-diagnostics-and-hap@r1
> Status:planned
> Core baseline:CORE-2.1.0 (canonical Core AC not claimed)

## Environment

- contract/fake 面:protected-main checkout,macOS arm64;fixture 工具
  (`ArkDeckFakeHDCFixture`)经 descriptor 绑定 dispatcher 真实 spawn;
- realHardware 面:维护者设备窗口(DAYU200 + 安装态 HDC 3.2.0f);
  `DHA-HW-002` 另需维护者经 merged PR 签发的 E1 RuntimeCapability;
- 设备原始日志/trace/dump 永不入仓;E2 面对本 change 全程禁止。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `DHA-ART-001` | artifact 模型契约 + 安全负向 + GC/quota 矩阵 | 元数据完整(含 hash/privacy/retention/binding snapshot);客户端只能按 ID/lease 访问,路径不可指定;path traversal/symlink 逃逸被拒;GC 不删 active/pinned;quota 逼近时拒新采集而非破坏既有;`observe.device@1` 四 artifact 真正落盘且可读 | contract |
| `DHA-CAP-001` | capture.diagnostics@1 编排契约 + 部分失败/取消/预算矩阵 | 一次请求产出 hilog/ui-dump/trace/index/summary;**部分成功逐 artifact 标注**,缺项不得记为整体成功;cancel 在安全边界收取已完成产物;超 byte budget 有序截断或失败;远端清理失败记 cleanup debt 且可被 reconcile 消费 | contract |
| `DHA-HAP-001` | debug.hap@1 编排契约 + E1 授权/补偿矩阵 | install 成功仅由 **package readback** 判定、start 成功仅由 **process/ability readback** 判定(exit 0 + 无 readback ⇒ 不得 succeeded);缺/错 capability fail-closed;失败按 cleanup policy 补偿;unknown 即停后续 mutation 并 reconcile;HAP 只能来自 artifact lease | contract |
| `DHA-HW-001` | 维护者窗口:真机 capture.diagnostics@1 | 一次提交产出预期 artifact 集合并可经 `artifact.*` 读取;duration/filter/category 生效;远端临时文件清理或记 debt | realHardware(窗口后补记) |
| `DHA-HW-002` | 维护者窗口 + 维护者签发的 E1 capability:真机 debug.hap@1 | 一次 runtime request 完成 install→start→capture→stop;readback 证据齐全;capability 按次消耗;缺 capability 时零 dispatch | realHardware(窗口后补记) |

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

- 编排:preflight → hilog → ui-dump → trace → receive → 校验 → 索引 →
  cleanup → finalize,步骤顺序与 catalog 声明一致;
- **部分成功**:trace 缺失时 `capture-summary.json` 与 job 结果逐项标注
  该 artifact 状态,整体不得记 succeeded-with-all;
- cancel:运行中取消 → 停止仍在跑的采集、在安全边界收取已完成 artifact、
  状态为 cancelled(非 failed 亦非 succeeded);
- 预算:超总 byte budget → 有序截断并标注,或失败;两种都不得写满磁盘;
- 远端:temp 路径由 provider 铸造;清理失败 → cleanup debt 记录并可被
  后续 reconcile 消费(测试驱动一次消费)。

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

## `DHA-HW-001` / `DHA-HW-002`(realHardware,窗口后补记)

- 窗口步骤由 Agent 起草并先在 host 侧自测一切可测项后交付;维护者亲手
  执行并贴回 transcript;Agent 核验后以 evidence-only PR 补记;
- `DHA-HW-002` 的 E1 capability 由维护者经 merged PR 签发,Agent 不得
  创建/修改/批准;窗口内如实记录 capability 消耗;
- 连接键/序列号脱敏入仓;raw 采集产物留 daemon 私有目录;
- 任一步失败如实记 blocked-attempt,不降级、不以 fixture 顶替。

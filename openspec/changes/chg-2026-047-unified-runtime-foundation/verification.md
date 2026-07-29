# CHG-2026-047 Verification Plan

> Change:CHG-2026-047-unified-runtime-foundation@r1
> Status:planned
> Core baseline:CORE-2.1.0 (canonical Core AC not claimed)

## Environment

- protected-main checkout,macOS arm64,Swift 6.3.x;全部验证为
  contract/unit/fake-integration(进程级 crash fixture 属 fake 类);
- 安装态 HDC、真实设备、网络监听、destructive dispatch 对本 change 禁止。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `URB-PROV-001` | provider 契约测试 + 注入负向 | typed action 封闭:API 面无 executable/argv/shell 载体;HDC 与 Rockchip adapter 在同一引擎注册;verify 基于语义判定(exit0+空输出≠成功);reconcile 面存在且 fail-closed | contract |
| `URB-HDC-001` | 拆分前后全量套件 + profile parser 矩阵 | `HDCProduction.swift` 拆为职责组件且既有 HDC/golden/supervisor 测试零修改零回归;观察族输出经版本 profile+语义解析(空白/诊断文本差异不误红);未知版本 → unsupported fail-closed | contract |
| `URB-DAEMON-001` | UDS 集成测试(双客户端并发)+ 权限/协议负向 | 两个独立客户端可同时查询同一 daemon;重复启动返回既有实例信息;socket 目录 0700/socket 0600;协议未知主版本拒绝;transport 与 handler 分离(handler 可用内存 transport 测试) | contract |
| `URB-JOB-001` | fake integration + 进程级 crash-window fixture | dispatch 前 durable intent(WAL gate 生产接线);intent 后 crash → 重启不重发、状态 waitingForRecovery/outcomeUnknown;同 idempotencyKey 返回原 job 零新副作用;同设备两 mutation 不并发;cancel 只在安全边界;job timeline 含 intent/dispatch/verify/reconcile | contract |
| `URB-COMPAT-001` | 全量既有套件 + adapter 等价 | Swift 全量零回归(含 chg-2026-022/043 supervisor 契约与全部 golden);`RockchipFlashExecutionHost`/`HDCApplicationDiagnosticsFacade` 公有面不变;脚本套件全绿 | contract |

## `URB-PROV-001`

- `DeviceProvider` 四方法(resolveFacts/lower/verify/reconcile)契约;
- action 为封闭枚举:编译面不存在 string command 构造路径;负向测试确认
  provider API 无任何 argv/shell/executable 参数面;
- `ProviderFacts` 含 tool 版本/hash、server facts、device identity、mode、
  build/profile、采集时间;
- verify 语义:exit 0 + 未识别输出 → `.unsupported`/`.unknown`,绝不映射
  succeeded;
- 双 provider 注册表:同一引擎可解析 hdc 与 rockchip 两个 providerID。

## `URB-HDC-001`

- 拆分为纯移动:`git log --follow` 可追溯;既有 HDC 相关测试文件零修改;
- 新 `HDCCompatibilityProfile`:登记版本(3.2.0d/3.2.0f 族)→ 观察族
  parser 选择;profile 未登记版本 → unsupported;
- parser 矩阵:等价语义不同空白/顺序无关诊断行 → 同一解析结果;截断/
  invalid UTF-8/空输出 → 显式 outcome;
- destructive/lifecycle 面继续走既有 golden 精确 pin(测试证明未接入新
  parser)。

## `URB-DAEMON-001`

- 集成测试:启动 daemon(临时状态目录)→ 两个 `ArkDeckAgentClient` 并发
  health/operation list/job submit → 结果一致且无串扰;
- 第二实例启动 → 返回既有实例信息(不抢占、不双写);
- 权限:socket 父目录 0700、socket 0600(测试断言 stat);零 TCP 监听
  (测试断言无网络 fd);
- 协议:`protocolVersion` major≠1 → 结构化拒绝;未知 method → 结构化
  错误;畸形 JSON → 错误响应而非崩溃;
- daemon 重启后 job/result 仍可查询(状态目录持久)。

## `URB-JOB-001`

- WAL:引擎 dispatch 必经 `WriteAheadIntentGate`;fixture 在
  「intent 已持久、dispatch 未发」与「dispatch 已发、outcome 未记」两窗口
  SIGKILL,重启后:窗口一可安全重做或继续;窗口二 → outcomeUnknown +
  零自动重发(计数器证明);
- idempotency:同 key 二次 submit → 同 jobID、副作用计数不变;不同 key
  → 新 job;ledger 重启后仍生效;
- 互斥:同 targetID 两个 mutation job → 第二个排队/拒绝,不并发(fake
  provider 计数证明);E0 并发按 catalog concurrencyKey 放行;
- cancel:running 中 cancel → 安全边界后 cancelled;critical step 不强杀;
- timeline:job 记录含 request、resolved binding revision、provider
  facts、bundle digest、capability usage、per-step intent/receipt/outcome。

## `URB-COMPAT-001`

- 全量 `swift test` 与 PRE-00/MU-1 基线对账零回归;
- 既有 Rockchip/HDC/supervisor/golden/journal/binding 契约测试文件零修改;
- 脚本套件(check-sdd/62/50/8/33/host_loop 644)全绿。

# OpenHarmony Tool Integration Profile

> ID：OPENHARMONY-TOOLS  
> Version：0.3.0
> Status：in baseline CORE-2.0.0（ratification 状态见 `openspec/baselines/CORE-2.0.0.yaml`） / version-probed at runtime  
> Core baseline：CORE-2.0.0

本文件记录当前 OpenHarmony/HDC 工具语义和 Adapter 输入。它不是平台 Profile，也不得覆盖 Core；任何具体命令都必须经当前 tool/device probe 证实。每个执行 Task SHALL 固定本文件的 version 与 SHA-256；parser family、命令映射或 capability 判断变化必须走 integration change。

## HDC host topology

- HDC 是 client/server/daemon；默认 host server 端口通常为 8710；
- `OHOS_HDC_SERVER_PORT` 和显式 `-s` 影响 endpoint，显式参数优先级由当前 HDC 指南/探测确认；
- 设备命令使用当前 durable binding 的 `hdc -t <connectKey>`；
- 只读环境诊断候选包括 version、checkserver、`list targets -v` 及等价命令；
- API 26.0.0+ subserver 能力只探测，不在 MVP 自动管理；
- macOS/Linux 当前实现常见 key 位于 `~/.harmony/hdckey(.pub)`，但 Core 不硬编码，Adapter 只报告当前工具证据；
- Unauthorized parser 覆盖 E000002/E000003 等已验证输出 family，未知输出保留 raw；
- `OHOS_HDC_ENCRYPT_CHANNEL` 当前文档默认关闭；设置值不等于已成功协商，仍需 connection evidence。

## HiDumper

窗口 inventory 样本：

```text
hidumper -s WindowManagerService -a '-a'
```

Recipe 数据位于 `openspec/contracts/catalogs/dump-recipes.yaml`。Adapter 必须处理 stdout、sidecar、固定旧文件名和 unknown output family，禁止全局 `/data` cleanup。

## Trace tools

- 分别 probe hitrace/bytrace 的存在、help/list、duration、buffer、output、begin/finish 和 tag；
- logical preset 位于 `openspec/contracts/catalogs/trace-presets.yaml`；
- remote path 使用 Job UUID 隔离，推荐 `/data/local/tmp/arkdeck/<jobUUID>/`，但设备权限/Profile 可选择等价 owned path；
- raw ftrace 由 host 后处理；固定删除前两行被禁止，除非 parser 证明是 chatter。

## Parameters

附件 Debug Profile 位于 `openspec/contracts/catalogs/debug-parameters.yaml`。Adapter 逐项 probe、读写、read-back，并遵守 missing/unreadable/value 与恢复 contract。

## HiLog

- 以当前 `hilog --help` 和权限 probe 选择等级、domain/tag、PID、buffer 和 device-side logging options；
- `hilog -r` 等清 buffer 命令在常见版本中是全局破坏性操作，只能作为显式危险 action；
- 参数语义未知时只使用 host stream/rotation，不猜测 device buffer mutation。

## HDC/flashd

首个 Provider 的研究路径包括：进入 updater/flashd、`hdc flash <partition> <image>`、`hdc update <package>` 以及显式选择的 erase/format。所有命令都必须由目标 toolchain/device probe 和 Profile 验证；它们不适用于 fastboot/厂商协议，也不证明 production user build 可 root/unlock。

## Golden fixture families（pack 1.0.0，registered by CHG-2026-005/TASK-I5-001）

Fixture pack：`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/`
（registry：`registry.json`；逐 fixture ID/stream/exit/classification/lineage/SHA-256 与
`INTEGRATION-PROFILES.lock.yaml`、`core-conformance.yaml` 三方一致登记）。观测来源：
hdc client/server `Ver: 3.2.0d`（binary SHA-256
`48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`，macOS 26.5.2 受控人工
capture 2026-07-18；failure 字节为 M0A 候选原样提取）。

| Family | Fixture ID | Probe/来源命令 | 真实输出形态（3.2.0d） | Semantic mapping |
| --- | --- | --- | --- | --- |
| failure（unauthorized） | `hdc-golden-failure-unauthorized` | 命令结果（M0A 候选） | `[Fail] ErrorCode: E000003 Unauthorized device` | `failure.unauthorized` |
| failure（offline） | `hdc-golden-failure-offline` | 命令结果（M0A 候选） | `[Fail] Offline after transfer` | `failure.offline` |
| success | `hdc-golden-success-uninstall` | `hdc uninstall <bundle>`（exit 0） | `[Info]... msg:uninstall bundle successfully.` + `AppMod finish`（CRLF） | `success` |
| healthy | `hdc-golden-healthy-checkserver` | `hdc checkserver`（exit 0） | `Client version:Ver: X, server version:Ver: X` | `healthy` |
| version | `hdc-golden-version` | `hdc -v`（exit 0） | `Ver: X` | `version` |

**Success-marker 实测披露**：3.2.0d 的 install/uninstall 成功输出**不含** M0A parser 假设的
`[success]` 标记；真实成功语义由 `msg:... successfully.` + `AppMod finish` 承载。当前 parser
对该 fixture 判 `unknownOutput`（由 `HDCGoldenResourceContractTests` 钉死）。按登记形态接线
parser 属于 TASK-M1-006，不得以放宽正则或静默改标记的方式提前采用；未登记 output family
一律维持 unknown/unsupported，exit 0 单独不构成 success。

## Supported family rule

Parser/Adapter 只支持声明并有 golden fixture 或真实 evidence 的 output family。未知 family 显示 unsupported/raw detail。增加 family 属于 integration change，不得通过宽松正则把未知错误判为成功。

## Production read-only probe registry（pack 1.0.0，registered by CHG-2026-015/TASK-I15-001）

结构化允许列表：`openspec/integrations/openharmony/readonly-probes.yaml`
（registry `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`，SHA-256
`3c0a252b20e96d2ad3b92436725391e7bd1119588db684f42bbe26dbcb7ebcde`）。SwiftPM
资源包：`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/`
（manifest `resources.json`，SHA-256
`6f09b841237bb36e1a6a72bbf55a714a61622c60508446d0ee6d6295cd89bf22`）。registry、资源
manifest、逐 receipt/control resource 与 `INTEGRATION-PROFILES-0.4.0` 形成 hash closure；
resource 内的 `registry.yaml` 与 integration registry 字节相同。

| Family | 3.2.0d / macOS conclusion | Probe contract | Authority boundary |
| --- | --- | --- | --- |
| `serverIdentityGeneration` | `supported` | commandless `platformProcessObservation`；要求已存在且唯一的 server process/start identity、选定 executable identity 与 exact listener endpoint；同一 recipe 用于 post-dispatch observation | `checkserver`、PID 形状、endpoint reuse、caller generation 均不能建立 identity/ownership；server absent 时 `unavailable` 且 command/server-start dispatch 为 0 |
| `selectedDeviceAuthorizationBinding` | `supported` | exact argv `list targets -v`；仅在有效 server-identity receipt、exact endpoint 与既有 durable binding identity/revision 全部存在时运行 | 只比较登记 row 与既有 binding；不得选 default target、创建/递增 binding 或推断 channel protection；unknown/stale/mismatch/timeout/cancel fail closed |
| `keyAccessDiagnostics` | `unsupported` | 不登记 argv 或 file-access dispatch | 受控记录仅证明 key material 缺席，未识别 configured/user-approved HDC key locator；传统默认路径不能授予 path authority。私钥 read/hash/copy/delete/chmod/upload 与 raw key/path logging 均禁止 |
| `subserverCapability` | `unsupported` | 不登记 argv 或 dispatch | 上游文档复核未定位 exact 3.2.0d revision 的零 lifecycle/device-migration client-local probe；不得从 version、`spawn-sub`、`killall-sub` 或 mutation alias 推断 support |

每个 entry 必须作为整体消费：tool/profile/registry version、executable identity、exact argv、
existing-server/endpoint precondition、effect、raw/receipt family、semantic mapping、authority、timeout、
cancellation、cleanup 与 provenance 任一不匹配即 `unsupported`/`unknown`。Agent-authored control vectors
仅验证 negative behavior，不构成 production provenance。登记本身不修改或授权 M1-006 production
adapter，不改变任何 `AC-HDC-*`、platform conformance、hardware/support/release 状态。

0.2.0 consumer 不认识本 registry，也不得从 0.3.0 文档局部借用 argv 或 authority。采用
`OPENHARMONY-TOOLS@0.3.0` 必须由 consumer 的独立 approved task 固定完整 registry/hash closure。

# OpenHarmony Tool Integration Profile

> ID：OPENHARMONY-TOOLS  
> Version：0.1.0  
> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`） / version-probed at runtime  
> Core baseline：CORE-1.0.0

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

## Supported family rule

Parser/Adapter 只支持声明并有 golden fixture 或真实 evidence 的 output family。未知 family 显示 unsupported/raw detail。增加 family 属于 integration change，不得通过宽松正则把未知错误判为成功。

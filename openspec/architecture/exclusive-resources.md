# Exclusive Resource Identity

> Status：review candidate  
> Applicability：all Agent Task execution

Task/claim 互斥资源使用受保护、规范化的 URN，而不是自由文本：

```text
arkdeck-resource:<kind>:<canonical-id>
```

允许 kind：`hdc-server`、`device-binding`、`host-volume`、`vm-snapshot`、`fixture`、`toolchain`、`host-lock`、`workspace`。`canonical-id` 只允许 URI unreserved 字符和 percent-encoding；endpoint 中的 `:`、路径分隔符和空白必须编码，不得用显示名称、盘符、mount path、IP 别名或 USB endpoint 临时值代替稳定身份。

- `hdc-server`：ID 是 `SHA-256("arkdeck-hdc-server-v1" NUL endpoint NUL decimal-generation)` 的小写 hex；默认全局 endpoint 的所有别名必须先规范化为同一 endpoint。
- `device-binding`：ID 是 `SHA-256("arkdeck-device-binding-v1" NUL stable-device-identity NUL decimal-binding-revision)` 的小写 hex；不能使用 connectKey。
- `host-volume`：ID 是 `SHA-256("arkdeck-host-volume-v1" NUL VolumeIdentityResolver-result)` 的小写 hex；不能使用输出目录字符串。
- `vm-snapshot`、`fixture`、`toolchain`、`host-lock`、`workspace`：使用治理注册的 immutable ID/hash identity。

Task packet approval 固定 URN；claim 必须逐项相等。核心共享资源的 ID 是小写 SHA-256，并由受保护 claim service 签发 `resourceIdentitySet` 证明：HDC 使用规范 endpoint + server generation，设备使用稳定 identity + binding revision，主机卷使用平台 Port 返回的稳定 volume identity。Guard 从证明字段重新计算 ID；路径、IP、显示名称等别名不能自行成为身份。受保护 claim 服务按 canonical URN 做原子冲突检测，Task ID 仍是隐式互斥资源。`deviceNetworkAccess` 至少声明一个 `hdc-server`，任何 real-device capability 至少声明一个 `device-binding`，`externalFilesystemWrite` 至少声明一个 `host-volume`。无法解析为规范身份时 Task 不得进入 `ready`。
Controlled-lab plan 的 target 必须携带这三个 URN；guard 从 exact endpoint/generation、device identity/binding revision 与 volume identity 重新计算并要求它们存在于 claim。`%xx`、显示名称或另一个逻辑 token 不能替代计算结果。

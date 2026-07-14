# Exclusive Resource Identity

> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> Applicability：产品运行时的共享资源协调(HDC server、device binding、host volume);V1 的 task claim 互斥机制已废止

Task/claim 互斥资源使用受保护、规范化的 URN，而不是自由文本：

```text
arkdeck-resource:<kind>:<canonical-id>
```

允许 kind：`hdc-server`、`device-binding`、`host-volume`、`vm-snapshot`、`fixture`、`toolchain`、`host-lock`、`workspace`。`canonical-id` 只允许 URI unreserved 字符和 percent-encoding；endpoint 中的 `:`、路径分隔符和空白必须编码，不得用显示名称、盘符、mount path、IP 别名或 USB endpoint 临时值代替稳定身份。

- `hdc-server`：ID 是 `SHA-256("arkdeck-hdc-server-v1" NUL endpoint NUL decimal-generation)` 的小写 hex；默认全局 endpoint 的所有别名必须先规范化为同一 endpoint。
- `device-binding`：ID 是 `SHA-256("arkdeck-device-binding-v1" NUL stable-device-identity NUL decimal-binding-revision)` 的小写 hex；不能使用 connectKey。
- `host-volume`：ID 是 `SHA-256("arkdeck-host-volume-v1" NUL VolumeIdentityResolver-result)` 的小写 hex；不能使用输出目录字符串。
- `vm-snapshot`、`fixture`、`toolchain`、`host-lock`、`workspace`：使用治理注册的 immutable ID/hash identity。

这套规范身份供未来产品运行时使用:HDC 使用规范 endpoint + server generation,设备使用稳定 identity + binding revision,主机卷使用平台 Port 返回的稳定 volume identity;路径、IP、显示名称等别名不能自行成为身份。多任务并发执行的 claim 级互斥属于 V1 机制,已废止;若未来出现真实并发执行者,再以轻量方式重新引入。

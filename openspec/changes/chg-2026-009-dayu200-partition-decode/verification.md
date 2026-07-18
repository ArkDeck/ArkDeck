# CHG-2026-009 Verification Plan

> Status:planned
> Change:CHG-2026-009-dayu200-partition-decode@r2
> Core baseline:CORE-2.0.0

本文件是 immutable verification plan;实际结果由 Task run/evidence 记录。
decoder 零 path open/device read,workflow 零设备/网络/subprocess;identity gate
不命中即整体拒绝。trusted-fd/sandbox broker evidence 缺失即整体 fail。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| DECODE-DAYU200-PARTITION-001 | identity-gated streaming decode + branch-complete tests | pinned identity 强制;允许以 ≤1 MiB chunk 消费并立即丢弃目标前 member body,不得解析/hash/返回/记录/持久化/跨 chunk 保留,取得目标后停止;raw identity/gzip pass、header/body count+bytes 精确审计;封闭文法未知形态显式 fail;evidence 含映射表/S2 引用/hash 引用,无原文无 locator,仅对 pinned 镜像成立 | pending |
| DECODE-DAYU200-INPUT-BOUNDARY-001 | static call-target audit + descriptor negative tests + macOS sandbox evidence review | production decoder 只接收预打开只读 fd,零 path open;首次 read 前 fstat 普通文件,非普通 fd 零 read fail;launcher 是独立签名/验证的 sandbox broker,封闭 entitlement/policy 排除所有 character/block device-node namespace(含 USB/serial/raw disk)并以 descriptor 传递;现有含 device entitlement 的 App 不自动合格;缺任一 broker/policy/signing evidence 即 fail | pending |
| DECODE-DAYU200-RECONCILE-001 | mapping ↔ 17 成员清单对账 | 每成员归位或显式孤儿;每无成员分区显式列出;non-authoritative,不推导烧写地址,零烧写/兼容/支持声明 | pending |

> Revision r2(2026-07-18):上表替换 r1 的 literal no-other-member-read 与
> path-open 静态零设备证明。r1 run/evidence 不追溯重判；必须由 r2 implementation
> + fresh run 重新验证全部三项 AC。

## Gate

- 只读硬边界:任何 subprocess/网络/设备访问或磁盘解包出现即整体 fail；sandbox
  deny 不得通过主动打开真实 device node 取证,设备类负测使用 synthetic/mock fd
  metadata + entitlement/policy/signing inspection。
- capability gate:仅 caller 声明“fd 可信”不构成 evidence；decoder 静态出现
  `open/openat/lstat` path target、broker 含 device entitlement、policy 未封闭或
  descriptor 传递链不明确,任一即 fail。
- stream gate:非目标 body 只允许为推进目标前单流而消费；读取目标后成员、
  任意解析/hash/log/persist/跨 chunk retention 或计数漂移均 fail。
- 解码失败是合法结果:未知文法如实记录,不得猜测凑表。
- 本 evidence 是 DEC-002 输入的候选,登记须另行 governance PR(先例 #52);
  gap 状态不由本 change 改变。

---
id: CHG-2026-009-dayu200-partition-decode
revision: 2
status: approved # r1 经 #70 批准;r2(stream-discard+trusted-fd/sandbox 修订)仅在 revision PR 由维护者 review/merge 后生效
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Route-B ①:pinned 镜像 parameter.txt 只读解码(分区表语义)

## Why

CHG-2026-007 route-b-plan.md 批准的立项顺序第①步。
`GAP-DAYU200-PARTITION-SEMANTICS` 的关闭事实定义:parameter.txt 的
mtdparts/CMDLINE 语法被逐字段解读,产出分区名→(offset,size,属性)的可复查
映射表,并与 archived CHG-2026-003 的 17 成员清单逐项对账。本 change 是纯只读、
零设备、零网络的离线解码——CHG-2026-003 刻意不解码成员字节,本 change 在其
pinned identity 之上补上这一步。

r1 执行审查暴露两个不可由实现自行解释的冲突:目标是单一 gzip/DEFLATE tar
stream 的第 8 个成员,定位它必须消费前 7 个成员内容；同时 path-based
`lstat→open→fstat` 无法排除设备节点在 open 前替换、设备先被打开的竞态。
r2 将前者明确为有界 stream-discard,并把后者提升为 trusted-fd + macOS OS
sandbox broker 的平台边界；缺 broker/policy evidence 时 fail closed。

## What changes

### In scope

- `scripts/partition_decode/`(stdlib-only,沿 CHG-2026-003 scan.py 先例):
  1. 固定输入门:archive 必须命中 CHG-2026-003 pinned identity
     (732948803 bytes / SHA-256 `fc7637…5280`),不匹配即拒绝;
  2. 流式定位并读取 `parameter.txt`:允许为推进单一 gzip/tar stream 而消费
     目标前的成员 body,但只允许固定上限 chunk 的立即丢弃；不得解析、hash、
     返回、记录、持久化或跨 chunk 保留非目标 body,取得目标后立即停止；审计
     精确记录 raw identity/gzip 两遍、tar header、前置 body count/bytes;
  3. 按 Rockchip mtdparts/CMDLINE 语法逐字段解析:`0x偏移@0x起点(名称[:属性])`,
     封闭文法、未知形态显式 fail(不猜测);
  4. 与 CHG-2026-003 成员清单对账:每个 img 成员映射到哪个分区、孤儿成员/
     孤儿分区显式列出;
  5. 产出结构化 evidence(映射表 + 对账表 + S2 文档来源引用 + 成员 hash 引用),
     沿 deterministic evidence bytes 约定;**parameter.txt 原文不入仓库**,仓库内
     只记结构化结论与 hash;
  6. 合成 fixture 单元测试(文法正/负分支全覆盖)+ 静态零 subprocess/网络/
     device-mutation 审计；production decoder 不得含 path-based open。
- trusted input boundary(r2 仅批准 design/AC,实现 artifact/path 由后续独立
  task-scope/readiness PR 固定):production decoder 只接收 trusted launcher
  预打开的只读 fd/capability,首次读取前 `fstat` 且仅接受普通文件。launcher
  必须是独立验证的 macOS sandbox broker:封闭 entitlement/policy 明确排除所有
  character/block device-node namespace(含 USB/serial/raw disk),并以 descriptor
  传递给 decoder。现有 ArkDeckApp 含 USB/serial entitlement,不得仅凭已有
  App Sandbox 声明充当本 broker。
- evidence 结论显式标注"仅对该 pinned 镜像成立",non-authoritative。

### Out of scope

- 任何设备操作(含只读)、任何烧写地址推导(GAP-FLASH-ADDRESSES 属后续 change,
  route-b-plan 明文本阶段不从成员字节推导地址)、协议/恢复路径事实;
- 以 `lstat/open/fstat`、仅 caller 声称 fd 可信、或现有 App Sandbox entitlement
  作为零设备证明；broker/policy/签名产物 evidence 缺一即保持 blocked;
- 修改 specs/contracts/hardware-matrix/integration lock;
- `GAP-DAYU200-PARTITION-SEMANTICS` 的 open-questions.md 登记状态变更(evidence
  合入后由独立 governance PR 依先例 #52 登记为 DEC-002 输入);
- 支持/兼容性声明。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Change-local AC/pass-fail:r2 修订；不改 current specs/contracts
- Platform Profile / Integration lock / hardware matrix:unchanged

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | change-local platform revalidation required | trusted-fd/sandbox broker 边界须有平台 evidence；不改变已发布能力状态 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- 只读硬门:零 subprocess、零网络、零 device mutation、不解包到磁盘；decoder
  零 path open/device read,broker 由 OS sandbox policy 排除 character/block
  device-node namespace;
- 威胁模型覆盖恶意 archive bytes、symlink/FIFO/device path 与 capability 建立前
  的并发替换；信任 macOS kernel/code-signing/sandbox enforcement,不声称抵御
  compromised kernel/root。仅 trusted fd 而无 sandbox broker evidence 不通过;
- stream-discard 只解决顺序压缩格式的物理定位,不授权解析/保留非目标内容；
- archive locator 不写入 evidence(CHG-2026-003 先例);parameter.txt 原文不入
  仓库;
- 解码失败(未知文法)是合法结果:显式 fail 并如实记录,不得为凑表而猜测。

## Approval

- Proposal 经 PR #69 合入 main(`a7f885e`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由本 approval-only PR(先例 #14/#40/#55)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。本批准不产生任务执行:
  TASK-PD-001 另需独立 readiness/status PR 转 ready 后方可开工;只读硬边界不因
  批准改变。
- Revision r2(2026-07-18):按 TASK-PD-001 r1 执行审查，将
  `DECODE-DAYU200-PARTITION-001` 的“不读取其他成员内容”修订为封闭、有界、
  可审计的前置 stream-discard,并新增 `DECODE-DAYU200-INPUT-BOUNDARY-001`
  trusted-fd/sandbox broker gate。本 revision PR 只修订治理/设计/验证,不包含
  implementation、readiness 或 r1 evidence 重判；r1 结论保持 FAILED/BLOCKED。
  r2 仅在维护者 review/merge 后生效(先例:CHG-2026-006 r2 / PR #60)。

---
id: CHG-2026-009-dayu200-partition-decode
revision: 4
status: approved # r1 经 #70 批准;r2/r3 已合入;r4 headless/platform task decomposition 仅在本 revision PR 由维护者 review/merge 后生效
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

r2 implementation/revalidation 随后证明“不得跨 chunk retention”的字面规则仍
无法由任何顺序 DEFLATE decoder 满足:DEFLATE 允许后续 block 引用最多 32 KiB
之前的输出,解码器必须在内部保留对应的 opaque history。这个算法状态不同于
应用取得、解析或二次利用非目标 member 明文,但 r2 没有划定二者边界,所以现有
实现正确地保持 blocked。r3 只关闭这个 change-local pass/fail 歧义,不放宽
trusted-fd/sandbox、零设备、零网络、零 subprocess、无落盘或无二次利用门禁。

r3 readiness 合入后,远程 macOS host 仍处于锁屏状态,无法合法运行必须由人类经
NSOpenPanel/PowerBox 选择 pinned archive 的 fresh collector。CHG-2026-014 已批准并
验证“两轴”调度模型:headless implementation 可以用独立 contract evidence 合入,
但不得取得或关闭来源 platform AC。r4 将 TASK-PD-001 拆为 headless codec remediation
与后续 interactive platform verification 两个任务;三项既有 platform AC、同一次 fresh
run、签名 broker 与全部 support/release gate 原样保留。

## What changes

### In scope

- `scripts/partition_decode/`(stdlib-only,沿 CHG-2026-003 scan.py 先例):
  1. 固定输入门:archive 必须命中 CHG-2026-003 pinned identity
     (732948803 bytes / SHA-256 `fc7637…5280`),不匹配即拒绝;
  2. 流式定位并读取 `parameter.txt`:允许为推进单一 gzip/tar stream 而消费
     目标前的成员 body,但只允许固定上限 chunk；应用层在下一 chunk 前释放
     上一非目标明文 chunk 的全部引用,不得解析、hash、返回、记录、持久化或
     复制该明文,取得目标后立即停止；审计精确记录 raw identity/gzip 两遍、
     tar header、前置 body count/bytes 与 application-visible retention counter;
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
- opaque codec-state boundary(r3):只允许 RFC 1951/zlib 顺序解码必需的
  DEFLATE history,固定 DEFLATE base window bits 为 15、最大 history window
  32768 bytes(zlib gzip wrapper 参数为 `wbits=16+15=31`)；该 state 必须封装在
  codec 内,应用不得取得 history/body view、复制/导出 state、使用 preset
  dictionary/codec clone,或对其 parse/hash/log/persist/return。
  compressed input remainder 单独限制为 65536 bytes；目标 body 取得后立即销毁
  codec 与 remainder。这个封闭例外不允许任何应用可见的非目标解压明文跨
  chunk 保留,也不声称对 allocator residue 做 forensic zeroization。
- execution decomposition(r4):
  1. `TASK-PD-001` 只交付上述 codec configuration/lifecycle remediation、完整
     unit/static/fault regression 与新的 contract-class headless receipt evidence；它
     不运行 collector、不读取 pinned archive、不生成或重判三项 platform AC evidence；
  2. `TASK-PD-002` 只在 TASK-PD-001 的完整 implementation commit 已合入后,由解锁
     console 上的人类通过未修改的签名 broker/NSOpenPanel 选择 pinned archive,并以同一次
     create-only fresh run 验证原三项 platform AC；该任务不得修改 decoder/broker source；
  3. headless task `done` 只表示实现 bytes、branch-complete tests 与 fail-closed receipt
     contract 已闭环,不向 TASK-PD-002、原三项 AC、change verification、gap/DEC-002、
     compatibility、support、hardware 或 release 状态传播任何通过结论。
- evidence 结论显式标注"仅对该 pinned 镜像成立",non-authoritative。

### Out of scope

- 任何设备操作(含只读)、任何烧写地址推导(GAP-FLASH-ADDRESSES 属后续 change,
  route-b-plan 明文本阶段不从成员字节推导地址)、协议/恢复路径事实;
- 以 `lstat/open/fstat`、仅 caller 声称 fd 可信、或现有 App Sandbox entitlement
  作为零设备证明；broker/policy/签名产物 evidence 缺一即保持 blocked;
- 修改 specs/contracts/hardware-matrix/integration lock;
- 以 headless/synthetic evidence 关闭或降级原三项 platform AC,或让 TASK-PD-002 读取
  未合入 worktree、branch 名或未固定 artifact;
- `GAP-DAYU200-PARTITION-SEMANTICS` 的 open-questions.md 登记状态变更(evidence
  合入后由独立 governance PR 依先例 #52 登记为 DEC-002 输入);
- 支持/兼容性声明。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Change-local AC/pass-fail:r3 的三项 platform AC 不变；r4 只新增一个不替代它们的
  headless implementation contract AC 与任务依赖
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
- stream-discard 只解决顺序压缩格式的物理定位,不授权应用解析/保留非目标
  明文；r3 的 32 KiB codec history 例外只覆盖算法必需且应用不可见的内部 state;
- archive locator 不写入 evidence(CHG-2026-003 先例);parameter.txt 原文不入
  仓库;
- r4 headless run 不接触 pinned archive,只记录 synthetic/contract/static 结果；后续
  platform run 必须绑定已合入 TASK-PD-001 完整 commit 与签名 artifact hash,且三项原
  Test ID 仍来自同一次 fresh collector;
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
- Revision r3(2026-07-19):按 r2 implementation 与 blocked fresh-attempt evidence,
  将 application-visible non-target plaintext retention 与 DEFLATE 必需的 opaque
  32 KiB history 明确分离,同时新增 codec configuration/lifecycle 的封闭 evidence
  gate。本 revision PR 只修改 change-local proposal/design/verification/AC 与 blocked
  task 注记；不包含实现、fresh evidence、readiness、任务状态或既有 evidence
  重判。r3 仅在维护者 review/merge 后生效；合入后仍须独立 readiness PR 才能
  恢复 TASK-PD-001。
- Revision r4(2026-07-19):沿 CHG-2026-014 的 two-axis 模型,把 r3 codec remediation
  与必须解锁 console 的 fresh platform collector 拆为 TASK-PD-001/TASK-PD-002。
  本 revision 只修改 change-local proposal/design/tasks/verification/acceptance metadata,
  不修改源码、不运行 collector、不生成或重判 evidence,也不使任一新任务 ready/done。
  r4 合入后 TASK-PD-001 仍须独立 readiness PR；TASK-PD-002 只有在 TASK-PD-001 done、
  implementation commit 已合入且 console 可交互解锁后才可 readiness。原三项 platform
  AC 的 expected result 与 minimum evidence 不变。

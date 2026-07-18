---
id: CHG-2026-009-dayu200-partition-decode
revision: 1
status: approved # r1 proposal 经 #69 合入;批准由本 approval-only PR 的维护者 review/merge 构成
class: implementation-only
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

## What changes

### In scope

- `scripts/partition_decode/`(stdlib-only,沿 CHG-2026-003 scan.py 先例):
  1. 固定输入门:archive 必须命中 CHG-2026-003 pinned identity
     (732948803 bytes / SHA-256 `fc7637…5280`),不匹配即拒绝;
  2. 流式定位并读取 `parameter.txt` 成员(不解包到磁盘、不读取其他成员内容);
  3. 按 Rockchip mtdparts/CMDLINE 语法逐字段解析:`0x偏移@0x起点(名称[:属性])`,
     封闭文法、未知形态显式 fail(不猜测);
  4. 与 CHG-2026-003 成员清单对账:每个 img 成员映射到哪个分区、孤儿成员/
     孤儿分区显式列出;
  5. 产出结构化 evidence(映射表 + 对账表 + S2 文档来源引用 + 成员 hash 引用),
     沿 deterministic evidence bytes 约定;**parameter.txt 原文不入仓库**,仓库内
     只记结构化结论与 hash;
  6. 合成 fixture 单元测试(文法正/负分支全覆盖)+ 静态零 subprocess/网络审计。
- evidence 结论显式标注"仅对该 pinned 镜像成立",non-authoritative。

### Out of scope

- 任何设备操作(含只读)、任何烧写地址推导(GAP-FLASH-ADDRESSES 属后续 change,
  route-b-plan 明文本阶段不从成员字节推导地址)、协议/恢复路径事实;
- 修改 specs/contracts/hardware-matrix/integration lock;
- `GAP-DAYU200-PARTITION-SEMANTICS` 的 open-questions.md 登记状态变更(evidence
  合入后由独立 governance PR 依先例 #52 登记为 DEC-002 输入);
- 支持/兼容性声明。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Platform Profile / Integration lock / hardware matrix:unchanged

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no revalidation trigger | 离线研究工具,无产品代码变更 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- 只读硬门:零 subprocess、零网络、零设备、不解包到磁盘(静态审计 + 测试钉死);
- archive locator 不写入 evidence(CHG-2026-003 先例);parameter.txt 原文不入
  仓库;
- 解码失败(未知文法)是合法结果:显式 fail 并如实记录,不得为凑表而猜测。

## Approval

- Proposal 经 PR #69 合入 main(`a7f885e`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由本 approval-only PR(先例 #14/#40/#55)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。本批准不产生任务执行:
  TASK-PD-001 另需独立 readiness/status PR 转 ready 后方可开工;只读硬边界不因
  批准改变。

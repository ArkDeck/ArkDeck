---
id: CHG-2026-013-dayu200-rehearsal-preparation
revision: 1
status: verified # 2026-07-18 verification closure(先例 #20/#48):两 PREP-* AC PASS;经本 PR 维护者 review/merge 生效
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Route-B ③前置:DAYU200 演练准备(host-only,零设备)

## Why

Route-B 第③步(恢复演练,全链首个写设备操作)的立项 gate 是 archived
CHG-2026-010 预案 §6 检查单"立项时原文引用并逐项打勾"。七项中第 3 项等
TASK-PD-001、第 4/5 项是维护者人为动作,而第 1 项(恢复物料本地就绪+逐文件
全量 SHA-256 比对)、第 2 项(`rkdeveloptool` 在演练主机构建完成+无设备 `ld`
冒烟)与第 6 项的模板部分(演练记录模板就绪)是**纯 host 侧准备动作**,与
PD-001 零依赖,可先行。CHG-2026-010 §2 已预留"构建与安装属演练 change 的
前置步骤";本 change 把该前置步骤独立立项执行,使 PD-001 合入后检查单只剩
维护者人为两项,演练立项零等待。**本 change 全程零设备操作——执行期间
DAYU200 必须不连接演练主机**(负向硬前提),不勾检查单第 3/4/5 项,不立项
演练,不构成演练执行授权。

## What changes

### In scope(host-only 执行)

- **工具构建(检查单第 2 项)**:在演练主机(维护者 macOS)按 Radxa 官方文档
  步骤构建 `rkdeveloptool`:Homebrew 安装构建依赖(automake/autoconf/libusb/
  pkg-config)、自官方仓库(github.com/rockchip-linux/rkdeveloptool 或 radxa
  fork)clone 源码并记录 commit hash、`autoreconf -i && ./configure && make`;
  记录构建产物 SHA-256 与 `rkdeveloptool -v` 版本串(须 ≥1.32,CHG-2026-011
  事实清单 §3 版本约束);
- **无设备冒烟(检查单第 2 项)**:设备不在场时执行 `rkdeveloptool ld`,
  byte-exact 采集输出(预期"无设备"形态);同采 `--help` usage 文本;
- **物料复核(检查单第 1 项)**:先全量重算 pinned 镜像归档身份
  (732948803 bytes / SHA-256 `fc7637…5280`,archived CHG-2026-003 identity)
  并逐字节核对,解包后对恢复物料成员逐文件重算**全量** SHA-256,与 archived
  member-inventory.json 逐项比对制表;物料字节保存在仓库外本地路径,仓库仅入
  hash 对照表;
- **演练记录模板(检查单第 6 项模板部分)**:起草
  `evidence/rehearsal-record-template.md`——逐命令 argv/stdout/stderr/exit
  code/时间戳/判别点结论/物料 hash 引用栏位,含中止触发记录节(预案 §5 四项
  中止准则原文)与检查单七项打勾页;
- 交付 `evidence/prep-record.md`(构建/冒烟/hash 复核记录)+ run.md。

### Out of scope

- **任何设备操作**:执行期间 DAYU200 不得连接主机;`rkdeveloptool` 写类命令
  (`db`/`ul`/`wl`/`wlx`/`gpt`/`prm`/`ef`/`rd`/`cs`)零出现;
- 演练本身的立项/执行、检查单第 3(PD-001)/4(风险确认)/5(时间窗)项;
- `hdc` 的任何执行;TCP/UART;白名单外任何命令;
- specs/contracts/hardware-matrix/integration lock 修改;gap 状态变更;支持声明。

## Execution boundary(封闭命令白名单)

仅允许:`brew install automake autoconf libusb pkg-config`(或已装则跳过)、
`git clone <官方 rkdeveloptool 仓库>`+`git rev-parse HEAD`、`autoreconf`/
`./configure`/`make`、`shasum -a 256`、pinned 归档解包(`tar`)、构建产物的
`rkdeveloptool -v`/`--help`/`ld`(仅无设备场景)。网络仅用于 Homebrew 依赖与
官方源码获取,逐下载记录来源 URL 与 hash;不执行任何其它下载物。M0B 教训
适用:工具退出码不可信,成败判定基于输出标记并保留原始字节。任何白名单外
命令、任何设备枚举行出现在 `ld` 输出,即整体 fail 并中止。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Platform Profile / Integration lock / hardware matrix:unchanged

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no revalidation trigger | host 工具准备,无产品代码变更 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- 设备不在场硬前提:全部命令执行时 DAYU200 不连接;这使 `ld` 的只读性无条件
  成立(无设备可读),消除 route-b 硬序对本 change 的约束面;
- 本 change 完成后,检查单第 1/2 项与第 6 项模板部分具备打勾 evidence;
  **打勾动作本身发生在未来演练 change 立项时**(自归档路径原文引用检查单);
- 不解除任何 gap、不改变 DEC-002;演练立项仍须:PD-001 evidence(第 3 项)+
  维护者书面风险确认(第 4 项)+ 时间窗(第 5 项);
- 物料字节与构建产物均不入 git 仓库(仓库仅 hash/版本/输出记录)。

## Approval

- Proposal 经 PR #90 合入 main(`09e7c55`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由 approval-only PR #91 合入 main(`cfb86e7`)将本 change
  置为 `approved`(先例 #14/#40/#55);TASK-RR-001 经 readiness PR #92
  (`5eb8062`)转 ready。

## Verification closure(2026-07-18)

- 交付物 `evidence/prep-record.md` + `evidence/rehearsal-record-template.md` +
  `evidence/runs/TASK-RR-001/run.md` 经 PR #93 合入 main(`30cca61`);
  TASK-RR-001 经状态 PR #94 合入 main(`b71f7b0`)翻转 done。两个 change-local
  AC(`TEST-PREP-DAYU200-TOOLING-001`、`TEST-PREP-DAYU200-MATERIALS-001`)在
  run.md 二值 PASS;设备不在场 attestation 在案,全部命令在封闭白名单内,
  判定按输出标记(`ld` 无设备 exit=1 如实记录)。
- 上述 PR 的维护者 review/merge 构成 `verification.md` acceptance matrix 所
  要求的 verification confirmation。本文件的 `status: verified` 仅在包含本状态
  变更的 verification closure PR 经维护者 review 并合入 `main` 后生效;verified
  不改变边界——本 change 只为 archived 预案 §6 检查单第 1/2 项与第 6 项模板
  部分提供打勾 evidence,打勾动作属未来演练 change 立项时;第 3/4/5 项保持
  open;不构成演练执行授权;不解除任何 gap;DEC-002 保持 open。archive 由
  后续独立 archive PR 完成(先例 #21/#49)。

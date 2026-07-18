# DAYU200 M0B Bring-up Design

> Status:draft
> Proposal:CHG-2026-006-dayu200-m0b-bringup@r1
> Core baseline:CORE-2.0.0

## Purpose and boundary

一次人类操作的真机 bring-up:对物理 DAYU200(RK3568)建立首批 `observed` 级
real-device 事实。不实现任何产品能力、不烧写、不写设备状态、不做支持声明。
Agent 的角色仅限:起草 runbook/采集脚本、复核 evidence 完整性、起草状态与
matrix 更新 PR;任何真实 `hdc` 进程只由人类启动。

## Fixed inputs

- 目标设备:DAYU200(RK3568),DEC-001 decided(#53);
- 参考镜像 identity(仅作对照,不要求设备运行该 build):`732948803` bytes,
  SHA-256 `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`
  (CHG-2026-003 archived evidence);
- hdc 工具:维护者本机 DevEco/SDK 内 hdc,采集时记录 absolute path + SHA-256 +
  `-v` 版本(I5-001 先例:3.2.0d,SHA-256 `48395ba8…d8260`,以实测为准);
- transport:USB(TCP 推迟,理由见 proposal Out of scope)。

## Read-only command allowlist(封闭;白名单外不得执行)

| 命令 | 用途 | 设备状态影响 |
| --- | --- | --- |
| `hdc -v` / `hdc version` | client 版本 | 无(隐式拉起 host server,记录 ownership) |
| `hdc checkserver` | server/daemon 版本 | 无 |
| `hdc list targets` / `hdc list targets -v` | 发现与 identity | 无 |
| `hdc shell hidumper --help` 及 runbook 固定的只读 hidumper 查询 | UI Dump 包装事实 | 无(只读诊断) |

- 唯一允许的设备端状态变化:首次连接时的授权信任确认,由人类在设备屏幕完成,
  设备端可撤销;runbook 记录确认前后的 `list targets` 状态迁移。
- 明确禁止:`install`/`uninstall`、`file send`/`file recv`、`target boot`/
  `reboot`、`tmode`/`tconn`、`kill`/`start`/`kill -r`/`start -r`、`killall-sub`、
  任何 flashd/fastboot/厂商工具调用。
- Host 侧:采集会隐式拉起 hdc host server(M0A 结论),runbook 记录该 server 为
  external ownership 并在采集结束后保持不杀(与 M1-006 external/unknown 零
  lifecycle 契约一致)。

## Capture protocol(沿用 I5-001 受控采集先例)

- 分 stream 原始字节采集(stdout/stderr 分离)、记录精确 argv、exit code、时间、
  macOS build、hdc path/hash/version;
- 每个 capture 文件计算 SHA-256 并登记于 run.md;含设备序列号/网络地址的字节
  存放仓库外受控位置(维护者控制),仓库内只记 hash 与脱敏摘要;
- 敏感自检:capture 不得含用户路径、密钥;序列号仅出现在受控位置与
  hardware-evidence 记录的 device identity 字段(该记录本身经维护者 PR review);
- 不得为"凑 golden"而改写字节;golden 登记与脱敏政策留给后续 integration
  change 决策。

## Evidence pipeline

1. 人类按 runbook 执行,产出 capture + 填写观察记录;
2. Agent 复核完整性(字段齐全、hash 一致、白名单合规),起草
   `evidence/runs/TASK-M0B-00x/run.md` 与符合
   `contracts/hardware-evidence.schema.json`(2.0.0,required:schemaVersion、
   evidenceId、operator、physicalTargetConfirmation、device、toolchain、
   transport、provider、stepKinds、acceptanceIds、executedAt、artifacts)的
   evidence JSON;provider 字段如实记录 `none`(M0B 无 Provider);
3. hardware-matrix 行以 `observed` 起草,随 evidence 同 PR 由维护者 review/merge
   生效;`validUntil`/revalidation trigger 按固件与 hdc 版本记录。

## TASK-M0B-002 supervisor observation(依赖 TASK-M1-006 done)

M1-006 合入后,以 ArkDeck 生产 `HDCServerSupervisor`(fake-hdc 契约已验)在真机
在场时做只读观察:external server ownership 判定、自动 lifecycle/subserver 调用
计数恒 0(仪表化实测)、endpoint 隔离(`OHOS_HDC_SERVER_PORT` 只进子进程 env)、
设备出现/消失的 fan-out。App 由人类启动;观察不引入白名单外命令,不做设备
mutation。若 M1-006 交付形态与本设计冲突,须先修订本 change 再执行。

## Non-goals

见 proposal Out of scope;另注:本 change 不定义新的持久 schema、不修改
`hardware-evidence.schema.json`、不建立 Trace/Debug/Flash capability 事实。

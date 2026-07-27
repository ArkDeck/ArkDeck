# TASK-DEC-008 D2 重装窗口 receipt

- Task:TASK-DEC-008(minter 部署副本重装)
- Authorization:readiness **r2**(#650,merge `1d1fb1e`,lvye APPROVED/
  mergedBy lvye)。source PR = #649(merge
  `15dcbb2089bc0d93ee7828df99f6349e73491fd0`)。
- **Operator:维护者(lvye)亲手执行全部命令**。Agent 对系统面**零写入**:
  本文件的核验全部来自维护者贴回的 transcript,加上 Agent 事后以**只读**
  命令(`launchctl print`、`stat`、`tail`)采集的复核。
- 窗口时间:2026-07-27,步骤 1–7 于本地 **19:4x–20:11** 之间完成
  (强制铸造 `minted_at_epoch=1785152586` = `2026-07-27T11:43:06Z`)。
- Hardware:none(维护者本机 root 窗口,非设备硬件)。

## 双 digest(窗口的两端)

| | sha256 | 实测 |
| --- | --- | --- |
| 窗口前 = 回滚目标 | `5b8cbc06e7246c83c273f37dd78b07c2eca1e91b541cc88532c9f3c6f5cd9671` | 步骤 2 命中 |
| 窗口后 = main `15dcbb2089…` 的字节 | `2df746cc58cf6dcf825a01f072cea4bdfffa61b706f40695c8e0531b3f2d6103` | 步骤 4 命中 |

准备步骤独立复核:`git show 15dcbb2089…:scripts/host_loop/
mint_installation_token.sh | shasum -a 256` 输出即上表「窗口后」值,
故**装上去的字节 == protected main 精确 OID 上的字节**,这正是该脚本
自身 docstring 描述的那条间接性。

## r2 七条二值条件逐条判定

| # | 条件 | 实测 | 判定 |
| --- | --- | --- | --- |
| 1 | PEM 判据(硬门) | `pem owner=root mode=600` | **PASS** |
| 2 | 安装后三项 | digest `2df746cc…`;`owner=root group=wheel`;`mode=555` | **PASS** |
| 3 | 拒绝路径干跑 | `exit=2`;stderr `mint_installation_token: private key not found at the given path` | **PASS(附注见下)** |
| 4 | 真实强制铸造 | `exit=0`;token `fuhanfeng 600`;**sidecar `root 600`**;`.mint.` 残留 **0**;sidecar 前三行 `app_id=`/`installation_id=`/`minted_at_epoch=` | **PASS** |
| 5 | 下一次自然触发 | `runs` **66 → 67**;`last exit code = 0` | **PASS** |
| 6 | 零 plist 改动 / 零 bootout·bootstrap | transcript 全程无此类命令;安装走「暂存 + 同文件系统 `mv`」 | **PASS** |
| 7 | evidence 脱敏收录 | 即本文件 | **PASS** |

**七条全部成立。**

### 第 3 条的附注(如实标注取证边界)

r2 第 3 条含「token 未改动」一半。**窗口 transcript 未对此独立取证**:
步骤 5 之后没有单独 `stat` token,而步骤 6 的铸造会覆盖该证据。该性质由
两条**窗口之外**的依据支撑,本 receipt 不把它记为「窗口已验证」:

1. **结构**:脚本在 `[ -f "$PEM" ]` 处即 `die … 2`,尚未走到 `OUT_DIR`
   校验与任何暂存写入;
2. **测试**:`test_nothing_is_written_by_a_refused_invocation`(CI 绿)以
   预置 token 文件断言拒绝路径零写入、零 `.mint.` 残留。

## 窗口最有价值的一格:D-M5 的线上生效证据

sidecar 权限在窗口中**真实翻转**:

| 时点 | `installation-token.meta` |
| --- | --- |
| 步骤 2(窗口前) | `owner=fuhanfeng mode=644` |
| 步骤 6 之后 | **`owner=root mode=600`** |

这是 D-M5 唯一无法靠静态断言证明的那半:**非特权账户不再能改写 root 的
重铸判据**。第 5 条进一步证明**收紧没有把 root 自己挡在门外**——下一次
launchd 派生的运行读到 root 600 的 sidecar 后正常判定
`fresh: 1949 seconds of validity remain; not re-minting`。

## D-M4 的线上旁证

步骤 6 之后 `.mint.` 残留计数为 **0**。该次为成功路径,故它证明的是
「成功路径不留暂存物」;**失败路径的零残留由 CI 的注入式 harness
(`MinterCleansUpEveryStagingPath`,macOS 侧真跑 `chmod`/`chown`/`mv`
三种注入)证明**,窗口不重复该实验(重复需要人为制造 root 面失败)。
两者合起来覆盖 D-M4 的两侧。

## Agent 事后只读复核(20:11:47 本地)

```
runs = 67
last exit code = 0
state = not running
log tail: fresh: 1949 seconds of validity remain; not re-minting
installation-token       owner=fuhanfeng mode=600
installation-token.meta  owner=root      mode=600
.mint. residue count: 0
```

## 脱敏声明

本文件与其引用的 transcript **不含**:token 明文、任何 `ghs_*` 串、PEM
内容或其任何字节。收录的是 digest、属主/权限、退出码、计数与日志中不含
密钥的行。`app_id` / `installation_id` 已存在于仓内 r2 正文与部署 plist,
本文件未引入新暴露。

## 未发生的事(如实记录)

- 未改动 `com.arkdeck.host-loop.refresh.plist`,未 bootout/bootstrap,
  未 `kickstart`——第 5 条来自**自然到点**的触发。
- 未回滚。备份 `com.arkdeck.host-loop.mint.sh.5b8cbc06.bak` 仍在原处;
  等价回滚源 = blob `4150401c5f875ac282d38d6f70eb4c0c35f97689`。
- 未触碰 token 路径、App/installation id 或铸造语义。

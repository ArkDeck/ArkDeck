# selectedDeviceAuthorizationBinding — device-window capture record

- Family:`selectedDeviceAuthorizationBinding`(capture-plan.md 矩阵第 2 行,唯一
  device-window family)
- Evidence class:`controlledHumanCapture`(harness 流)+ maintainer host observation
  (`OB-*` 记录)
- Captured:2026-07-20,维护者 lvye(fuhanfeng)亲手执行两次(run 1 = 15:09,run 2 =
  15:12,clean-window 重采);设备 = 桌面物理确认的 DAYU200(与 hardware evidence
  记录一致),经 USB 连接;本窗口内除本 family 外零设备操作(run 1 的偏差见
  Deviations)。Agent 零 hdc/OB 执行,仅事前起草脚本、事后核验/脱敏/起草本记录。
  **Provenance 认可 = 维护者 review/merge 本 evidence PR**(capture-plan.md 认可载体)。
- Host:macOS 26.5.2(25F84),arm64。
- Raw 位置:操作者受控目录(仓库外,目录 0700/文件 0600;本记录以
  `<capture-session>` 指代;两次 run 的 session transcript 一并保留)。

## Instruments(计划固定,零新工具)

- `scripts/m0b_capture/capture.py` **AS-IS**,SHA-256
  `be66c30e7db6839196f095724d9ee75a59d938a7e1e4ffa1f139e8f3df3760f8`(与
  host-only-capture-2026-07-20.md 同一 instrument 身份);仪器常量披露同该记录
  (manifest 携带 M0B change/task/transport 字段,系 AS-IS 常量非归属声明)。
- 单次 harness 调用按计划顺序执行两个 id:`hdc-list-targets` →
  `hdc-list-targets-verbose`(`--commands` 保序;M0B 单调用多命令先例)。
- `OB-1`(ps)/`OB-2`(lsof)人工 host 观察,bracket 闭合。

## Pinned tuple 复核(session 门)

- hdc 二进制 SHA-256 实测 =
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`,与 pinned
  M0B tuple 逐字命中(两次 run 各自复核,漂移即停条件未触发)。版本串交叉印证:
  同日同一二进制在 host-only session 的 `checkserver` 输出 client/server 双
  `Ver: 3.2.0d`。

## Family observation(run 2 = clean-window 主证据)

- Bracket 事前/事后(`OB-1`/`OB-2`):恰一个 server 候选——PID `48339`(自
  2026-07-18 15:36:12 存活,argv `hdc -m -s ::ffff:127.0.0.1:8710`),LISTEN
  `127.0.0.1:8710`,无其他连接;事前/事后**字节相同**(同 SHA-256),**零
  generation 事件**。run 2 的 `OB-1`/`OB-2` 文件与同日 host-only session 的对应
  文件逐字节相同(同样干净的进程面)。
- harness:2 commands,exit `0`,`selfCheckPassed: true`,0 timed out,stderr 均
  0 bytes;manifest 中 `serialPresent: null`(未提供 `--target`,三态记录惯例),
  argv 不含任何 serial。
- **授权绑定观察(family 候选输出证据,raw 留仓库外)**:
  - plain `list targets`:33 bytes,SHA-256
    `2035c0783fe1b2fbc3bba6badfb76003c1a5d46bbe16d1479de439e9fd874fc2`——仅
    32 字符 connectkey + LF,无状态列;
  - verbose `list targets -v`:58 bytes,SHA-256
    `d8816e413776d80e6e577b78f6abbf8c114bfd570b3627f7a007c97681af9c48`——
    `<key>\t\tUSB\tConnected\tlocalhost\n` 形态(结构见 CHG-008 r7 与 M0B 记录)。
- **跨 session 字节级稳定(本记录核心事实)**:两条流的 SHA-256 与 merged M0B
  evidence(2026-07-18,EVD-M0B-DAYU200-20260718-001 采集表)以及本日 run 1 全部
  逐字节相同——跨两日、跨 server 代际零漂移;设备在无任何信任 UI 交互下持续报告
  `Connected`(与 M0B AUTH-001 r2 分支 B 一致)。connectkey 跨日稳定(字节相同即
  蕴含,serial 本身不入仓库)。
- 确定性:run 1/run 2 的 full manifest **字节相同**(`c4d6fbb7…`)、redacted
  manifest 字节相同(`80b3c9d6…`,与 full 唯一差异 = schema id,零掩码需求)。
- 注册含义(登记候选输入,不在本记录裁决):verbose 行是该 family 的 probe 输出
  形态锚点;plain 形态无状态列的事实与 CHG-008 r7 修正互为印证;probe 注册须以
  verbose 形态为状态观察面。

## Deviations(如实)

- D1(run 1 窗口纯度):run 1 bracket 期间存在并行交互式 `hdc shell` client
  (PID `95490`,15:09:21 启动,早于脚本 11 秒,全程存活;`OB-2` 记录其对 server 的
  `127.0.0.1:51162` ESTABLISHED 连接)——违反本 family 的独立窗口规则。该 client
  为操作者侧进程,已在 run 2 前关闭;其来源未逐项记录。处置:run 2 以 clean window
  重采为主证据;run 1 全部字节保留为带偏差证据。交叉印证:run 1 与 run 2 的两条流、
  full manifest 均逐字节相同——并行 client 未改变观察结果,但窗口纯度裁决权在
  维护者 review(merge 本 PR 即接受该处置)。
- 无其他偏差;两次 run 的 stop condition 均未触发。

## Hash manifest(raw 均在仓库外;redacted manifest 副本已入本目录)

| Artifact | SHA-256 |
| --- | --- |
| run1/run2 `manifest.json`(字节相同) | `c4d6fbb7630daea833b91c1992a89d5d9c8a7c81dedae01780fcf5e37da67385` |
| run1/run2 `redacted-manifest.json`(字节相同;副本=`harness-list-targets.redacted-manifest.json`) | `80b3c9d62f7aa5262bc647c7097067e0428d0f1c4975851480285b6c6365d417` |
| run1/run2 `00-hdc-list-targets.stdout`(33 B,字节相同,= M0B) | `2035c0783fe1b2fbc3bba6badfb76003c1a5d46bbe16d1479de439e9fd874fc2` |
| run1/run2 `01-hdc-list-targets-verbose.stdout`(58 B,字节相同,= M0B) | `d8816e413776d80e6e577b78f6abbf8c114bfd570b3627f7a007c97681af9c48` |
| 两个 `.stderr`(均 0 B) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| run 1 `OB-1-pre.txt`/`OB-1-post.txt`(字节相同,含并行 shell 行) | `231fa9620b656a062b0c26d2cb9f5a8047fb4f681c9f3e1b48adda0eb58605a4` |
| run 1 `OB-2-pre.txt`/`OB-2-post.txt`(字节相同,含 ESTABLISHED 行) | `bf04bf6ff3df9384b759d3e07e8e71b976465b47440165e39f3f1781d64cfbff` |
| run 2 `OB-1-pre.txt`/`OB-1-post.txt`(字节相同,= host-only session OB-1) | `99975e21f6965b26a6c104dca1d30c47e2f7479541c36199223d00e609e2147a` |
| run 2 `OB-2-pre.txt`/`OB-2-post.txt`(字节相同,= host-only session OB-2) | `87ada8f8dcd8de2f381150d3ca2362f864cc9c5407725a40b298b16cfa4bbf67` |
| run 1 `env.txt` / run 2 `env.txt` | `bb1ee5173fbcdc396f80eef820cc4658cd6f29640c519bdb87ac0ff88e92d3ac` / `3fb06a1bf4f807beffd18a6faee240833038a85c4da063b28d5edc482de005ba` |
| run 1 / run 2 session transcript | `949e61129249d9ec5b81caf222029fed0466d2ebb5f55cd37c2586ceb7d0b30f` / `8585917e06a9065c13bfc4ce9f1dab73d0265d7c6daf088bdb46647222d37829` |

## Boundary

设备命令面 = 计划固定的两个 list-targets id,零其他设备命令、零 server lifecycle/
subserver 命令、零 network dispatch;serial 字节只存在于仓库外 raw 流(本记录与
manifest 副本均不含);不构成 compatibility/conformance/support/release claim,不改变
`TASK-I15-001` `blocked` 状态;仅提供其注册评审所需的 authoritative input。四类
family 进度:随本记录,**4/4 全部满足**(subserverCapability #141、
serverIdentityGeneration + keyAccessDiagnostics #155、本 family 本 PR)——
`TASK-I15-001` 的剩余前置仅为独立 readiness PR。

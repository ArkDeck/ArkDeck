# serverIdentityGeneration + keyAccessDiagnostics — host-only capture record

- Families:`serverIdentityGeneration`、`keyAccessDiagnostics`(capture-plan.md 矩阵
  第 1/3 行,均为 host-only 窗口;本 session 零设备、零 network dispatch)
- Evidence class:`controlledHumanCapture`(harness 流)+ maintainer host observation
  (`OB-*` 记录)
- Captured:2026-07-20 14:51–14:57 CST,维护者 lvye(fuhanfeng)亲手执行——计划
  规定 Agent 不代跑任何 hdc/OB 观察;Agent 仅事前起草命令清单、事后核验/脱敏/起草
  本记录(M0B PR #58 先例)。**Provenance 认可 = 维护者 review/merge 本 evidence PR**
  (capture-plan.md 认可载体)。
- Host:macOS 26.5.2(25F84),arm64。
- Raw 位置:操作者受控目录(仓库外,目录 0700/文件 0600;本记录以
  `<capture-session>` 指代;含全程 session transcript)。

## Instruments(计划固定,零新工具)

- `scripts/m0b_capture/capture.py` **AS-IS**,SHA-256
  `be66c30e7db6839196f095724d9ee75a59d938a7e1e4ffa1f139e8f3df3760f8`,执行时
  `main` OID `6b9dfe4`。仪器常量披露:该 harness 的 manifest 固定携带
  `change: CHG-2026-006-dayu200-m0b-bringup`、`task: TASK-M0B-001`、
  `transport: "usb"` 字段——均为 AS-IS 仪器自带常量,不构成本次采集对 M0B
  change/task 的归属声明或 transport 事实(本次零设备)。
- `OB-1`(ps)/`OB-2`(lsof)/`OB-3`(shasum+stat)/`OB-4`(stat/ls/env,零 hdc)人工
  host 观察,输出逐文件落盘并 hash。

## Family 1:serverIdentityGeneration

### Pinned tuple 复核(session 门,先行)

- hdc 二进制 SHA-256 实测 =
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`,与 pinned
  M0B tuple 逐字命中(漂移即停条件未触发)。
- `checkserver` stdout(55 bytes,全部 printable ASCII + 结尾 LF):

  ```text
  Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d
  ```

  client 与 server **双双命中 pinned `Ver: 3.2.0d`**。

### Bracketed observation(run 2 = 完整 bracket)

- 事前(`OB-1-pre2`/`OB-2-pre2`):恰一个 server 候选——PID `48339`,自
  2026-07-18 15:36:12 存活,argv `hdc -m -s ::ffff:127.0.0.1:8710`;lsof 显示该
  pid LISTEN `127.0.0.1:8710`(IPv6 socket 的 v4-mapped loopback,与 merged M0A
  evidence 文档形态一致)。
- harness `hdc-checkserver`:exit `0`,`selfCheckPassed: true`,`timedOut: false`,
  stderr 0 bytes。
- 事后(`OB-1-post2`/`OB-2-post2`):与事前**字节相同**(同 SHA-256)——同 pid、
  同 start time、同 endpoint,**零 generation 事件**。
- 确定性:run 1 与 run 2 的 stdout 字节相同(`50e8dfe0…`)、full manifest 字节相同
  (`93c569d7…`)、redacted manifest 字节相同(`8d6d6317…`,唯一 full/redacted 差异
  = schema id,本次采集无需任何掩码)。
- 观察边界(如实):server 自 2026-07-18 既存,本 session **未观察到**"无 server 时
  `checkserver` 隐式拉起"的 Decision-3 变体;录得的是"pinned 3.2.0d 下 `checkserver`
  面对既有同版本 server 不重启/不重绑"变体。两种变体计划均接受为诚实记录。
- 分类澄清:`OB-1` 各文件中的 1Password Browser Helper 行为 grep 假阳性
  (chrome-extension id `aeblfdkhhhdc…` 含 "hdc" 子串),分类为非候选进程;server
  候选恰一。

## Family 2:keyAccessDiagnostics(`OB-4` only,零 hdc 命令)

- `~/.harmony`:**不存在**(ENOENT 记录在案)。
- `~/.ohos/config/`:存在,内容为 DevEco **应用签名材料**——fixture 工程的
  cer/csr/p12/p7b 各一(私密文件权限 `0600`)与 `material/` 缓存目录(`0700`),
  **非 hdc 设备认证 key material**。硬规则保持:私密材料零读取/零 hash/零指纹;
  本机不存在可指纹的 hdc 公钥文件。文件名中的工程签名别名后缀在本记录省略
  (raw 列表仅存仓库外)。
- 环境变量:无 `HDC_*` 或 key-path 相关变量;仅 `PATH` 含 DevEco toolchains 目录
  (用户路径段在本记录脱敏为 `<operator-home>`)。
- **Family 结论(登记候选输入,不在本记录裁决):host 侧 hdc key material 缺席。**
  与 M0B 一手实测 AUTH-001 分支 B(该设备 build USB 连接不弹信任 UI)互洽。对
  TASK-I15-001 的含义:`keyAccessDiagnostics` probe 的注册形态必须把"缺席"作为
  一等状态;本记录是否充分由注册评审判断。

## Deviations(如实)

- D1:run 1(首次 harness 采集)bracket 不完整——`OB-2` 事前未采、事后 bracket 未
  闭合(操作者粘贴缓冲 parse error 中止后续命令)。run 2 以完整 bracket 重采;
  run 1 的 harness 输出全部保留,且与 run 2 逐字节相同(见确定性一节)。
- D2:`OB-4` 首次执行因 cwd 错误未落盘(仅屏显),以绝对路径重跑落盘;两次屏显
  内容形态一致。

## Hash manifest(raw 均在仓库外;redacted manifest 副本已入本目录)

| Artifact | SHA-256 |
| --- | --- |
| `capture.py`(instrument,in-repo) | `be66c30e7db6839196f095724d9ee75a59d938a7e1e4ffa1f139e8f3df3760f8` |
| run1/run2 `manifest.json`(字节相同) | `93c569d74f5eb3540d45bedd8253e1bbbfb192f1bcf17efa8629ee7ec9d97570` |
| run1/run2 `redacted-manifest.json`(字节相同;副本=`harness-checkserver.redacted-manifest.json`) | `8d6d63177f59d784ccd071fd054a27873db8a8779481ac83a3110a5cda4787b4` |
| run1/run2 `00-hdc-checkserver.stdout`(字节相同,55 B) | `50e8dfe03cb770dfade5b91198523b964fd3bd6fd8855b541ceb46201f0d014a` |
| `00-hdc-checkserver.stderr`(0 B) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `OB-1-pre.txt`/`OB-1-pre2.txt`/`OB-1-post2.txt`(字节相同) | `99975e21f6965b26a6c104dca1d30c47e2f7479541c36199223d00e609e2147a` |
| `OB-2-pre2.txt`/`OB-2-post2.txt`(字节相同) | `87ada8f8dcd8de2f381150d3ca2362f864cc9c5407725a40b298b16cfa4bbf67` |
| `OB-3-shasum.txt` | `0cea5b1922bcc913f221d952ae958cabdc27ba3e2769d6c3c61eefda568f942a` |
| `OB-3-stat.txt` | `00105863861c0ab5deff88e249a95a78f72af1527bcf29a2e2f7a6eb1c654e26` |
| `OB-4-locate-harmony.txt` | `9abd54ecad869cbae69462b2d5cd3fd1336a19cf6e7f8e96b37fa2b670cc6267` |
| `OB-4-locate-ohos.txt` | `df1dabc9bd167e7f545b386b152d6080946bda0a82203c5292e8a15e6c3910de` |
| `OB-4-stat.txt` | `86b33f6d39869b647fb2e24a7633e20d44ec662ece1ec3bc9c7f39cb8e5f54f6` |
| `OB-4-env.txt` | `d0a8fadc7825863b2f890782b780acf6c9ceba7c02d13173d40ce1d22a1858fc` |
| `env.txt` | `edb89331b58d16d9fd8308ff8dfabe7d1bbdec162d4ed25482d2b127daa26284` |
| `session-transcript.txt` | `68299fc040816c94deb9668d1d1c8a3f723ba4d6817a005eca045064787f6770` |

## Boundary

零 device/network dispatch;唯一 hdc 命令 = harness 封闭白名单内的 `checkserver`;
不构成 compatibility/conformance/support/release claim,不改变 `TASK-I15-001`
`blocked` 状态;仅提供其注册评审所需的 authoritative input。四类 family 进度:随
`subserverCapability`(PR #141)与本记录,3/4 已满足;`selectedDeviceAuthorizationBinding`
仍待独立设备窗口(不得与 UD Phase A 同窗口)。

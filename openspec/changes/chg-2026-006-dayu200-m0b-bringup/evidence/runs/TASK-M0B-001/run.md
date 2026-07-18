# TASK-M0B-001 run — DAYU200 真机发现/授权观察/工具链/受控采集

- Change:CHG-2026-006-dayu200-m0b-bringup / Task:TASK-M0B-001
- Evidence ID:`EVD-M0B-DAYU200-20260718-001`(`hardware-evidence.json`,schema 2.0.0,provider `none`)
- Operator(人类,亲自执行全部 hdc 命令):fuhanfeng;Agent 仅起草 runbook/脚本与本记录,未执行任何真实 `hdc`
- 执行日期:2026-07-18(UTC 时间线见下);物理目标确认:operator 确认"当前连接的就是 DAYU200(RK3568)开发板"(书面确认记录于 2026-07-18T07:52:26Z,见 Deviations D3)
- Host:macOS 26.5.2(build 25F84,Darwin 26.5.2),arm64
- Toolchain:hdc `Ver: 3.2.0d`(client 与 server 一致,`checkserver` 实测);binary `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`,SHA-256 `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`(与 I5-001 provenance 同一枚);transport USB
- Device(operator 于设备"关于"页实际观察):DAYU200(RK3568),OpenHarmony `7.0.0.34`,API `26.0.0`;serial 仅记录于 `hardware-evidence.json` 的 device identity 字段与受控位置(design.md capture protocol 许可的唯一入仓位置)
- 采集工具:`scripts/m0b_capture/capture.py`(main `4960c10` 合入形态;封闭只读白名单、argv 数组无 shell、逐流 SHA-256、敏感自检、redacted manifest 输出侧终检门)

## 执行时间线与命令合规(白名单自证)

四个采集目录,共 11 次命令执行,全部命中封闭白名单、全部 `exit=0`、无 timeout、无截断、
`selfCheckPassed` 全 true。argv 中 connectkey 已按 redacted manifest 形态掩码;逐流完整
SHA-256 见 `capture-hashes.md` 与 `redacted-manifests/*.json`(两处一致)。

| run(UTC) | commandId | argv(hdc 之后) | exit | stdout |
| --- | --- | --- | --- | --- |
| pre-auth(07:39:59) | hdc-version-flag | `-v` | 0 | 12B `906d35a917937ecb…` |
| pre-auth | hdc-version-word | `version` | 0 | 12B `906d35a917937ecb…` |
| pre-auth | hdc-checkserver | `checkserver` | 0 | 55B `50e8dfe03cb770df…` |
| pre-auth | hdc-list-targets | `list targets` | 0 | 33B `2035c0783fe1b2fb…` |
| pre-auth | hdc-list-targets-verbose | `list targets -v` | 0 | 58B `d8816e413776d80e…` |
| negative(07:44:01) | hdc-list-targets | `list targets` | 0 | 33B `2035c0783fe1b2fb…` |
| negative | hdc-list-targets-verbose | `list targets -v` | 0 | 58B `d8816e413776d80e…` |
| post-auth(07:44:20) | hdc-list-targets | `list targets` | 0 | 33B `2035c0783fe1b2fb…` |
| post-auth | hdc-list-targets-verbose | `list targets -v` | 0 | 58B `d8816e413776d80e…` |
| hidumper(07:46:09) | hidumper-help | `-t <connectkey> shell hidumper --help` | 0 | 34B `a4904901becfb1a1…` |
| hidumper | hidumper-services | `-t <connectkey> shell hidumper -ls` | 0 | 3121B `351fc59ea33de263…` |

白名单外命令执行数:0;flash/写设备/网络外联:0;server kill/restart:0(hdc host
server 由首条命令隐式拉起后保持外部所有权)。所有 stderr 均为 0 字节(hash
`e3b0c44298fc1c14…` = 空串 SHA-256)。

## 二值结论(per acceptance-cases.yaml)

### TEST-HW-M0B-DAYU200-DISCOVERY-001 — PASS

- 物理 DAYU200 经 `hdc list targets` / `list targets -v` 发现:单设备,verbose 状态
  USB / Connected;稳定 device identity(32 字符 connectkey)三次采集逐字节一致,
  已记录于 hardware-evidence 记录 device identity 字段。
- hdc client `Ver: 3.2.0d`(`-v` 与 `version` 两种拼写输出逐字节一致),
  server `Ver: 3.2.0d`(`checkserver` 实测,client/server 同版本);tool path/hash 已钉。
- 设备 OpenHarmony build 为 operator 于设备屏幕实际观察(7.0.0.34 / API 26.0.0),
  非镜像文件名推断。
- 全部命令在封闭只读白名单内,argv/exit code 逐条登记(上表);evidence 记录经
  schema 2.0.0 校验,provider `none`,仅支持 `observed` 矩阵行。

### TEST-HW-M0B-DAYU200-AUTH-001 — FAIL(as written;观察事实如实记录)

AC 原文要求"on-device trust 前观察到 unauthorized 态,人工确认信任后目标转为
ready,转变体现在 `list targets` 状态中"。实际观察与该前提不符:

- pre-auth、negative(USB 重插新鲜枚举后)、post-auth 三次 `list targets` /
  `list targets -v` 输出**逐字节相同**(stdout SHA-256 一致,见上表),全程
  USB / Connected;unauthorized 态从未出现。
- operator 现场观察:**该 DAYU200 build 在 USB 连接时不弹出任何信任确认 UI**
  (operator 同时报告手机形态设备会弹);重插亦不触发。信任推测为 I5-001 采集
  窗口(2026-07-18 更早时段,同一 Mac + 同一 hdc)已持久化,且设备端无可交互的
  授权界面可供重置观察。
- denied/timeout 负路径:按 AC 的如实记录条款处理——不可重现,原因即上条
  (无信任 UI、无未授权态可进入);negative 目录采集为重插后即时状态,输出与
  authorized 态相同。
- 满足的子条款:负路径不可重现性已如实记录;无 server kill/restart;无 key
  material 复制/上传/入仓。
- 结论:按 AC 字面判 **FAIL**。观察到的设备族事实(该 build 无授权确认 UI、
  USB 枚举直接 Connected)本身是有价值的 M0B 产出,已完整记录;AC 前提与该
  硬件行为的不匹配留给后续 change 修订(见 Residual risks R2)。

### TEST-HW-M0B-DAYU200-RAWCAPTURE-001 — PASS

- 设备族原始输出(`list targets` 两形态、设备在场的 `checkserver`)分 stream
  逐字节采集,精确 argv、exit code、per-stream SHA-256 全部登记(上表 +
  `capture-hashes.md` 20 个文件全量 hash)。
- 序列号字节仅存维护者受控位置 `~/m0b-capture/2026-07-18/`(仓库外),仓库内
  以 hash 与 redacted manifest 引用;本 change 未编辑任何 capture 字节、未登记
  任何 golden fixture。
- Agent 复核:受控位置逐文件重算 SHA-256 与 manifest 记录一致(4 目录全部
  integrity OK);evidence 目录经序列号缺席扫描(逐文件断言 serial 子串不出现)。

### TEST-HW-M0B-DAYU200-UIDUMP-PROBE-001 — PASS

runbook 固定的两条只读 hidumper 查询已带 argv/exit/streams 采集,供后续
integration change 修 HiDumper call wrapper(ui-dump spec);本 change 不修
wrapper、不做兼容性声明。观察到的 wrapper 关键事实:

- `hidumper --help`(经 `hdc -t <connectkey> shell`)输出为单行
  `hidumper: option pid missed. help`(34B)且 **exit code 为 0**——该 build 的
  hidumper 不将 `--help` 识别为 usage 请求,且错误路径不反映在退出码上。
  推论(供 wrapper 设计,非本 change 结论):不能以 `--help` 做特性探测,不能以
  exit code 判 hidumper 成败(与 M0A hdc 无 `[success]` 标记同族)。
- `hidumper -ls` 正常:`System ability list:` + 多列服务名(3121B / 32 行),
  含 `RenderService`、`WindowManagerService`、`AbilityManagerService`、
  `UiService`、`UiAppearanceService`、`AccessibilityManagerService`、
  `DisplayManagerService`、`MultimodalInput` 等 ui 相关 ability。

## Deviations

- D1:AUTH-001 判 FAIL(as written)——未授权前态在本硬件/本窗口不可观察,详见
  上文;这是 AC 前提与设备实际行为的不匹配,非执行偏差。
- D2:hardware-matrix 编辑除新增 `observed` 行外,同 PR 移除了"首批设备待确认 /
  notStarted"占位行并更新头部 status 注(占位内容与新增行并存会自相矛盾);
  tasks.md Allowed paths 字面为"仅新增 observed 行",此处超出部分明示留维护者
  review 裁决。
- D3:物理目标确认的书面记录时间(07:52:26Z)晚于首次采集(07:39:59Z);operator
  全程物理在场操作设备(插拔 USB、读取设备"关于"页),书面确认为事后补记于同一
  会话,schema 字段按书面确认时间如实填写。
- D4:pre-auth 目录按 runbook 步骤 2 命名,但实际采集时设备已处于 authorized 态
  (见 AUTH-001);目录名保留原样,语义以本记录为准。

## Residual risks / 遗留

- R1:单一组合事实——仅覆盖 OpenHarmony 7.0.0.34 / API 26.0.0 / hdc 3.2.0d /
  macOS 26.5.2 / USB;不得外推到相近版本(matrix 规则)。revalidation trigger:
  设备固件或 hdc 版本任一变化。
- R2:AUTH-001 的 AC 前提(存在可观察 unauthorized 态)与该 DAYU200 build 行为
  不符;修订 AC 或补充"无授权 UI 设备族"分支须走独立 change,本 evidence 不
  预支结论。
- R3:hidumper exit code 不可靠(--help 错误路径 exit 0)是 wrapper 集成的已知
  风险输入,遗留给 ui-dump integration change。
- R4:GAP-DAYU200-RECOVERY-PATH 等四 gap 保持 unknown,DEC-002 保持 open;本
  run 零写设备,未触碰恢复路径。

## Addendum — r2 重评(2026-07-18,CHG-2026-006 r2 生效后)

CHG-2026-006 r2(PR #60,main `b77690b`)将 `HW-M0B-DAYU200-AUTH-001` 修订为
双分支。按 verification.md r2 注记要求,本节为独立重评步骤(维护者 review/merge
本 addendum PR 即构成裁决),**仅引用本记录已合入的采集事实,零新增 `hdc` 执行**:

| r2 分支 B 条款 | 已合入事实(出处) |
| --- | --- |
| operator 明确记录新鲜枚举(重插)前后均无信任提示 | operator 现场观察"该 build 不弹信任 UI(手机才弹)";negative 目录为 USB 重插后即时采集(本记录 AUTH-001 节) |
| `list targets` 字节可比对地呈现稳定 authorized 态 | pre-auth/negative/post-auth 三次采集 stdout SHA-256 逐字节相同(`2035c078…`/`d8816e41…`),verbose 全程 USB/Connected(命令合规表) |
| 负路径记录为不可复现并给出原因 | 无信任 UI、无未授权态可进入(AUTH-001 节;D1) |
| 零 server kill;key 材料不复制/不入仓库 | 命令合规表(0 kill/restart);self-check 全 true;capture-hashes.md |

- 结论:`TEST-HW-M0B-DAYU200-AUTH-001` 按 **r2 分支 B 判 PASS**。
- 原 r1 结论不改写:上文"FAIL(as written)"按 r1 保持有效(verification.md r2
  注记的非追溯条款);本节是新增的独立评定,非对 r1 记录的修改。
- 本 addendum 未执行任何设备命令,无新增 capture;matrix 行 AC coverage 随本
  addendum 同 PR 更新。

## Boundary

read-only capture;observed-only;不构成支持/兼容性声明;不解除任何
`GAP-DAYU200-*`;不推进任何 matrix 行超过 `observed`;manifest 标
`controlledHumanCapture`,realHardware 分类由本 evidence 记录(operator 人工
attested + 维护者 PR review)承载;序列号字节保持在受控位置,仓库内仅
hash/redacted manifest 与 hardware-evidence device identity 字段。

# ArkDeck 设计稿 brief(九页)

每份对应规格 `docs/design/macos-ux-interaction-spec.md` §5.x 的一个功能页。
用法:在 claude.ai/design 的 ArkDeck 项目里**开新对话,一次贴一份**。不要一次让它画完整个 app。

三点使用须知:

1. **设计 agent 看不到这个仓库。** 它自动拿到的只有组件 bundle、每个组件的 `.prompt.md` / `.d.ts`,以及 README 里的约定头(token 词表、危险语义规则)。它不知道 §5 的页面定义,也没读过 `prototype.html`——所以 brief 必须自带事实。这也是每份 brief 里「内容」段要逐字照抄的原因。
2. **「必须画出的语义」段是重点。** ArkDeck 的设计价值几乎全在非顺利路径上;不点名,agent 只会画顺利路径,那样的稿子没有评审价值。
3. **画出来的是候选稿,不是规格的替代。** 规格 §5 是 normative 的 HOW;两者不一致时以规格为准,发现行为级缺口要走 behavior delta,不能只改稿子。

写这九份时对照发现的规格↔原型不一致,以及规格要求但原型无内容的地方,都已就地标注在对应 brief 里。

---

## 5.1 Overview

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Overview** 页。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏的设备行由 `device.candidates` 动态产生；`NavItem` × 7（Overview · Flash · Debug · UI Dump · Trace · History · Automation，Overview 为当前页），不画 Settings 导航项。
内容区自上而下:`StatusStrip` 四格 → 两列 `Card` 网格,四张卡片依次是 HDC 工具链 / 连接与通道保护 / 能力矩阵 / 设备访问诊断。
底部 `JobInspector` 折叠态常驻。

**内容** — 只绑定生产 presentation，不硬编码设备、build、serial、hash 或探测结论:

StatusStrip 四格:
- `HDC server` → 当前 health / generation
- `目标设备` → 当前 adopted target / connection state；无 target 时显示明确空态
- `通道保护` → 当前 protection verdict
- `需处理` → 当前诊断计数

卡片一「HDC 工具链」,用 `KeyValueList`:
| 来源 / 路径 | 当前 HDC selection snapshot |
| 平台信任 | 当前 trust verdict + reason |
| client / server / daemon | 当前版本事实；缺失写 unknown |
| server | health · generation · ownership |
| endpoint | 当前 host / port / source |
| SHA-256 | 完整值可选择，视觉中间省略 |
| 自动 lifecycle / subserver | Runtime 返回的计数 |

版本不一致时尾注:`版本字符串不一致:只读能力按独立探测结论呈现;Flash 仍需命中已验证组合。ArkDeck 不会自动重启 external server。`

卡片二「连接与通道保护」,`KeyValueList`:
- 当前设备 → transport + 独立 authorization Chip + 独立 channel-protection Chip
- `策略` → `无可靠加密证据 → 按未受保护通道处理;设备授权 ≠ 链路机密性`

卡片三「能力矩阵（当前 target）」,`DataTable`,列 = 能力 / 状态 / 探测证据（第三列 mono），固定四行:
- `hidumper`：`debug.template.run(windowInventory)` 的 target / binding-bound 结果
- `hitrace`：`trace.probe` 的 disposition、family、tag 数与 help SHA
- `bytrace`：同一 `trace.probe` 的独立 disposition；probe failed / unrecognized 都显示 `无法确认`
- `RockUSB Flash`：Catalog 中 `flash.dayu200@1` 的 availability / reason

状态闭集为 `可用` / `受限` / `不可用` / `无法确认`。不存在 `flashd` 行，也没有 raw shell 输出入口。

卡片四「设备访问诊断」,当前无异常时的文案:
`当前未发现 permissionDenied / driverUnavailable。若出现,将区别于 offline/unauthorized 展示,并给出由谁执行的最小权限修复步骤;ArkDeck 不会自动提权或写系统规则。`

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **unknown 与 unavailable 必须视觉可分。** probe failed / unrecognized 是「无法确认」，Catalog 明确 unavailable 才是「不可用」；ArkDeck 不从“没探测到”推断“没有”。
2. **「已授权」与「加密未验证」是两枚独立 chip,不能合并成一个状态。** 设备授权 ≠ 链路机密性。
3. **版本不一致(`mismatchUnverified`)不阻断只读能力,但阻断 Flash。** 尾注要说清这个分级,不要写成"工具链故障"。
4. `ownership: external` 意味着这个 server 是 DevEco 起的——页面上不能出现任何"重启 server"的主按钮,那是 §5.2 里的独立危险 sheet。

**不要做的事**:不要发明设备名、build 串或 hash；不要复活 `flashd`、raw shell 或 `查看 raw`；不要把四张卡合并成一张长表；不要给任何 chip 配 emoji。

---

## 5.2 设备接管与授权

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **设备授权** 页。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏设备行来自 `device.candidates`，当前选中 unauthorized candidate；`NavItem` × 7（Overview · Flash · Debug · UI Dump · Trace · History · Automation）。本页是点击未授权设备行进入的,不是导航目的地 —— 七个 `NavItem` 全部非活动。
内容区只有一张 `Card`,宽度上限 640,不铺满 detail:标题 → 三步 onboarding 有序列表 → 状态块(随阶段替换) → 一行按钮。三步就是 spec 说的 解锁 → 设备端信任 → 有界等待。
底部 `JobInspector` 折叠态常驻。

一共画 **四个生产状态**:`idle` / `polling`(E000002 等待中) / `timedOut`(E000003) / `ready`,外加一张独立的 `DangerConfirmDialog`。四个状态共用同一张卡的骨架,只换状态块和按钮行。`denied` 暂无生产 probe 判据，不画成生产状态。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

页标题:`设备授权 — unknown-tablet`
卡片标题:`此设备尚未信任本机(E000002)`

三步有序列表(四个状态里都在,不随阶段消失):
1. `解锁设备屏幕;`
2. `在设备弹出的「是否信任此计算机?」中选择 信任 或 始终信任;`(`信任` 与 `始终信任` 加粗)
3. `ArkDeck 将自动检测授权结果(有界轮询,不反复弹通知)。`

状态块,每个阶段只出现一个:
- `idle` — 无状态块。
- `polling` — warn `Chip`(带缓慢脉冲):`等待设备端确认… 03:00`。`03:00` 是 mm:ss 倒计时,从 180 秒起数。
- `timedOut` — warn `Callout`:`等待设备授权超时(E000003 · timedOut)。这不等同于已知 denied。请解锁设备、检查 USB 调试与信任弹窗后重试。`
- `ready` — ok `Callout`:`已授权,设备 Ready——列表与 Overview 已更新。`

按钮行:
| 阶段 | 主按钮 | 次按钮 |
| --- | --- | --- |
| idle | primary `开始等待授权` | — |
| polling | primary `开始等待授权`,disabled | — |
| timedOut | primary `重试:开始等待授权` | danger `重启共享 HDC server…` |
| ready | primary `开始等待授权` | — |

左栏未授权设备行:warning symbol + `需要信任`,transport `USB`。
(原型该行现在写的是 `未授权 — 点击处理`;spec §5.2 要求 `需要信任`,按 spec 画。)
左栏 ready 设备行:`rk3568-dev` · `OpenHarmony 5.0.0.71` · `USB`。
`ready` 那张图里,原来的未授权行变成 `ohos-tablet` · `OpenHarmony 5.0.0.46` · `USB` · ready。

独立危险 sheet,`DangerConfirmDialog`:
- `title` = `重启共享 HDC server?`
- `impactTitle` = `影响范围`
- `impact` 三条:
  - `该 server 由 DevEco Studio 启动(ownership: external),重启将断开其与所有已连接设备的会话`
  - `其他工具正在进行的传输/调试会失败`
  - `ArkDeck 从不静默执行此操作`
- `acknowledgements` 一条:`我了解会影响 DevEco 与其他设备会话`
- `confirmLabel` = `重启共享 HDC server`,`cancelLabel` = `取消`

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **E000002 与 E000003 是两个状态,不是同一条错误的两种措辞。** E000002 = 还在等(warn chip + 倒计时,主按钮 disabled,没有次按钮);E000003 = 等待窗口已经关掉(warn callout + 可点的重试)。同一张卡上永远不会同时出现这两块。
2. **retry 是普通按钮。** `Button variant="primary"`,没有确认 sheet、没有勾选门、没有 danger 描边。「再等一次」在 ArkDeck 眼里是零代价动作,不该被仪式化。
3. **重启共享 HDC server 绝不是默认修复。** 它只在 `timedOut` 态出现,只在次要位置,永远不占主按钮位、不预选、不出现在 idle/polling/ready。它走独立 sheet 且必须勾选才解锁 —— 因为这个 server 是 DevEco 起的,重启掉的是别人的会话。
4. **左栏那一行读作「需要信任」,不是「离线」也不是「错误」。** 未授权是一个人能当场解决的状态;offline 不是。三态点必须可分:ready = ok、unauthorized = warn、offline = 灰。
5. **有界等待要把边界画出来。** `03:00` 是真的会走到 0,走到 0 就翻成 E000003。不要画无限旋转的 spinner,也不要给这段等待配百分比进度 —— ArkDeck 不知道用户什么时候会去点那个弹窗。
6. **`ready` 那张图里设备名和 build 变了(unknown-tablet → ohos-tablet · OpenHarmony 5.0.0.46)。** 授权之前 ArkDeck 拿不到设备身份,这不是刷新延迟,是「没测到」和「测到的值」的区别。

**不要做的事**:不要把原型里的 `模拟:用户拒绝(E000003)` 按钮画进产品页,那是原型自己的演示开关;不要画 `REQ-HDC-007` / `AC-HDC-007-01/02` 这类 AC 标注 chip(spec §7:评审叠加层,不进产品);不要把 E000003 画成红色 danger,原型是 warn;不要发明 serial、key 或别的错误码;不要让这张卡铺满 detail 宽度。

---

## 5.3 UI Dump

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **UI Dump** 页。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏:`DeviceRow` × 2(rk3568-dev · ready · **当前选中**;unknown-tablet · unauthorized)+ `NavItem` × 7,🌲 UI Dump 为当前页。
detail 自上而下:`RecoveryBanner`(两条,在页面内容之前、toolbar 之下) → 页标题 `UI Dump` → 两列工作区 → 页尾 scope note。
两列:左列是一条**单一工作流表单**,四段沿 leading edge 对齐、共享一条纵向轴线 —— Window inventory → Recipe → Debug parameter policy;右列 `Card` 是这条流水线的 Review 端(产物)。原型把它画成了四张平级卡片网格,spec §5.3 明确要求避免「四张孤立卡片」:分组照原型,阅读顺序按 spec 画成一条有方向的流水线。
底部 `JobInspector` 折叠态常驻。

产物卡画 **两个状态**:未采集 / 已采集。策略卡另画一张选中「保持开启」的二次确认。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

`RecoveryBanner` 两条(与 Trace 页共用同一组):
- `Flash · rk3568-dev · system 分区` + warn chip `outcomeUnknown`。正文:`上次会话在「Flash Steps · flashPartition(system)」写入 intent 后异常退出,未记录 outcome。设备最后处于 updater 模式。` / `Provider 未声明 restartSafe —— 不提供自动续跑,请按 RecoveryGuide 人工确认设备状态。` 动作:`恢复指引` + danger `结束恢复并归档…`
- `Trace · rk3568-dev` + dim chip `waiting`。正文:`等待设备重启回连(剩余 04:12)。回连后自动继续参数恢复。` 动作:disabled 的 `结束恢复并归档…`,hover 原因 `仍在等待窗口内,归档不可用`

第一段「窗口清单」,`Card` 的 `action` 是 `刷新` 按钮。`DataTable`,列 = windowId / 名称 / 焦点(第一列 mono):
- `12` · `com.example.settings / MainAbility` · `●`(**当前选中行**)
- `8` · `com.ohos.launcher` · (空)

尾注:`来源:hidumper -s WindowManagerService -a -a。解析失败时保留 raw 输出并允许安全手输 windowId。`(命令部分 mono)

第二段「Recipe」,`Card` 的 `action` 是 accent 色 mono 文字 `-w 12 -element -c`,随选中 recipe 与 windowId 实时变化。`RadioGroup`,四个选项(破折号后半段 mono):
- `elementTree — -w <w> -element -c`(默认选中)
- `nodeSummary — -w <w> -default`
- `fullDefaultTree — -w <w> -default -all`
- `componentDetail — -w <w> -element -lastpage <compId>`

只有选中 `componentDetail` 时,组下面多出一行:`compId(安全手输,只接受数字):` + mono `TextField`,宽 100,值 `33`。

第三段「Debug 参数策略」,`RadioGroup`,三项(label + description):
- `不改变参数` — `— 以设备当前状态采集`(默认选中)
- `临时开启,结束后恢复` — `— 仅当原值可读且可写回时可选`
- `保持开启` — `— 需要二次确认,状态栏持续提醒`

左对齐 primary 按钮 `采集`;运行中变成 disabled 的 `采集中…`。

选中「保持开启」后的二次确认,直接接在这一组下面:danger `Callout` + 两个按钮。
- Callout 正文:`persist.ace.debug.enabled 等参数将持久保留在设备上,可能影响性能与后续测量;设备状态栏将持续显示提醒,且该变更计入审计。`
- 按钮:`取消` + danger `确认保持开启`
- 原型这个 sheet 没有勾选门,所以不要为它编 `DangerConfirmDialog` 的 acknowledgement 文案。

右列「产物」`Card`:
- 未采集:`尚未采集。产物将按 stdout / remote sidecar / merged 派生分行列出并标注来源。`
- 已采集:`DataTable`,列 = Artifact / 来源 / SHA-256(第一列与第三列 mono):
  - `stdout.elementtree.txt` · `stdout` · `7d1a…90ff`
  - `sidecar.arkui.dump` · `remote sidecar` · `e33b…12c0`
  - `merged.elementtree.json` · `derived(可重建)` · `a1f4…77b3`
- 已采集尾注:`⚠ Dump 可能包含页面文本/包名/标识符,按敏感数据处理;导出前将提示。raw 永不原地修改。`

页尾固定 scope note:`仅 ArkUI UI Dump(窗口/组件树/组件详情)。Fault/Crash Artifact 与整机诊断快照首版不支持。`
(原型把这句放在标题下方;spec §5.3 要求固定在页尾。文字相同,按 spec 放页尾。)

`JobInspector` 里这条 Job 的标题:`UI Dump · elementTree · w12 · rk3568-dev`。若画展开态,用 `PhaseTrack`,阶段随策略变:
- 不改变参数:`Preflight · WindowInventory · Capture · Sidecars · Receive · Validate · Complete`
- 临时开启,结束后恢复:`Preflight · WindowInventory · SnapshotParam · Capture · Sidecars · Receive · Validate · RestoreParam · Complete`
- 保持开启:`Preflight · WindowInventory · SnapshotParam · Capture · Sidecars · Receive · Validate · Complete`

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **Recipe 只有四个 canonical option,没有第五个「自定义」入口。** 每个选项的 label 里就是那条 hidumper 参数本身,不塞进 tooltip:选 recipe 等于选一条已验证的命令,读者要在按「采集」之前对得上。这一页永远不出现自由命令输入框。
2. **只有 `componentDetail` 会露出 compId 输入,别的三个 recipe 页面上根本没有这个字段。** 而且它只收数字 —— `安全手输,只接受数字` 是命令注入面上的闸,不是输入便利。四个 recipe 里只有它需要一个设备上的 component ID,这就是它单独有输入框的全部理由。
3. **三条策略的代价必须贴在它自己那一行。** `仅当原值可读且可写回时可选` 是「临时开启」的前置条件,`需要二次确认,状态栏持续提醒` 是「保持开启」的代价。把它们收进卡片尾注,就等于让人先选完才知道选了什么。
4. **「不改变参数」是默认选中项,「保持开启」要第二次确认且是 danger 面。** 默认不动设备状态;要动,就得再答一次。
5. **产物三行不能合并成一行。** stdout / remote sidecar / merged 是三种不同来源,merged 标 `derived(可重建)`;`raw 永不原地修改` —— merged 是并列的第三份产物,不是覆盖前两份的结果。
6. **阶段名是承诺,不是装饰。** `RestoreParam` 只存在于「临时开启,结束后恢复」的阶段列里;选「保持开启」就没有这一步 —— 因为它本来就不打算恢复。
7. **页尾那句 scope note 是硬边界,不是路线图。** Fault/Crash Artifact 与整机诊断快照首版不支持,不要画成灰掉的 tab、「即将支持」的占位或带锁图标的入口。
8. **解析失败不是空状态。** spec 要求解析失败时给 raw 只读视图和校验后的安全手输 ID。如果画这一态,只画一块 mono 只读区 + 手输 windowId 的输入,内容留空 —— 原型只有那句尾注,没有对应的 raw 视图文案,不要编。

**不要做的事**:不要发明第五个 recipe、windowId、bundle 名或 hash;不要把 compId 做成下拉或 picker(原型是手输 + 数字过滤);不要给产物表补 size / sensitivity 列 —— spec 列了这两列但原型没有对应内容,sensitivity 现在只以整句形式活在尾注里;不要画 `AC-DUMP-*` 这类标注 chip;不要把 `RecoveryBanner` 折进页面内容里或做成可关闭的 toast。

---

## 5.4 Trace

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Trace** 页。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏:`DeviceRow` × 2(rk3568-dev · ready · **当前选中**;unknown-tablet · unauthorized)+ `NavItem` × 7,📈 Trace 为当前页。
detail 自上而下:`RecoveryBanner`(两条,与 UI Dump 页同一组) → 页标题 `Trace` → 两列。
左列竖排:`Card`「抓取配置」(heading 右侧放 `SegmentedControl size="sm"`:Preset / 自定义 tag) → `Card`「Debug 参数快照(before → desired)」 → 卡片之外一个左对齐 primary 按钮。
右列一张 `Card`「抓取状态」。
底部 `JobInspector` 折叠态常驻。

配置卡画 **两态**:Preset(表)与 自定义 tag(`TagPicker`)。状态卡画 **三态**:未抓取 / 抓取中 / 完成。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

`SegmentedControl`:`Preset` / `自定义 tag`

Preset 态,`DataTable`,列 = (选中标记) / Preset / tags(第三列 mono):
- `ArkUI 深度` · `ace app ability graphic ohos sched freq sync`(**默认选中**,行首 `●`)
- `附件兼容 / 全景` · `ace app ability graphic ohos sched freq sync binder disk workq`
- `渲染 / 动画` · `graphic ace app sched freq sync`

选中「附件兼容 / 全景」时,配置卡底部多一条 warn `Callout`:`附件兼容 preset 的 buffer 327680 超出该设备建议值,已按能力探测收敛到 307200。`

自定义 tag 态:
- 提示句:`仅设备已确认支持的 tag 可选(能力探测 tag×11);未确认的 tag 禁用并标注原因,不猜测。`
- `TagPicker`,**可选 11 个**:`ace` `app` `ability` `graphic` `ohos` `sched` `freq` `sync` `binder` `disk` `workq`(前 8 个点亮)
- **禁用 2 个,仍然可见**:`distributeddata` `mmc`,虚线边框,hover 原因 `设备未报告支持该 tag`
- 计数句:`已选 8 个 tag。`

配置卡底部一行(两态都有):
- `duration` + `SegmentedControl size="sm"`:`10s` `15s` `30s`,默认 `15s`
- `buffer 307200`(数字加粗)
- dim `Chip`:`工具:hitrace(设备已确认)`

「Debug 参数快照(before → desired)」`Card`,`DataTable`,列 = 参数 / before / desired / 恢复(前三列 mono):
- `persist.ace.trace.build.enabled` · `false` · `true` · ok `Chip` `可恢复`
- `persist.rosen.animationtrace.enabled` · `missing` · `1` · warn `Chip` `不可自动回滚`

尾注:`missing/unreadable 原值不承诺自动恢复:只允许「不改变」或显式确认的持久变更。本组合需要设备重启,预计断开 → 回连同一设备。`

主按钮,primary,左对齐,在卡片之外:`应用参数并开始抓取(ArkUI 深度 · 15s)`;抓取中变成 disabled 的 `抓取中…`。括号里的名字与秒数跟随左列选择;自定义 tag 态下写作 `自定义(8 tags)`。

右列「抓取状态」`Card`:
- 未抓取:`未在抓取。完成后产物:*.raw.ftrace(不可变)/ *.filtered.ftrace(派生)/ capture.log / manifest.json。`(四个文件名 mono)
- 抓取中:warn `Chip`(脉冲)`抓取中` + `IndeterminateBar`,下面一句:`设备端无可靠字节总量,不显示百分比——只显示阶段(见底部任务抽屉)与不定进度。`(`不显示百分比` 加粗)
- 完成:`DataTable`,列 = Artifact / 角色 / SHA-256(第一列与第三列 mono):
  - `arkui-deep.raw.ftrace` · `raw(不可变)` · `3f9a…b1c7`
  - `arkui-deep.filtered.ftrace` · `derived(可重建)` · `c822…04de`
  - `capture.log` · `log` · `910b…77aa`
  - `manifest.json` · `manifest` · `e0a1…88f2`
  - 尾注:`✓ 参数已按快照恢复;raw hash 已写入 manifest。`

`JobInspector` 里这条 Job 的标题:`Trace · ArkUI 深度 15s · rk3568-dev`。若画展开态,用 `PhaseTrack`,阶段逐字如下:`Preflight · SnapshotParams · Configure · Reboot · WaitReconnect · Capturing · Receiving · Validating · Restore · Complete`,安全边界落在 `WaitReconnect`。
spec §5.4 还要求不定进度旁显示 elapsed;原型页面上没有,elapsed 归 `JobInspector`。别在右列编一个计时器。

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **只有设备已确认的 tag 可选;未确认的那两个保持可见、禁用、并给出原因。** `distributeddata` 与 `mmc` 不在「未选」里,而在「未确认」里 —— 把它们藏起来会让人以为这台设备没有该 tag,而真正发生的是 ArkDeck 没能确认它。全选也只到 11。这个区别就是这个控件存在的理由。
2. **参数 snapshot 是一张 diff 表,不是彩色卡片。** `missing` 那一行的「恢复」列必须是 warn chip `不可自动回滚`,与上一行的 ok chip `可恢复` 视觉可分。`missing`/`unreadable` 意思是 ArkDeck **读不到原值**,不是「原值是空」—— 读不到就没法承诺还原,所以只允许「不改变」或显式确认的持久变更。
3. **需要重启的影响写在执行之前。** `本组合需要设备重启,预计断开 → 回连同一设备。` 主按钮自己也要承认它先改参数再抓:`应用参数并开始抓取(…)`,不是「开始」。
4. **抓取中是 indeterminate,而且要说明为什么。** 不要 0–100 进度条、不要 ETA、不要编字节数或帧数。`设备端无可靠字节总量` 这句留在页面上 —— 它是设计承诺,不是可以省掉的解释。
5. **完成后四行分列,角色不同。** raw 标 `不可变`,filtered 标 `derived(可重建)`,`capture.log` 与 `manifest.json` 各占一行。筛选是在派生产物上做的操作,永远不回写 raw;`raw hash 已写入 manifest` 是这条不变量的凭据。
6. **buffer 收敛是已经发生的事实,不是待你确认的选项。** `327680 → 307200` 用 warn callout 陈述结果,旁边不给「仍按 327680 试一次」的按钮或撤销链接。
7. **Preset 与自定义是同一件事的两个入口,不是两种运行模式。** 切到自定义时带着当前 preset 的 tag 集合进来;至少保留一个 tag —— 已选数为 1 时最后那个取消不掉,抓取始终带一个 tag。

**不要做的事**:不要发明 tag、preset、参数名、时长档位或 hash;不要给 tag 面板加全选/反选(原型没有,加了就会让人以为能选到那两个禁用项);不要把禁用 tag 收进「更多」或折叠区;不要把 `IndeterminateBar` 换成 spinner + 百分比;不要画 `AC-TRACE(param)` 这类标注 chip;不要把 `RecoveryBanner` 折进页面内容里 —— 那条 `Trace · rk3568-dev · waiting` 说的正是这台设备现在的处境。

---

## 5.5 Debug 工作台

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Debug 工作台**页。四个 tab 各画一张:Logs / Apps / Network / Commands。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏:`DeviceRow` × 2(rk3568-dev / unknown-tablet)+ `NavItem` × 7(◎ Overview · ⚡ Flash · 🐞 Debug · 🌲 UI Dump · 📈 Trace · 🗂 History · ⚙ Settings,Debug 为当前页)。
内容区自上而下:`RecoveryBanner`(跨页常驻,不是本页新增)→ 页标题 `Debug 工作台` → `Tabs`(四项)→ 当前 tab 的内容,一张 `Card` 装完。
底部 `JobInspector` 折叠态常驻。本页没有 `StatusStrip`——那是 Overview 的。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

Tabs 四项:`Logs` · `Apps` · `Network` · `Commands`。

Logs tab,控制行从左到右一行排开(会换行):
- 主按钮:未采集时 `开始采集`(primary);采集中时 `停止采集`(default)
- `暂停界面` / 采集暂停后变 `恢复界面`;**未采集时该按钮 disabled**
- 小字 `level ≥` + `SegmentedControl` size `sm`,三档 `I` `W` `E`,当前 `W`
- `TextField` mono,占位符 `tag 过滤`,宽约 110
- `Chip` tone `dim`:`host 轮转: 片 #3 · 11.8MB/64MB · 配额 1GB`
- 右端(和上面隔开)`Button` variant `danger`:`清空设备 buffer…`

暂停时,控制行下方多一枚 `Chip` tone `warn`:`界面已暂停 · N 行待补`(N 是暂停期间攒下的行数,一直在涨;原型没有固定值,画一个两三位数即可)。

`LogTail`,`emphasis`,maxHeight 220,格式 `07-13 时间 等级 tag: 正文`:
```
07-13 11:02:11.482 W ArkUI: [list_layout] measure retry, node 88
07-13 11:02:11.490 W ArkUI: [render] flush delayed 22ms
07-13 11:02:12.013 E AbilityMS: connect timeout, bundle=com.example.settings
07-13 11:02:12.400 W ArkUI: [list_layout] measure retry, node 91
```
要更多行只能从这几条里取(同格式,别自己编日志):`W ArkUI: [render] flush delayed 18ms`、`W Multimodal: touch dispatch queue depth 3`、`I RenderService: flush composition, 1 surface dirty`、`I Hiview: cpu usage snapshot written`、`I WindowManager: focus window unchanged (12)`。注意默认筛选是 level ≥ `W`,所以 `I` 行在默认档下**不应该出现**;要画 `I` 行就把分档切到 `I`。
筛空时正文写 `(当前过滤条件下没有日志)`。

LogTail 下方 hint,两态各一句:
- 采集中:`采集中:设备端持续拉流,host 侧按 64MB/片轮转,不清设备 buffer。`
- 未采集:`未在采集。开始/停止只影响 host 侧拉流,绝不清空设备 buffer。`

`清空设备 buffer…` 打开 `DangerConfirmDialog`:
- title `清空设备日志 buffer?`
- impactTitle `hilog -r 是全局且不可恢复的设备端操作`
- impact 三条:`会影响其他工具正在进行的采集` / `普通的开始 / 停止采集绝不自动清空` / `该操作计入审计`
- acknowledgements 一条:`我了解这会清空所有工具可见的设备日志`
- confirmLabel `清空设备 buffer`,cancel `取消`
- 确认后日志区只剩一行:`07-13 11:04:00.000 I audit: hilog -r executed (user-confirmed); device-side buffer cleared`

Apps tab,`DataTable`,列 = 包名(mono)/ 版本 / 状态 / 操作:
- `com.example.settings` · `1.2.0` · `Chip` ok `运行中 · pid 2841` · `停止`
- `com.demo.gallery` · `0.9.1` · `Chip` dim `未运行` · `启动 Ability` + `Button` danger `卸载…`
表下 `Button` primary:`安装 HAP…`

`安装 HAP…` 开普通 sheet(不是 danger):标题 `安装 HAP`,`KeyValueList`:
| 文件 | ~/Downloads/todo-demo.hap · 4.2MB |
| 包名 / 版本 | com.sample.todo · 0.3.0 |
| 签名 | 证书链完整 · profile 含本设备 + ok `Chip` `✓` |
hint:`安装是 deviceMutation:进入任务抽屉,按阶段推进,可在安全边界取消。`
按钮 `取消` / primary `安装到 rk3568-dev`。派发后 `JobInspector` 里出现 `安装 HAP · todo-demo.hap · rk3568-dev`,`PhaseTrack` 五阶段 `Preflight` → `Transfer` → `Install` → `Verify` → `Complete`。

`卸载…` 开 `DangerConfirmDialog`:title `卸载 com.demo.gallery`,impactTitle `影响范围`,impact 三条 `设备:rk3568-dev · serial 150100469…` / `应用本体与其数据将从设备移除(deviceMutation,计入审计)` / `ArkDeck 不保留该应用数据的副本`;ack `我确认卸载 com.demo.gallery 及其数据`;confirmLabel `卸载 com.demo.gallery`。

Network tab,`DataTable`,列 = 类型 / 本机(mono)/ 设备(mono)/ 操作:
- `forward` · `tcp:9222` · `tcp:9222` · `删除`
空表文案 `无转发规则`。表下 `Button` primary `新建转发…`。
sheet:标题 `新建端口转发`,hint `forward:本机端口 → 设备端口(hdc fport)。`,一行两个 mono `TextField`:`本机 tcp:` `9223` `→ 设备 tcp:` `9223`;按钮 `取消` / primary `添加转发`。

Commands tab:
- `Callout` tone `warn`:`App 只提交 approved typed template 与 schema-defined inputs。下面的 executable / argv 是 Provider lowering 的只读预览,不是输入框。`
- `Select` mono,四个选项(封闭集):`已安装包清单` · `读取 ArkUI Debug 参数` · `窗口清单` · `设备运行时长`;旁边 `Button` primary `运行 typed template`
- `KeyValueList` 三行:`template id` → `device.packageInventory`;`effect` → `EffectBadge` effect `readOnly`;`lowered argv` → `hdc -t 150100469… shell bm dump -a`
- 未运行时 `尚未运行 typed template。运行后显示 Provider lowering、退出码与耗时。`
- 运行后每次一段 `LogTail`:
```
template device.packageInventory · 已安装包清单
provider lowering (read-only): hdc -t 150100469… shell bm dump -a
exit 0 · 812ms
com.example.settings
com.demo.gallery
com.ohos.launcher
```
- 页尾 hint:`不存在自由文本 command / argv / path 字段;PTY 与 raw shell 不属于此界面。`

另外三个模板的真实数据(要画第二段回显就从这里取,四个模板 effect 全是 `readOnly`):
- `device.debugParameterRead` · 读取 ArkUI Debug 参数 · `hdc -t 150100469… shell param get persist.ace.debug.enabled` · 输出 `0` · 104ms
- `device.windowInventory` · 窗口清单 · `hdc -t 150100469… shell hidumper -s WindowManagerService -a -a` · 输出三行 `WindowName  DisplayId  Pid   WinId  Type` / `settings0   0          2841  12     APP` / `launcher    0          1203  8      LAUNCHER` · 436ms
- `device.uptime` · 设备运行时长 · `hdc -t 150100469… shell uptime` · 输出 ` 11:02:33 up 2 days,  3:14,  load average: 1.02, 0.88, 0.79` · 96ms

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **「暂停界面」暂停的是界面,不是 host 采集。** 暂停态要同时画出三个证据:`界面已暂停 · N 行待补` 这枚 chip(数据还在进来)、主按钮仍是 `停止采集`(采集还在跑)、hint 仍是 `采集中:…` 那句。把它画成「暂停采集」就把整条语义抹掉了。
2. **「清空设备 buffer」是设备端全局且不可恢复的动作,只能走危险 sheet。** 它与「开始/停止采集」不是同一类东西:后者只动 host 侧拉流。两句 hint 都在强调「绝不清空设备 buffer」,不要因为嫌重复而删掉任何一句。规格要求它待在 destructive actions 菜单里;原型把它放在控制行最右的 danger 按钮上——两种都行,唯独不能让它和 `开始采集` 看起来是同一权重的兄弟按钮。
3. **Commands 只有 approved typed template。** `Select` 是封闭下拉,不是可输入的 combobox;`lowered argv` 是**只读回显**,画成 `KeyValueList` 的值或 mono 文本,绝不画成带边框的输入框。没有自由文本命令区、没有 `$` 提示符光标、没有 PTY。回显里的 `provider lowering (read-only):` 这行前缀是故意的,留着。
4. **Apps 把 mutation 与 read-only 分开。** 卸载 = destructive,danger 按钮 + sheet;启动/停止 = deviceMutation,普通按钮就地执行;安装 = deviceMutation,进任务抽屉按阶段推进。三者的视觉重量必须不同。pid 用等宽 tabular numbers,包名 mono。
5. **Network 只收 typed 端口。** 两个数字字段,非数字被丢弃;界面上不存在任何能贴进 shell 片段的地方。
6. **切 tab 只换视图。** 目标设备、执行模式、正在跑的任务都不随 tab 变;焦点留在 tab 条上,不被强行搬到面板里。

**不要做的事**:不要画终端窗口、`$` 提示符或任何看起来能敲命令的地方;不要给 Commands 加「高级模式 / 自定义命令」入口;不要发明包名、pid、serial、日志行或模板 id;不要画百分比进度(设备不报可信总量);不要给 chip 配 emoji——`✓ ⚠ ⊘` 这类排版符号可以,走 `Chip` 的 `icon` 位。

---

## 5.6 Flash

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Flash** 页。三个模式各画一张(Execute / Plan only / Simulated),外加一张「正在写入分区」的执行中状态。以当前 DAYU200 / `flash.dayu200@1` 产品事实为准。

**当前权威 brief（旧原型 literals 全部失效）**:

- 顺序固定为 Availability → Rockchip device access → Profile & Image Set → Prerequisites → Exact Plan → Review & Run。所有 target、build、partition、size、hash、toolchain 与 plan digest 都直接绑定 App facade 的生产 presentation；不得硬编码 rk3568、flashd 或示例 serial。
- Execute 的 Exact Plan 与 data impact 完整展示后，只有一个 danger 主按钮 `擦除用户数据并刷机`。不打开确认 sheet，不画 checkbox，不要求输入短语。按钮说明须明确它只是 UX acknowledgement；Runtime capability 与 fresh facts 仍是唯一准入。
- 提交期间每 750ms 读取 `job.list`，用 indeterminate progress + 真实 timeline 展示状态；不画百分比或 ETA。timeline 尾部进入 `criticalNonInterruptible` step 时，页面与 Job Inspector 同时显示完全一致的临界写入 callout。
- Rockchip 访问卡必须区分 permission denied、driver unavailable、offline/unauthorized、tool blocked 与 protocol blocked，并显示责任方、ArkDeck 外最小修复动作和普通 `重新检查设备访问` 按钮。不得画 sudo、驱动安装或全局权限放宽入口。
- 成功后只画两个已有生产字段的 Postflight 对照：`observation.firmware` 对 profile `runtimeBuildVersion`；pre binding revision 对 `observation.bindingRevision`，成功关系为 `n→n+1`。manifest 全 executed + SHA 尚无字段，不画占位行。
- USB rebind 在稳定身份、相邻 binding revision 与 updater/plan 阶段证据完整时自动继续，任何缺失或漂移都 fail closed；TCP / UART 断连才进入人工 rebind confirmation。不要把有 durable proof 的 USB 恢复写成“静默续刷”。
- 当前 Catalog 只发布 USB / RockUSB 的 `flash.dayu200@1`，所以不要画 rebind confirm / abort 控件；未来 TCP / UART Flash 必须先有 domain 状态与 RPC，设计不能先行伪造。
- Plan only / Simulated badge 永久保留；Execute 没有 badge。所有状态以 symbol + 文案表达，不只靠颜色；长 hash 中间省略但完整值可选择/查看；900×600 和 VoiceOver 阅读顺序必须保留主按钮前的风险信息。

**当前生产事实与刻意边界**:

- Prerequisites 来自 target / binding / profile-bound `flash.prerequisites`，闭集为 `loader` / `recoveryPath` / `unlocked` / `stablePower`；没有 `flashd`。
- `recoveryPath` 只有在 owner-only DAYU200 跨模式 binding 精确覆盖当前 target identity、相邻 revision 与 HDC alias 时才是 satisfied；HDC adoption 本身不构成跨模式证明。required 项为 unknown / unsatisfied 时保留 Exact Plan 审阅，显示可见 blocker 并禁用主按钮，Runtime 使用同一事实在 capability 签发与首个外部 effect 前双重拒绝。
- Trace tag、参数 before / after、Debug 日志 / 包清单 / 端口规则和 Overview 能力矩阵均接生产 facade。缺失或不匹配时显示 unavailable / unknown，不用 fixture 补洞。
- Flash `job.cancel` 已开放，临界写入只停止后续步骤；Artifact 在 History 中逐项导出；Automation 只开放既有 task 的 list / reconcile / pause / cancel。
- HDC production authorization 由 domain-owned durable binding 刷新；App 可展示真实 `.timedOut`，但生产 probe 尚不能推导的 `denied` 不得从 fixture 搬过来。
- Flash Postflight 仍只有 build 对照与 binding revision 两行；manifest 全 executed + SHA 无 wire 字段，继续不画。

<details>
<summary>已废止的 rk3568 / flashd 原型参考（仅供追溯，不得用于新设计或实现）</summary>

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏:`DeviceRow` × 2(rk3568-dev / unknown-tablet)+ `NavItem` × 7(Flash 为当前页)。
内容区自上而下:`RecoveryBanner` → 页标题 `Flash` + 紧随其后的模式 badge → `SegmentedControl`(Execute / Plan only / Simulated,label「执行模式」)→ 两列区域。
左列自上而下三张 `Card`:`Profile / Image Set — rk3568-5.0-full` → `Prerequisites` → (执行成功后才出现)`上次执行 · Postflight`。
右列一张 `Card`:`Exact Plan`,表下面就是 Review & Run 区。
底部 `JobInspector` 折叠态常驻;执行中展开态要一起画。

规格把模式段控放在 toolbar、并要求详情第一节是 **Availability(`AVAILABLE` / `UNAVAILABLE(reasonCode)`)**。原型两点都没有:段控在内容区顶部一张卡里,且 Flash 页没有任何 Availability 文案或 reasonCode 串。按规格的顺序排版,但 Availability 那一节留空槽并标注「原型未提供文案」,不要编 reasonCode。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

模式 badge(紧跟页标题):
- Execute → **没有 badge**
- Plan only → `Chip` tone `planned` icon `◇`:`PLANNED — 不派发 deviceMutation/destructive`
- Simulated → `Chip` tone `simulated` icon `▤`:`SIMULATED · fixture-a3 — 不接触真实设备`

卡片「Profile / Image Set — rk3568-5.0-full」,`DataTable`,列 = 分区 / 镜像 / 大小 / SHA-256(全 mono):
- `boot` · `boot.img` · `64MB` · `c9d2…41aa ✓`
- `system` · `system.img` · `2.1GB` · `8b07…9e35 ✓`
卡尾 hint:`镜像原地引用,不复制进 Session;GB 级流式 hash。`

卡片「Prerequisites」,无表头的三列表(名称 / 状态 / 补充):
- `root-capable build` · ok `Chip` `satisfied`
- `进入 updater` · ok `Chip` `satisfied`
- `flashd 能力` · 默认 warn `Chip` `unknown`,第三列一个勾选框,标签 `演示:已在升级模式实测确认`;勾上后状态变 ok `satisfied`,勾选框消失
- `稳定供电` · ok `Chip` `satisfied`

卡片「Exact Plan」,`DataTable`,列 = `#` / `step` / `参数摘要` / `effect` / (最后一列无表头):
| 1 | enterUpdater | — | `EffectBadge` deviceMutation |
| 2 | flashPartition | boot · boot.img · 64MB | `EffectBadge` destructive |
| 3 | flashPartition | system · system.img · 2.1GB | `EffectBadge` destructive |
| 4 | reboot + waitReconnect | binding revision + 强证据 | `EffectBadge` deviceMutation |
| 5 | postflight verify | 版本/设备校验 | `EffectBadge` readOnly |
Plan only 模式下,**每一行**最后一列都是 `Chip` tone `planned`:`notExecuted(planned)`;其余模式该列为空。

Review & Run 区,按模式三态:
- Execute:`Button` variant `danger`:`刷写 rk3568-dev(2 个分区)…`。flashd 仍为 unknown 时按钮 disabled,`title` = `required prerequisite flashd 为 unknown,临界步骤前阻断`,并且**旁边一句可见的阻断说明**:`⚠ flashd unknown → 执行分支被阻断(不能刷到一半才发现)`
- Plan only:`Button` primary `生成完整计划(零设备写入)`;生成后追加 `Button` `查看 plan artifact` + `Chip` planned `◇ planned · 已持久化`
- Simulated:`Button` primary `运行模拟场景(断连注入)`。只有模拟 **TCP / UART** transport 时才进入 `WaitReconnect → Rebind 确认`；模拟 USB 时，在稳定身份、相邻 binding revision 与 updater/plan 阶段证据完整匹配后自动 rebind，证据不足则 fail closed。(原型里的 AC 编号是评审叠层，不进产品——本页任何地方都不要画 REQ/AC chip。)

执行中(Execute 且任务在跑),Exact Plan 卡片内 `Callout` tone `danger`:
`正在写入分区 —— 临界区不可中断:取消只会停止后续步骤。请勿合盖、手动睡眠、断电或拔线(idle sleep 已由系统保持,但合盖无法被阻止)。`
(⚠ 由 `Callout` 自己画,文案里别再打一个。)

Execute 不打开 `DangerConfirmDialog`，也不要求 checkbox 或文字短语。Exact Plan、目标、镜像、分区、userdata 影响、供电提示和 bootloader / 厂商恢复路径在 Review & Run 中完整可见；随后只有一个 danger 主按钮 `擦除用户数据并刷机`。点击即提交 typed request，但该点击只是 UX acknowledgement，Runtime capability 与 fresh facts 仍是唯一准入。

`JobInspector` 里的 Execute 任务:标题 `Flash · rk3568-5.0-full · rk3568-dev`,`PhaseTrack` 九阶段 `Preflight` `EnterUpdater` `Re-identify` `flash boot` `flash system` `Verify` `Reboot` `Postflight` `Complete`,当前停在 `flash system`。日志尾部:
```
→ Preflight
已获取 CriticalActivityLease(idle sleep 保持)
→ EnterUpdater
→ Re-identify
→ flash boot
→ flash system
用户请求取消(策略:atSafeBoundary)
— 已请求取消:等待安全边界 —
```
取消按钮文案 `取消(在安全边界)`;已请求取消后变 `等待安全边界…` 并 disabled。任务上的 criticalNote 与页面内那句一字不差。完成文案 `完成:postflight 校验通过,设备回报 build 与镜像期望一致。`

Plan only 任务:标题 `Flash(plan-only)· rk3568-5.0-full`,阶段 `Preflight` `Validate` `makePlan` `Persist plan`(全部走完),日志只有一行:`完整计划含 2 个 destructive 步骤,全部 notExecuted(planned);mutation dispatch = 0。`
`查看 plan artifact` 开普通 sheet,标题 `plan artifact — rk3568-5.0-full` + `Chip` planned `◇ PLANNED`,正文是只读 JSON:
```
{
  "schema": "flash-plan/1.0",
  "profile": "rk3568-5.0-full",
  "device": {"serial": "150100469…", "bindingRevision": 3},
  "steps": [
    {"n":1,"step":"enterUpdater","effect":"deviceMutation","status":"notExecuted(planned)"},
    {"n":2,"step":"flashPartition","target":"boot","sha256":"c9d2…41aa",
     "effect":"destructive","status":"notExecuted(planned)"},
    {"n":3,"step":"flashPartition","target":"system","sha256":"8b07…9e35",
     "effect":"destructive","status":"notExecuted(planned)"},
    {"n":4,"step":"reboot+waitReconnect","effect":"deviceMutation","status":"notExecuted(planned)"},
    {"n":5,"step":"postflightVerify","effect":"readOnly","status":"notExecuted(planned)"}
  ],
  "mutationDispatch": 0
}
```
sheet 尾注:`plan artifact 已持久化到 Session;PLANNED 标识在历史与导出中永久保留。`

Simulated 任务:标题 `Flash(simulated)· fixture-a3 TCP 断连注入`,设备 `SIM-fixture-a3`,阶段 `Preflight` `EnterUpdater` `flash boot` `注入断连` `WaitReconnect` `Rebind 确认` `reconcile` `Complete`,停在 `Rebind 确认`。日志首行 `→ Preflight(合成设备,无真实 connectKey)`,停下时追加 `检测到 TCP 断连后回连:等待用户 rebind 确认。`USB fixture 不复用这条人工确认路径：完整证据允许自动 rebind，缺失或漂移直接阻断。
rebind 区块(在 Job inspector 里,不是弹窗):粗体 `设备回连,需确认后继续`,mono 证据行 `同一 serial · binding revision 3→4 · updater 阶段与 plan 一致`,两个按钮 primary `确认同一设备,继续` / `中止`。确认后日志 `用户确认 rebind:同一 serial · binding revision 3→4;继续执行。`;中止后任务终态为已取消,日志 `用户中止 rebind:剩余步骤不执行;该结论写入审计。`。完成文案 `完成:reconcile 与注入脚本一致;SIMULATED 标识永久保留。`

卡片「上次执行 · Postflight」(仅执行成功后),`KeyValueList`，只画 Runtime 当前已投影的两行:
| 设备回报 build | OpenHarmony 5.0.0.96 + ok `Chip` `= 镜像期望 ✓` |
| 设备身份 | 同一 serial · binding revision 3→4 |

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **模式 badge 永不脱落。** 段控是模式的来源,badge 紧跟标题;PLANNED / SIMULATED 还要出现在 `JobInspector` 的任务行、History 行与导出包里。Execute **没有** badge——「没有徽章」本身就是「这是真的」的表达,不要为了对称给它补一个 `EXECUTE` chip。
2. **详情顺序是 Availability → Profile & Image Set → Prerequisites → Exact Plan → Review & Run。** 先说这台设备能不能做,再说做什么、再说凭什么能做、再说具体做几步、最后才是那颗按钮。Availability 这一节原型没有文案,留空槽并注明,不要拿 Prerequisites 顶替。
3. **unknown 的前置条件要画成「带理由的阻断」,不是一个灰按钮。** `flashd 能力` 是 unknown 时,`⚠ flashd unknown → 执行分支被阻断(不能刷到一半才发现)` 这句必须**可见**——它不能只藏在 disabled 按钮的 hover title 里。unknown 用 warn,不用 danger:ArkDeck 不知道,和 ArkDeck 知道它不行,是两件事。
4. **Exact Plan 的 effect 列和 disposition 列是这张表存在的理由。** 五步各自的 effect 分级(deviceMutation / destructive / readOnly)用 `EffectBadge` 画满;Plan only 下每行都要有 `notExecuted(planned)`,配合 `mutationDispatch: 0`——plan-only 不是「按钮变灰的 Execute」,它是一次真的、有产物的、零写入的运行。
5. **临界写入期间,页面和 Job inspector 说同一句话。** 措辞是「取消只会停止后续步骤」,不是「无法取消」:当前写入不会被强杀,后续步骤会停。电源提示要保留那句诚实的括号——`idle sleep 已由系统保持,但合盖无法被阻止`。这一刻取消按钮变 `等待安全边界…` 并禁用。
6. **断连按 transport 分流,摆证据不摆结论。** TCP / UART rebind 区块给可核对的原始比对，并保留继续 / 中止两个明确选择。USB 在稳定身份、相邻 revision、updater/plan 阶段证据完整时按 Core 自动 rebind；缺证据或漂移时零新 dispatch。不要把有 durable proof 的 USB 自动恢复描述成“静默续刷”。
7. **Postflight 是「设备回报 build = 镜像期望」的对照,不是「成功」两个字。** 当前只画 build 对照与 binding `n→n+1`；manifest 全 executed + SHA 尚无生产字段，不画占位行。

**不要做的事**:不要画百分比进度条或 ETA(设备不报可信字节总量,用 `PhaseTrack` + `IndeterminateBar`);不要发明分区名、镜像名、大小、hash、serial、build 串或 fixture id;不要把 SIMULATED 缩成角落里的小灰字;不要给 Flash 添加确认 sheet、勾选框或文字短语;不要给 chip 配 emoji。

</details>

---

## 5.7 History

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **History** 页,三栏。至少画两种选中态:`S-0711-04`(已中断 · 结果未知)与 `S-0712-02`(planned)。

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
最左仍是应用侧栏(`DeviceRow` × 2 + `NavItem` × 7,History 为当前页)。
内容区按规格是**三栏 split view**:筛选栏 → Session 表 → 详情 inspector。原型把筛选画成了内容区顶部的一张卡加两行 pill,是两栏——按规格改成三栏,把两行 `FilterPills` 竖着放进最左那栏。
详情栏自上而下按固定分组:Summary → Timeline → Parameters → Artifacts → Recovery linkage。
底部 `JobInspector` 折叠态常驻。

规格还要求全文搜索、时间筛选,以及「筛选器可存为 toolbar menu」。原型这三样都没有任何控件与文案——要画就只画一个空的搜索 `TextField` 和它在 toolbar 里的位置,不要编筛选器名字或时间区间。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

`FilterPills` 三行,label 分别是 `状态` / `模式` / `设备`:
- 状态:`全部` `成功` `失败` `已取消` `planned` `已中断`
- 模式:`全部` `execute` `plan-only` `simulated`
- 设备:`全部` `rk3568-dev` `SIM-fixture-a3`

Session 表,`DataTable`,列 = Session(mono)/ 状态 / 设备(mono)/ 内容 / 时间(mono),六行:
| S-0713-06 | dim `⊘ 已取消` | rk3568-dev | Trace · 渲染/动画 30s(用户取消) | 07-13 10:21 |
| S-0712-01 | ok `✓ 成功` | rk3568-dev | Trace · ArkUI 深度 15s | 07-12 14:02 |
| S-0712-02 | planned `◇ PLANNED` | rk3568-dev | Flash · rk3568-5.0-full(3 分区) | 07-12 15:40 |
| S-0712-03 | ok `✓ 成功` + simulated `▤ SIMULATED` | SIM-fixture-a3 | Flash · 断连注入场景(reconcile 一致) | 07-12 16:11 |
| S-0711-04 | warn `⚠ 已中断 · 结果未知` | rk3568-dev | Flash · system 分区(outcomeUnknown) | 07-11 23:47 |
| S-0711-05 | danger `✕ 失败` | rk3568-dev | UI Dump · elementTree(设备离线) | 07-11 20:15 |
本次会话刚产生的行,Session 号后面跟一枚小标签 `本会话`。筛空时表体写 `无匹配项`。

详情栏标题 `Session 详情`。未选中时:`选择左侧 Session 查看 manifest、参数 before/after、Artifact 与审计详情。planned/simulated 标识在历史与导出中永久保留。`

Summary,`KeyValueList`(以 `S-0711-04` 为例):
| 状态 | warn `⚠ 已中断 · 结果未知` |
| executionMode | execute |
| 设备 | rk3568-dev · binding rev 3 |
| manifest | schema 1.0 · 9 steps · SHA e0a1…88f2 |
| 审计 | outcomeUnknown @ flashPartition(system) · needsAttention · 未执行补偿:restoreParam×2 |
已取消的会话,审计行改为:`用户取消 @ 安全边界;补偿动作已执行,参数已恢复`。成功与 planned 的会话没有审计行。

Timeline:原型没有为已结束的会话提供时间轴文案。可以用 `PhaseTrack` 复用 Flash 任务自己声明的九个阶段 —— `Preflight` `EnterUpdater` `Re-identify` `flash boot` `flash system` `Verify` `Reboot` `Postflight` `Complete` —— 并把中断点停在 `flash system`(与审计行的 `flashPartition(system)` 对得上)。这是从任务定义推出来的,不是新编的;除此之外不要造时间戳。

Parameters(只有 Trace / UI Dump 会话有),`DataTable`,列 = 参数(mono)/ before / after / 状态:
- `persist.ace.trace.build.enabled` · `false` · `false` · ok `Chip` `已恢复`
- `persist.rosen.animationtrace.enabled` · `missing` · `missing` · dim `Chip` `未改变`

Artifacts,小标题 `Artifact`,`DataTable` 列 = 文件(mono)/ role / origin / size / SHA-256(mono)/ privacy / status。所有值来自 `artifact.list`，按会话类型取生产返回行；不得使用下面的旧示例 hash 作为真实值:
- Trace:`raw.ftrace` · raw / device · `3f9a…b1c7`;`filtered.ftrace` · derived / host · `c822…04de`;`capture.log` · log / host · `910b…77aa`
- UI Dump:`stdout.elementtree.txt` · raw / stdout · `7d1a…90ff`;`sidecar.arkui.dump` · raw / device · `e33b…12c0`;`merged.elementtree.json` · derived / host · `a1f4…77b3`
- Flash(execute):`plan.json` · plan / host · `b7c3…e901`;`flash.log` · log / host · `44d0…a2c8`
- Flash(plan-only):只有 `plan.json` · plan / host · `b7c3…e901`
空表文案:`无产物(planned 会话仅含 plan artifact)`

每个 `published` Artifact 行有 `导出…`；成功后同一行出现 `在 Finder 中显示`。missing / invalid 状态禁用导出并显示 status detail。

`导出…` 先开系统 confirmation dialog:
- 标题 `导出 Artifact`
- message 逐项展示实际文件名、格式化 size、privacy 与完整 SHA-256
- 普通 Artifact 主按钮 `选择导出位置`；sensitive Artifact 主按钮 `导出敏感 Artifact…`，明确这是显式敏感数据 opt-in
- 取消后不产生读取；确认后再开 `NSSavePanel`

导出过程中显示小型 `ProgressView`。App 分块读取并复算 byteCount / SHA-256，校验通过才落到用户选择的位置；失败在行内显示原因。设计中不画 Session zip、多选项或 connectKey 脱敏开关，因为当前生产能力的边界是单个不可变 Artifact。

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **已中断 / 失败 / 已取消是三种东西,必须靠 symbol + 文案分开,不能只靠颜色。**
   - `⊘ 已取消`(dim)——人主动停的,补偿已执行、参数已恢复,是最轻的一种;
   - `✕ 失败`(danger)——做了、没成,但**结果是已知的**;
   - `⚠ 已中断 · 结果未知`(warn)——不知道设备现在是什么状态。
   直觉上「中断」像是「失败」的变体,恰恰相反:失败有结论,中断没有。文案里的 `· 结果未知` 是这一条的全部重量,不许简写成「已中断」。
2. **unknown outcome 额外背着 needsAttention。** 详情审计行里的 `outcomeUnknown` 与 `needsAttention` 都要出现,并且要指出未执行的补偿(`未执行补偿:restoreParam×2`)——归档不等于收拾干净了。这条会话与 `RecoveryBanner` 上那条 Flash 恢复项是同一件事,详情里要能看出这层关联(Recovery linkage 分组的内容就是它;原型只给了这一行审计文案,没有跳转控件,别自己发明按钮标签)。
3. **三栏,不是两栏。** 筛选是一栏,清单是一栏,详情是一栏;详情栏常驻(选中前显示那句空态文案),不要做成点一下才滑出来的抽屉。
4. **详情分组顺序固定:Summary / Timeline / Parameters / Artifacts / Recovery linkage。** 每组一个小标题,不要把它们合并成一张长 KeyValueList。
5. **导出先看精确 Artifact 元数据,再选择位置。** name / size / privacy / SHA-256 四项都要出现；sensitive 使用更明确的主按钮，不能与普通产物无差别导出。
6. **planned / simulated 标识跟着会话进入 History。** `S-0712-02` 这类 planned 会话若没有已发布 Artifact，空表文案要如实写出来——那不是「加载失败」。单 Artifact 导出保留其既有 bytes 与 metadata，不生成新的 Session mode 声明。

**不要做的事**:不要用颜色区分状态(要 symbol + 文字,高对比度模式下也得读得出来);不要把「已中断」画成「失败」的红色变体;不要发明 Session id、hash、时间戳、设备名或文件名;不要画尚不存在的 Session zip 导出或多选清单;不要给状态 chip 配 emoji——`✓ ✕ ◇ ⊘ ⚠ ▤` 是排版符号,走 `Chip` 的 `icon` 位,照抄即可。

---

## 5.8 Settings

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Settings** 页。

**布局** — Settings 是系统 `Settings` scene,不是主窗口的一页:画成一个比主窗口窄的独立 `WindowFrame`,标题 `ArkDeck — Settings`,没有 sidebar、没有设备列表、没有底部 Job inspector。内容区不再重复超大标题(页面标题已在 window chrome 上)。主窗口通往它的入口是 toolbar 上一枚 icon-only `ToolbarButton`(`Symbol name="settings"`,aria-label `打开设置`),那枚按钮属于主窗口,不画进这一稿。
内容区是两列 `Card` 网格,四张卡依次是 HDC 工具 / 输出与保留 / 诊断 / 更新,分别对应 spec 的 Toolchains / Storage / Diagnostics / Updates 四个 pane。spec 还列了一个 General pane,原型没有任何 General 内容——不要替它编设置项,也不要画一排空的 pane 切换器凑数。
「导出诊断包…」打开一个 sheet:`Card` 承载,底部两枚 `Button`。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

卡片一「HDC 工具」,用 `RadioGroup`(name `hdc`,label `HDC 工具`,当前值 `deveco`):
- `DevEco SDK — …/toolchains/hdc · 3.1.0e`(路径与版本 mono)
- `手动选择 — /usr/local/bin/hdc · 3.0.0b`(mono),description = `(SHA-256 已计算 · 能力需重新探测)`

卡内 `Callout tone="warn"` + `Symbol name="warning" small`:
`有任务正在运行:切换不影响运行中的 Job——工具在 Job 创建时固化,仅新任务使用新选择。`
(没有运行中任务时,同一位置退成一行灰字:`切换不影响运行中的 Job:工具在 Job 创建时固化。` 本稿画有任务在跑的那一态。)

卡片二「输出与保留」,`KeyValueList`:
| 输出根目录 | ~/Library/Application Support/ArkDeck |
| 历史配额 | 20GB · 保留 90 天 · pinned 除外 |
| 当前占用 | 6.4GB · 42 个 Session · 3 pinned |

卡片三「诊断」:
正文 `诊断包由你主动导出,默认不含设备 raw 产物,导出前可预览勾选;无自动上传。`(「不含」加粗)
按钮 `导出诊断包…`

卡片四「更新」:
- 勾选框(已勾)`自动检查已签名更新`
- 灰字 `只获取签名 feed；下载后先校验身份与完整性，明确同意后才在 Finder 中显示安装包。`
- `Chip tone="ok"` `✓ 当前已是最新版本` + `Button` `立即检查`(按下后原地变成禁用的 `已检查 · 当前版本`)

诊断包 sheet:
标题 `导出诊断包`
灰字 `逐项勾选导出内容;默认不含设备 raw 产物。该包只保存到本机,无自动上传。`
四个勾选项:
- ☑ `ArkDeck 应用日志(近 7 天)`
- ☑ `工具链探测记录(hdc 版本/hash/endpoint)`
- ☑ `设备清单(connectKey 已脱敏)`
- ☐ `设备 raw 产物(默认不含,可能包含敏感内容)`
底部:`取消` + primary `导出诊断包`

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **工具链切换只影响新 Job。** RadioGroup 旁那句不是提示语,是这一页的主要事实:正在跑的 Job 用的是它创建时固化的那个二进制,切换不追溯、不重启、不影响它。所以这张卡里不能出现「应用并重启」「立即生效」这类按钮——选中即选择,生效点在下一个 Job。有任务在跑时这句话升级成 warn `Callout`,因为此刻它才真的会被误读。
2. **手动选择那一项的代价写在选项里。** `SHA-256 已计算 · 能力需重新探测` 属于 description,不进 tooltip、不移到卡片尾注:读者正在做选择,代价就该在这一行。「已计算」与「需重新探测」是两件事,不要合并成一句「已验证」。
3. **Storage 的五项事实(root / quota / retention / pinned / 当前使用量)必须都在,但只有三行。** 配额行同时带 retention 与 pinned 例外,占用行同时带 Session 数与 pinned 数。照三行画,不要为了对齐 spec 的五个词拆成五行、再给空出来的行编数值。
4. **诊断包三件事同框:默认不含设备 raw、逐项可预览勾选、无自动上传。** 三条缺一不可,而且各说各的:「默认不含」不是「不能含」,所以设备 raw 那一项存在且可勾,只是默认不勾并带自己的风险说明;「可预览勾选」意味着清单在导出前完整摊开,不是导完再看;「无自动上传」是这一页唯一提到网络的地方,它说的是「没有」。
5. **更新走的是已实现的签名流程,顺序不能省。** 只取签名 feed → 先校验身份与完整性 → 明确同意后才在 Finder 中显示安装包。自动的只有「检查」这一步;不要画一键安装、静默安装或自动安装开关。

**不要做的事**:不要把 Settings 画成 sidebar 的第八个 `NavItem`(原型把它内嵌进主窗口只是原型便利,入口按钮的 title 自己写着「设置(原型中内嵌展示)」);不要用 `DangerConfirmDialog` 做诊断导出 sheet——导出是 hostOnly 动作,套危险确认等于把它误分类成不可逆的设备操作(组件表里没有 checkbox,勾选项用原生 `<input type="checkbox">` + label 画);不要画 AC 标注 chip(`AC-DIAG-002-01` 只在原型评审模式里叠加,不进产品);不要发明路径、配额数字或版本号。

---

## 5.9 Automation / Bounded AI Debug Loop

> 贴进 claude.ai/design 项目的新对话。

用 ArkDeck 组件画 **Automation** 页。该页已经是生产工作区：它只监控现有 Harness task，并开放 Runtime 已实现的三个有界生命周期动作；不带 Preview badge。

**当前权威 brief（只画 production wire 已有字段）**:

- Sidebar 的第七项是 Automation，正常导航样式，不带 Preview / planned badge。`HTASK-*` 是 Runtime task ID，与 Git `TASK-*` 无关。
- 内容使用两栏 `HSplitView`。左栏是 Runtime 返回的 task list：lifecycle symbol + 文字、active round、HTASK ID、goal；右栏是所选 task 详情。
- 详情顶部依次显示 lifecycle、stage、type 与 goal；Facts 区只显示 task ID、target ID、round、version、updated UTC，以及有值时的 active Job ID / wait reason。
- Allowed operations 区只读显示 Runtime 返回的字符串；空数组显示明确空态，不把它变成按钮或输入。
- 动作固定为 `Reconcile`（primary）、`Pause`、`Cancel`（destructive），分别映射 `task.reconcile` / `task.pause` / `task.cancel`。terminal task 禁用全部动作；waiting / humanRequired 额外禁用 Pause。动作期间禁用重复提交并显示小型 progress。
- 页面底部常驻 boundary callout：App 不能创建 task、提供 human resolution、resume、propose patch、导出 promotion、GC workspace 或管理 capability。失败原因行内显示并可完整阅读。
- toolbar 只有 Refresh。unavailable 显示 Runtime reason + 连接指导；空 list 显示“没有 Automation task”；未选中显示选择提示。
- 不画 Attempts、budgets、conditions、StageTrack 或 HumanActionRequired action，因为这些字段尚未由当前 App facade 投影。不得用 v0.3 演示数据补齐。

**必须画出的语义**:

1. lifecycle 与 stage 是两条独立事实，均使用 Runtime 原文；lifecycle 以 symbol + 文字表达，不只靠颜色。
2. 所有动作都绑定当前选中的完整 HTASK ID；响应若返回不同 ID 或缺字段，整次刷新失败，不拼接局部事实。
3. Allowed operations 是证据，不是 authority 或快捷操作入口。
4. `Cancel` 取消的是现有 Harness task，不等同于任意 Runtime Job 的取消，也不扩大 task 的 allowed operations。
5. 900×600 下仍保留 list / detail 对应关系；键盘焦点和 VoiceOver 先读任务，再读事实、操作和 boundary。

**不要做的事**:不要画 task submit、resume、human decision 文本框、patch 编辑器、预算编辑器、workspace GC、promotion 导出或 capability admin；不要发明 HTASK、target、goal、round、wait reason 或 allowed operation；不要提供 raw command / argv / 远端路径输入。

<details>
<summary>已废止的 v0.3 Automation Preview 候选（仅供追溯，不得用于新设计或实现）</summary>

**布局** — `WindowFrame`,标题 `ArkDeck — OpenHarmony 设备工作台`。
左栏:`DeviceRow` × 2(rk3568-dev / unknown-tablet)+ `NavItem` × 7(Overview · Flash · Debug · UI Dump · Trace · History · Automation,Automation 为当前页)。Automation 的 label 后面跟一枚小 `Chip tone="dim"` `Preview`——`NavItem` 没有 badge 属性,徽标从 label 传进去。icon 用 `Symbol`(`overview` / `flash` / `debug` / `dump` / `trace` / `history` / `automation`),不用 emoji。
内容区自上而下:`RecoveryBanner`(§4.2 的 banner,humanRequired 一项,落在页面内容之前、toolbar 之下)→ 页标题 `Automation` + `Chip tone="planned"` → `StatusStrip` 四格 → `Card`「修复目标」内含 `StageTrack` → `Card`「预算」内含 `BudgetMeters` → 两列并排:`Card`「Attempts」(`DataTable`)与 `Card`「Attempt 2 · Evidence」(`KeyValueList` + `OperationList` + warn `Callout`)。
底部 `JobInspector` 折叠态常驻,`jobs` 为空,摘要读作「没有运行中的任务」。
spec 给 Automation Attempt 留的是三栏 split view;原型用内容区内的两列实现「清单 + 详情」。照两列画即可,但两列的对应关系要显式:Attempts 表第 2 行是选中行(`selectedId`),右卡标题就是 Attempt 2。

**内容** — 逐字使用,不要改写、不要翻译、不要补充:

RecoveryBanner 一项,kind = `humanRequired`:
- 标题 `Automation · HTASK-DEMO-001 · unknown-tablet`
- 正文 `typed HAP deployment 需要一台已授权设备。unknown-tablet 的授权被拒绝或弹窗超时,ArkDeck 不自动重试。`
- `reasonCode` → `E000003`
- `需要你做` → `解锁设备屏幕,在设备弹出的「是否信任此计算机?」中选择「信任」或「始终信任」;若重试无效,再检查设备的 USB 调试开关。`
- `之后回到` → `deploying`
- 按钮 `我已完成上述动作`

页标题:`Automation` + `Chip tone="planned"` `Preview · code-backed candidate`

`StatusStrip` 四格:
- `Runtime task` → `HTASK-DEMO-001 · debugCrash`(mono)
- `Lifecycle` → `Chip tone="warn"` `● running`
- `Current stage` → `patching`
- `Target binding` → `rk3568-dev · rev 4`(mono)

卡片「修复目标」:
正文 `复现并修复设置页启动后闪退；完成 build、typed HAP deployment 与同一设备复验后才允许成功。`
`StageTrack`,stages 固定八项:`initializing` `reproducing` `collecting` `analyzing` `patching` `building` `deploying` `verifying`,`currentIndex = 4`(停在 patching)
尾注 `阶段、lifecycle 与 conditions 是三条正交信息；回退到 analyzing 不会被画成新的成功阶段。`

卡片「预算」,标题右侧 `Chip tone="dim"` `停止条件已固化`,`BudgetMeters` 五条:
| Rounds | 4 / 8 | 50% |
| Wall clock | 07:42 / 30:00 | 26% |
| Artifacts | 18.4 / 64 MB | 29% |
| E1 mutations | 2 / 4 | 50% |
| Model calls | 3 / 12 | 25% |
尾注 `no-progress 0/2 · action retry 0/2。任一预算耗尽即停止并保存 machine reason，不自动扩大预算。`

卡片「Attempts」,`DataTable`,列 = `#` / `Outcome` / `Strategy fingerprint` / `Observation`(第一列与 fingerprint 列 mono):
- `1` · `Chip tone="dim"` `noProgress` · `91ac…74e0` · `crash signature unchanged`
- `2` · `Chip tone="warn"` `● active` · `6f2b…9d18` · `candidate built; deployment pending`(选中行)
尾注 `重复失败由 strategy fingerprint 判断，不因改写 hypothesis 文案而伪装成新策略。`

卡片「Attempt 2 · Evidence」,`KeyValueList`:
| base revision | 7c9e…e218 |
| patch revision | candidate:2 · diff 6f2b…9d18 |
| confirmed | crash=SIGABRT; source guard missing |
| disproved | device offline; package mismatch |
| next readback | launch state + crash signature absent |

`OperationList` 四枚:`workspace.apply-patch@1` `workspace.run-tests@1` `debug.hap@1` `capture.diagnostics@1`
`Callout tone="warn"` + `Symbol name="warning" small`:`只允许上面的 typed operation。raw argv、shell、远端路径和未登记命令在提交前拒绝。`

原型没有内容的三处,如实空着,不要补:spec 还点名 Attempt detail 要展示 ActionRun、evaluation 与 runtime/build Artifact,原型的 Evidence 只有上面五行;spec 的摘要条要 goal / round / elapsed,原型把 goal 放进「修复目标」卡、把 round 与 elapsed 交给 Rounds 与 Wall clock 两条预算,摘要条只有四格;原型这一页复用的是共用的 Flash outcomeUnknown / Trace waiting 两条恢复项——那不是 Harness block,所以本稿改画 §5.9 点名的 humanRequired 项。

**必须画出的语义** — 这几条是本页的存在理由,画错就等于画反:

1. **`HTASK-*` 是运行单元,与 Git 的 `TASK-*` 不是一回事。** 页面上出现的任务标识永远是 `HTASK-DEMO-001`,mono,不缩写、不换前缀、不链去 issue 或 PR。sidebar 那枚 `Preview` 徽标也是这个意思的一部分:这是 Harness 的运行单元视图,不是任务看板。
2. **阶段轨是固定的八段序列,回退不是新阶段。** 八个阶段永远全部画出,当前标记停在 `patching`(第 5 格)。要表达 verifying 未过后回到 `analyzing`,做法是把当前标记退回同一条轨上的第 4 格:不追加节点、不抹掉已走过的阶段、不给回退配成功色。spec 说这条回退用「回向箭头」表达,`StageTrack` 用的是标记回退——两种画法都行,前提是满足同一条不变量:analyzing 不能被画成一个新的成功阶段。若加箭头,它必须落在同一条轨上、指向已存在的 analyzing 节点。
3. **stage / lifecycle / conditions 是三条正交事实,不能压成一个指示器。** `● running` 与 `patching` 各占摘要条的一格。压成一个总状态之后就再也读不出「running 的任务正停在 patching」,更读不出「running 的任务刚退回 analyzing」——而后者恰恰是这一页最需要说清的事。
4. **预算是 consumed / max:接近上限只警告,耗尽才停,并且说得出机器可读的理由。** 五条都写成「已用 / 上限」,进度条允许画确定百分比,因为分母是 host 自己持有的(轮次、墙钟、字节、E1 改动次数、模型调用);设备侧工作没有这样的分母,那里该用 `IndeterminateBar`,绝不编百分比。耗尽时的行为是停止并保存 machine reason,不是弹窗问「要不要加预算」;页面上不能出现任何放宽上限的控件。`Rounds 4 / 8` 与 `E1 mutations 2 / 4` 已过半,画面要读得出「再有两次设备侧改动就触顶」。
5. **Allowed operations 是只读 chip:那是允许清单本身,不是历史记录,更不是输入框。** 不在这四枚里的东西根本无法提交。`@1` 是标识的一部分,不折叠、不美化、不译成中文动词,用 mono 以便和 host 侧登记表逐字符比对。chip 必须与那句拒绝声明同屏——单看四枚 chip 会被读成「用过的命令」,配上声明才读得出「只有这四个能用」。整页不得出现 raw argv、shell、远端路径或任何自由文本命令面。
6. **`humanRequired` 复用 §4.2 的同一个 banner family,理由要具体到 block 类型。** 它摊开三行事实:`reasonCode`(机器可读的 block)、`需要你做`(最小人工动作,不是一句「请检查设备」)、`之后回到`(恢复到哪个 stage,让人知道按下按钮会发生什么)。按钮写「我已完成上述动作」,不写「继续」——人只能为自己做过的事作证。ArkDeck 在这里不自动重试。授权缺失、outcomeUnknown、strategy exhausted、evidence integrity、environment unavailable 是五种不同的 block,各有各的准确文案;原型只给了授权缺失这一种(E000003),另外四种没有文案,不要照着编。

**不要做的事**:不要发明 HTASK 编号、设备名、fingerprint、revision、阶段名或预算数字;不要把 Attempt 的 Outcome 与任务的 Lifecycle 用同一枚 chip 表达(`noProgress` / `● active` 说的是这一次尝试,`● running` 说的是整个任务);不要在底部 Job inspector 里给 HTASK 补一条假的运行中 Job——HTASK 与 Job 是两套单位;不要画 AC 标注 chip(`HarnessTask lifecycle / stage`、`bounded debug loop budgets` 这类只在原型评审模式里叠加,不进产品);不要把「Preview · code-backed candidate」徽标删掉或降级成灰字,它是这一页尚未被接受为 production 的唯一可见证据。

</details>

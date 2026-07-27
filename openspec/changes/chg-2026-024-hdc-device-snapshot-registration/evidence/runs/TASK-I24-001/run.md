# TASK-I24-001 run log

## capture session #1（2026-07-27）— 全序列执行完毕；`observedEmpty` 未取得，其余各格有机器证明

### 授权链

- capture plan **r4**（#651 merge）+ instrument-identity **(D-2)** 决策载体
  （#626 merge）+ r3 重钉（#624 merge）+ r2 计划（#275 merge）。
- 执行者 = 维护者 `lvye` 亲手；**Agent 全程零 HDC 调用、零设备接触、零 raw
  stream 读取**（下文所有结论均由 redacted-manifest 的哈希/字节数与
  operator 转录的结构化探针导出）。
- 本记录**不使 TASK-I24-001 `ready`**，不注册任何 family，不构成 support/
  compatibility/conformance 声明；provenance 的受理以维护者 review/merge 本
  evidence PR 为准。

### 工具与 harness 身份（执行时复核，全部命中）

| 项 | 值 | 判定 |
| --- | --- | --- |
| selected HDC | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc` | (D-2) 钉定路径 |
| hdc SHA-256 | `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` | 命中 r3/(D-2) pin；每份 manifest 的 `toolchain.hdcSha256` 同值 |
| hdc 报告版本 | `Ver: 3.2.0f` | 命中 (D-2) 钉定值（S0 实证，见下） |
| `capture.py` blob / SHA-256 | `47ee62f4486fdb9d2de71422ff69caf75a1ca7b5` / `be66c30e7db6839196f095724d9ee75a59d938a7e1e4ffa1f139e8f3df3760f8` | 命中 r2 pin |
| `test_capture.py` blob / SHA-256 | `dd80592503d6dc29e17c51d13f9beee081af4655` / `466d9e81413a2d99a4d17c16ac6af626b12738c02bbb5babbbf572ff3fe79d97` | 命中 r2 pin |
| fake-only harness 自测 | `Ran 50 tests … OK` | 命中 r2 期望 |
| host | Darwin `26.5.2` / `arm64` | 每份 manifest 一致 |

### server provenance（r4 披露义务，两件事分开陈述）

1. **被观察的 server 由 operator 预先启动**：窗口开始时 `OB-0`（8710
   LISTEN）与 `OB-1`（ps）双向确认**零 HDC server**；operator 随后于
   **2026-07-27 19:51:26 本地（11:51:26Z）** 手工启动
   `hdc -m -s ::ffff:127.0.0.1:8710`（PID `22677`、`ppid=1`、user
   `fuhanfeng`），同刻 `pgrep DevEco` 为空。该 server **不是**独立工作遗留
   的 pre-existing 实例，本记录不作此声称。
2. **harness 自身的 lifecycle 计数为 0**：serverStart / serverStop /
   serverRestart / serverAdoption / subserverLifecycle / deviceMigration /
   deviceMutation / destructive 全部为 0——由封闭 commandId
   （`hdc-version-flag`、`hdc-list-targets-verbose`）、harness 的 argv/no-shell
   契约与稳定的 server 括号联合支撑。

以上两条**不合并**为笼统的「零 lifecycle 效应」结论（r4 stop condition）。

### server 稳定性括号

| 时刻（本地） | PID | 启动时刻 | normalized endpoint |
| --- | --- | --- | --- |
| 窗口前（S0 前） | 22677 | Jul 27 19:51:26 | `127.0.0.1:8710 (LISTEN)` |
| C2 前 20:19 | 22677 | 同上 | 同上 |
| C3 前 20:21 | 22677 | 同上 | 同上 |
| 窗口末 20:29 | 22677 | 同上 | 同上 |

四次观测 PID / 启动时刻 / executable / normalized endpoint 逐项一致。argv 的
`::ffff:127.0.0.1:8710` 与 `lsof` 的 `127.0.0.1:8710` 为同一端点的两种书写
（r4 认定以 `lsof` 为准）。

**偏差 DEV-1（如实记录）**：r2/r4 要求**每次 harness 调用前后**各做一次
`OB-0/OB-1/OB-2`。本窗口实际留存四次括号观测（覆盖窗口首尾与 C2/C3 之前），
**未做到逐调用 8×2 的完整括号**。缓解事实：四次观测跨越 19:51–20:29 全窗口
且逐项一致，期间无任何 server 变化迹象。是否因此降低 `I24-HDC-DEVICE-
PROVENANCE-001` 的受理等级，由维护者裁决；本记录不自行判定为满足。

### 观察序列（UTC 时刻取各步 `redacted-manifest.json` 的 mtime）

| 步 | UTC | 物理状态 | 行 | stdout 字节 | 状态字段 | exit | 耗时 | stderr | selfCheck |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S0 | `11:58:57Z` | — | — | 12 | — | 0 | 16ms | 0 B | passed |
| C0 | `12:01:27Z` | 零设备 | 1 | 56 | `Offline` | 0 | 1372ms | 0 B | passed |
| C1 | `12:13:46Z` | 接入第一台 | 1 | 58 | `Connected` | 0 | 1345ms | 0 B | passed |
| C2 | `12:19:06Z` | 不变 | 1 | 58 | `Connected` | 0 | 1372ms | 0 B | passed |
| C3 | `12:21:52Z` | 接入第二台 | 2 | 116 | `Connected`×2 | 0 | 1358ms | 0 B | passed |
| C3R | `12:23:18Z` | 不变 | 2 | 116 | `Connected`×2 | 0 | 1356ms | 0 B | passed |
| C4 | `12:24:22Z` | 拔掉一台 | 2 | 114 | `Connected`+`Offline` | 0 | 1357ms | 0 B | passed |
| C5 | `12:25:58Z` | 拔掉最后一台 | 2 | 112 | `Offline`×2 | 0 | 1375ms | 0 B | passed |

全部八步 `exitCode 0`、`timedOut false`、`truncated false`、stderr 恒为 0 字节
（SHA-256 = 空串哈希 `e3b0c442…b855`）、`selfCheckPassed true`、
`keyMaterialFound false`、`userPathFound false`。C 步耗时聚集于
1345–1375ms。

### 行文法（由字节账导出，零 raw 接触）

```
<key:32> \t <name:空> \t USB \t <state> \t localhost \n
```

- `Offline` 行 = 32+1+0+1+3+1+**7**+1+9+1 = **56** 字节；
- `Connected` 行 = 同式，状态 **9** = **58** 字节；
- 实测总字节 56 / 58 / 58 / **116 = 2×58** / 116 / **114 = 58+56** /
  **112 = 2×56**，逐格与行式相加吻合 → **无隐藏内容，两个 key 均为 32 字符**；
- 制表分隔列数恒为 **5**；第 2 列（设备名）在两台设备上均为空；
- 状态取值域本窗口所见 = { `Connected`, `Offline` }；传输恒 `USB`；
  主机标签恒 `localhost`。

### 六项机器证明（哈希级，非观感）

| 证明 | 命令 | 结果 |
| --- | --- | --- |
| S0 内容唯一确定 | 以候选串重建 SHA-256 | `sha256("Ver: 3.2.0f\n")` = `baa9ba96…0f93` = manifest 记录值；12 字节吻合 |
| appeared 为原地翻转 | `sed 's/Connected/Offline/' C1` | = `7e2ba1ca…36c3` = **C0 哈希**，逐字节相等 |
| 重复观察稳定 | C2 manifest sha256 | = `d8816e41…9c48` = **C1 哈希**，逐字节相等 |
| 多行重复稳定、行序稳定 | C3R manifest sha256 | = `b8bed987…6842` = **C3 哈希**，逐字节相等 |
| disappeared 为原地翻转 | `sed 's/Offline/Connected/' C4` | = `b8bed987…6842` = **C3 哈希** |
| 全部离场仍为原地翻转 | `sed 's/Offline/Connected/' C5` | = `b8bed987…6842` = **C3 哈希** |

附：C3/C3R 的 `sort` 后哈希与原文哈希相同，即该对样本的输出顺序恰为字典序。
**单一样本，不推广为规则**；行序按 r2 仍只作呈现性事实，不得作身份依据。

### 主要发现（对 family 设计有直接影响）

1. **「零设备」≠「零行」。** `list targets -v` **从不删行**：设备离场只是把
   状态原地翻成 `Offline`（C4/C5 两条 `sed` 还原证明），而 server 记住它见过
   的每一台（C5 两行 ≠ C0 一行）。因此在一个见过设备的 server 上，靠拔线
   **不可能**观察到零行。
2. **`observedEmpty` 需要重新定义**为「零 `Connected` 行」，`Offline` 行是
   「已知但不在场」。`I24-HDC-DEVICE-EMPTY-001` 现文写作「registered
   successful **zero-row** family yields observedEmpty」，与上述实测不相容，
   需在后续 revision 中处置（本 evidence 不改 AC）。
3. **未被推翻、但也未被证实**：本窗口**不能**得出「零行输出不存在」。C0 是在
   一个**已经见过第一台设备**的 server 上采得（server 起于 19:51:26，彼时设备
   仍连接），因此 C0 不是「从未见过设备的 server」观察。零行是否存在，需要
   另一次窗口：**先在零设备状态下启动 server，再立刻观察**（r4 已授权
   operator 在窗口前启动 server，无需新修订）。
4. **appeared / disappeared 结构同构**：两者都是行内状态字面量翻转，key 与行序
   不变、行不新建不删除。transition 的判据应建立在「同 key 行的状态迁移」上，
   而不是行的出现/消失。
5. **parameterization 成立**：多设备表现为同一行式的 N 次重复（116 = 2×58），
   行边界为换行、字段边界为制表符，可表述为闭合有界文法。

### change-local AC 现状（本记录只陈述观察，不判定 change 级通过）

| AC | 本窗口结论 |
| --- | --- |
| `I24-HDC-DEVICE-SNAPSHOT-001` | one / many / stable / order 四格有机器证明；zero（零行）**未取得**；duplicate/adversarial 属实现期契约面，本窗口不涉及 |
| `I24-HDC-DEVICE-EMPTY-001` | **未满足**：零行族未观察到；且现 AC 文本与实测语义不相容（发现 2/3） |
| `I24-HDC-DEVICE-PROVENANCE-001` | 源哈希、工具身份、稳定括号齐备；**但括号非逐调用**（偏差 DEV-1），受理等级由维护者裁决 |
| `I24-HDC-DEVICE-REGISTRY-001` | 未涉及（实现期） |
| `I24-HDC-DEVICE-NODISPATCH-001` | Agent installed-HDC / device / network / server-lifecycle / mutation / destructive dispatch **= 0**；本窗口的 HDC 调用全部由 operator 亲手经 harness 发出 |

### (D-2) 义务履行

- 本次采集的工具版本 **`3.2.0f`** 已在上表钉定并贯穿本记录；
- **工具版本差异声明**：本 family 的观测来自 hdc `3.2.0f`，与
  `integrations/openharmony/readonly-probes.yaml`（`toolContext` 及其内嵌
  版本串的条目 ID）、`trace-probes/1.0.0/`、`profile.md` 与
  `verification/hardware-matrix.md` 所登记的 `3.2.0d` **非同一工具**；后续
  registry / `INTEGRATION-PROFILES` lock / 条目命名必须显式携带 `3.2.0f`，
  不得与 `3.2.0d` 同胞条目混编。

### 隐私与仓库安全

raw stdout/stderr、完整 manifest、`OB-*` 原文、绝对用户路径与设备标识符
**全部留在仓库外** `~/i24-capture`（0700）。本记录只含哈希、字节数、行/列数、
固定非敏感字面量（`USB`/`Offline`/`Connected`/`localhost`）与动态字段**长度**
（key = 32 字符）。discovery stdout 按 r2 一律视为含标识符，Agent 未读取任何
一份。

### 其余偏差（如实记录；编号用 `DEV-*`，与 instrument-identity 决策的 `(D-1)…(D-4)` 区分）

- **DEV-2（Agent 方法错，已更正）**：起草 r3 时以 `strings` 静态提取判定 hdc
  版本为 `3.0.0b`（实为 handshake 协议常量），据此误判为「降级」；经维护者
  实测 `hdc -v` = `3.2.0f` 推翻。根因与通用规矩已写入 capture-plan r3。
- **DEV-3（Agent 方法错，已更正）**：C0 结构探针出来后，Agent 以字段长度
  9 推断状态为 `Connected` 并宣布窗口终止；实为 `Offline`（长度同为 9 的
  `localhost` 才是第 5 列）。经 operator 打印第 2–5 字段推翻，窗口恢复执行。
  教训：字段长度不能替代字段取值。
- **DEV-4（Agent 输出事故）**：一次汇报命令块尾部混入 `</parameter>` 杂质，
  zsh 整行 parse error、零执行（与 TASK-MPF-001 attempt#1 同型复发）。已重发
  纯净命令，无状态影响。
- **DEV-5（操作面）**：`OB-1` 的初版识别用 `grep hdc`，命中 1Password 扩展 ID
  `aeblfdkhhhdcdjpifhhbdiojplfjncoa` 产生假阳性。已由 r4 新增 `OB-0` 与
  executable 级精确匹配修复，本窗口按修复后判据执行。

### human attestation（维护者 2026-07-27 确认，齐备）

- operator：`lvye`；窗口 UTC 区间：`11:51:26Z`（server 启动）–
  `12:25:58Z`（C5）。
- **A（2026-07-27 维护者确认）**：全部设备插拔由 operator `lvye` 亲手完成；
  窗口期间**未开启 DevEco、未运行第二个 HDC 客户端、未对 server 做任何
  lifecycle 动作**。
- **B（2026-07-27 维护者确认）**：C4 拔除的是**第二台**设备（即 C3 时后接入
  的那台）；因此 C4 的 `Connected` 行对应第一台、`Offline` 行对应第二台，
  C5 再拔第一台后两行皆 `Offline`。行与设备的对应关系仅存在于仓库外的
  controlled session，本记录不载任何标识符。
- `accepted-by: pending maintainer evidence-PR review`。

### 后续

1. 本 evidence PR merge = provenance 受理（attestation 已齐备）；
2. 另开一次**虚拟机式最小窗口**确定零行是否存在：零设备状态下启动 server →
   立即一次 `list targets -v`；
3. 依据发现 2/3 起草 **r5**：重定义 `observedEmpty` 与
   `I24-HDC-DEVICE-EMPTY-001`，并把「拔线不等于消失」「transition 以同 key 行
   状态迁移为判据」写入 design；
4. 其后才是 TASK-I24-001 的 readiness（registry/fixture/lock/test matrix）。

---
id: CHG-2026-024-hdc-device-snapshot-registration
revision: 6
status: verified # 2026-07-28 本 verification-closure PR；closure 段见文末
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Register a parameterized HDC device-observation snapshot family

## Why

CHG-2026-022 r2 已由维护者合并（PR #268，merge
`35a8aee2026daaa12ce2c7de91eb5d3fd77277cc`），并把 TASK-OBS-001 恢复为
`blocked`。其首项解除前置要求一个独立 approved/done integration change，注册
parameterized zero-to-many 只读设备 snapshot family 并同步 macOS mapping。

当前 `OPENHARMONY-HDC-READONLY-PROBES@1.0.0` 的
`selectedDeviceAuthorizationBinding` 只允许 exact `list targets -v` capture 与一个
既有 durable binding identity/revision 精确匹配。它不能表示任意设备集合、成功的
empty snapshot、周期 observation 或 disappearance；不同 row 即使匹配另一个 binding
也必须返回 unknown。把该 family 直接当设备枚举会绕过 CHG-2026-015 的 registry、
provenance 和 authority boundary。

本 change 只注册一个独立、版本化的 device-observation integration input。它不接入
production App、不实现 fan-out、不改变 binding/authorization，也不执行 Agent/CI
真实 HDC 或设备命令。

## What changes

### In scope

- 新增独立 registry `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`，目标
  integration profile 为 `OPENHARMONY-TOOLS@0.4.0`；现有
  `OPENHARMONY-HDC-READONLY-PROBES@1.0.0` 保持 byte-identical；
- 登记 `deviceObservationSnapshot` family：exact argv、selected executable identity、
  exact endpoint、valid bracketed existing-server identity、bounded stdout/stderr/exit、
  parameterized zero/one/many row grammar、typed empty/snapshot/unknown、timeout、
  cancellation、effect 与 provenance；
- authoritative inputs 必须覆盖成功 empty、single-row、multi-row、稳定重复、出现和
  消失序列。raw connect key/serial/用户路径不入仓；受控 raw 留在维护者位置，仓库只
  保存 hash、长度、row count、脱敏结构 receipt 和 accepted-by；
- whole-output fail closed：任一未登记 column/state/transport、duplicate identity、
  mixed failure marker、stderr、nonzero exit、truncation、identity/endpoint drift、timeout
  或 cancellation 使整份 snapshot 为 unknown，不能把 unknown 当 empty；
- snapshot 只建立“本次 registered observation 中出现的设备 pseudonym set”。它不能
  选择 default target、创建/修改 durable binding、证明 authorization/channel
  protection、推断物理拔出原因，或授权任何 device/lifecycle/subserver mutation；
- bump Integration profile/lock，并同步 macOS profile 的 family mapping；新增 versioned
  redacted receipt/control resource 与 contract tests，固定 registry/profile/lock/resource
  hash closure；
- 完成后只为 CHG-2026-022 后续独立 readiness 提供 integration input。production
  producer、轮询 cadence、fan-out、presentation 与 App UI 仍归 CHG-2026-022。

### Out of scope

- 修改 `Packages/ArkDeckKit/Sources/**`、`ArkDeckApp/**`、Core specs/contracts/schema、
  CHG-2026-022 状态或其 implementation；
- 改写/替换既有 read-only registry、CHG-015 evidence、CORE-2.1.0 conformance pins；
- Agent/CI 执行 installed HDC、访问真实设备、启动/停止/restart/adopt HDC server、执行
  subserver/device/destructive mutation 或非 loopback 网络；
- 把 plug/unplug capture 当硬件支持、release、authorization 或 binding evidence；
- 用 agent-authored fake bytes、宽松正则、exit 0、connect-key shape 或 caller assertion
  将 family 提升为 supported。

## Observable behavior before/after

- Before：没有 production-authoritative arbitrary-device snapshot family；任意集合与
  empty/disappearance 只能 unknown。
- After registration done：版本感知 consumer MAY 读取封闭
  `deviceObservationSnapshot` entry；仅完整 precondition/provenance/grammar 满足时得到
  typed empty 或 pseudonym set，其他结果继续 unknown。registration 本身不产生事件，
  不让 CHG-2026-022 自动 ready。

## Scope

- Canonical Core Requirements/AC claimed:none
- Integration input:`OPENHARMONY-TOOLS@0.3.0` +
  `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`（只读基线）；candidate
  `OPENHARMONY-TOOLS@0.4.0` +
  `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`
- Change-local acceptance:`I24-HDC-DEVICE-SNAPSHOT-001`、
  `I24-HDC-DEVICE-EMPTY-001`、`I24-HDC-DEVICE-PROVENANCE-001`、
  `I24-HDC-DEVICE-REGISTRY-001`、`I24-HDC-DEVICE-NODISPATCH-001`
- Core baseline bump:no

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | integration mapping candidate; no conformance transition | 需要 exact 3.2.0d controlled capture 与后续 consumer readiness |
| Windows | deferred / unchanged | port 未启动，无 capture/support 声明 |
| Linux | deferred / unchanged | port 未启动，无 capture/support 声明 |

## Safety, privacy, and compatibility

- 新 registry 是独立 allowlist，不修改已被 M1-006/Core conformance pin 的 1.0.0
  registry；旧 consumer 保持 0.3.0 行为；
- command entry 必须要求 independent existing-server receipt；server absent 或 identity
  drift 时不得通过执行 command 探测安全性；
- raw identifiers 只在 observation process 内短暂存在。consumer adoption 必须用
  session-scoped keyed pseudonym；持久日志、presentation、receipt 和 repository 禁止
  raw connect key/serial；
- successful empty 是 authoritative registered output，unknown/failure 永不等价 empty；
- rollback 是独立 revert registration implementation PR；不删除旧 registry/evidence，
  CHG-2026-022 保持 blocked。

## Approval and flow

本 proposal PR 只创建 change package，零实现、零 capture、零 evidence、零设备命令。
批准须独立 approval-only PR；TASK-I24-001 初始 blocked。维护者提供并 review 受控
capture/provenance 后，另起 readiness PR；implementation+evidence、`ready→done`、
change `verified` 与 CHG-2026-022 adoption/readiness 均使用独立 PR。

## Approval

- r1 proposal 经 PR #272 合入 main（squash `cdfc181`，`status: proposed`）。
- 正式批准：2026-07-21 由本 approval-only PR（先例 #55/#89/#171/#195/#226/
  #253/#254/#266）将本 change 置为 `approved`；批准由维护者 review/merge 本 PR
  构成。merge 即批准：
  - **单任务 scope 与边界**：TASK-I24-001 只登记独立、版本化的
    `deviceObservationSnapshot` integration input、同步 profile/lock/macOS mapping 并
    提供 contract/evidence closure；production producer、轮询 cadence、fan-out、
    presentation 与 App UI 仍归 CHG-2026-022，既有 readonly registry、Core 与
    production Sources 保持在 forbidden scope；
  - **design 硬边界**：existing-server-only 与稳定 pre/post identity/endpoint bracket，
    whole-output fail closed，successful empty/snapshot/unknown 严格区分且不发 partial
    set；session-scoped keyed pseudonym、raw identifiers/streams 留仓库外；零 server
    lifecycle/adoption、subserver/device/binding mutation 与 destructive effect；
  - **验收面**：五条 change-local AC（I24-HDC-DEVICE-SNAPSHOT/EMPTY/PROVENANCE/
    REGISTRY/NODISPATCH-001）；canonical Core AC 零认领、Core baseline 不升版，macOS
    mapping 不产生 platform conformance transition。
- 本批准不产生任务执行：TASK-I24-001 保持 `blocked`，仍须维护者受控 capture/
  provenance 经独立 PR review/merge，并由独立 readiness PR 完整重钉 inputs、hashes、
  scope 与 test matrix 后才可转 `ready`。本批准不构成 HDC/设备支持、authorization、
  binding、hardware/release evidence，也不会使 CHG-2026-022 自动 ready。

## Revision 2 — controlled capture execution plan

- r2 只把 `capture-plan.md` 从概念矩阵收紧为可独立 review 的 human execution plan：
  固定复用既有只读 allowlist harness、instrument blob/hash、C0–C5+C3R 顺序、每次
  observation 的 server identity/endpoint bracket、repo-safe handoff 字段与 stop
  conditions；不新增或修改 capture tool。
- r2 不执行 installed HDC、不访问设备、不登记 registry/resource、不生成 provenance，
  也不改变任何 task 状态。只有维护者 review/merge 本 r2 治理 PR 后，维护者本人才能
  按该计划执行 capture；随后仍须独立 evidence PR 与 readiness PR。

## r3 注记（2026-07-27，instrument drift；原文如实保留不改写）

r2 `capture-plan.md` 钉定的 selected HDC（`Ver: 3.2.0d` / SHA-256
`48395ba8…d260`）已不在维护者主机；当前唯一副本 SHA-256
`05b2bf7a…a68f83`（6,016,944 bytes），维护者 2026-07-27 实测 `hdc -v` =
**`Ver: 3.2.0f`**（相对 r2 钉定值为常规补丁升级 d→f）。

**一处已更正的方法错误如实入档**：Agent 起草时以 `strings` 静态提取得到
`Ver: 3.0.0b` 并据此误判为「降级」；该字面量实为 handshake/auth 协议常量，
真实版本由 `%x.%x.%x%c` 运行时拼装、在二进制中无文本形态。规矩：`strings`
所得版本字面量不构成工具报告版本的证据。

r3 因此把 capture plan 置于一个**未解即不得开窗**的 instrument-identity
decision 之下：(D-1) 恢复 3.2.0d 按 r2 原文执行（代价 = 刻意固定在更旧工具）；
(D-2) 在 3.2.0f 上采集并接受双版本 profile，此时 registry/lock/条目命名必须
显式携带 `3.2.0f` 且 evidence 必须写明与 `readonly-probes.yaml`/`trace-probes`/
`profile.md`/`hardware-matrix` 所登记 3.2.0d 的差异；(D-3) 暂缓，TASK-I24-001
保持 `blocked`；(D-4) 另立独立 change 先把整个 openharmony profile 从 3.2.0d
迁到 3.2.0f，其后本采集与全 profile 同源（代价最高、结果最干净）。

本 revision 不改变采集方法论（该计划本就是 falsifiable 判定而非预设结论），
只更换被判定的对象并新增上述 gate 与两条 stop condition。TASK-I24-001 仍
`blocked`；本 PR 合入不构成 ready，也不接受任何 provenance。

## r4 注记（2026-07-27，窗口内 existing-server 前提触发；原文如实保留）

窗口开启时 `OB-0`(8710 LISTEN)与 `OB-1`(ps)双向确认**零 HDC server**，
故 r2/r3 的 existing-server 前提当场 FAIL；随后 operator 手工启动了
server(PID `22677`、`hdc -m -s ::ffff:127.0.0.1:8710`、`ppid=1`、
`lsof` 归一 `127.0.0.1:8710`，同刻无 DevEco 进程)。r2/r3 原文禁止
「为让前提通过而启动 server」，故不能默许。

r4 把该禁令的**实质**保留、形式改为**披露义务**:允许 operator 在窗口前于
harness 之外启动 server 并记录其来源/时刻/方式/身份；窗口期间的任何
lifecycle 动作仍然禁止；evidence 必须逐字披露该 server 系 operator 为本
窗口启动，并把「harness 零 lifecycle 计数」与「server 系预先启动」**分开
陈述**，不得合并为笼统的零效应结论。理由:本 family 要证的是采集本身不产生
lifecycle 效应且观察对象是已在运行的 server；server 由 operator 于窗口前
启动与由 DevEco 数日前启动，对该主张无实质差别——真正要防的是悄悄制造前提。

r4 另修一处检测缺陷:`grep hdc` 会命中 1Password 扩展 ID
`aeblfdkhhhdcdjpifhhbdiojplfjncoa`(实测假阳性)，故新增 `OB-0` 并要求
executable 级精确匹配。TASK-I24-001 仍 `blocked`；本 PR 合入不接受任何
provenance。

## r5 注记（2026-07-27，virgin-server 零行观察；原文如实保留）

采集会话 evidence（#656 merge `af6d64d`）证明零行在见过设备的 server 上
不可达，同时明确未证明零行不存在。r5 单次授权 **V0 窗口**：operator 于窗口前
确认零设备、以普通 `kill`（非 `hdc kill`）停止现役 server `22677`、双向确认零
server、在零设备状态下启动新 server，随后以 harness 采集**恰好一次**。判据二值：
零行则零行族存在（并声明其成立条件为 server 未见过设备），非零行则
`observedEmpty` 必须改以「零 `Connected` 行」定义。

**r5 不修改任何 AC**——`I24-HDC-DEVICE-EMPTY-001` 的重定义留待 r6，取决于 V0
实测结果；先改 AC 再观察是本末倒置。新增一条披露义务（被停 server 的 PID 与
时刻）与三条 stop condition。TASK-I24-001 仍 `blocked`。

## r6 注记（2026-07-27，按实测重定义 empty 语义；原文如实保留）

r5 把 AC 重定义推迟到实测之后。两次窗口的 evidence（#656 merge `af6d64d6`、
#658 merge `6df25c25`）给出三态：virgin server 输出 `[Empty]` 标记行
（9 字节、0 制表字段、**CRLF**，内容由 sha256 反证唯一确定）；见过设备但当前
无在场，输出 N 行状态全 `Offline`；有在场设备则含 `Connected`。设备离场从不
删行，只是原地翻转状态（`sed` 归一化后与在场快照哈希逐字节相等）。

据此 r6 做四件事，**不扩任何 scope**：

1. `I24-HDC-DEVICE-EMPTY-001` 由「registered successful zero-row family」改为
   **`observedEmpty` = 零 `Connected` 行**，两种已登记成功形态（marker 行 /
   全 `Offline` 行集）均满足；marker **充分不必要**，只认 marker 的实现必须
   在该 matrix 上失败——因为见过设备的 server 永不再输出它。
2. `I24-HDC-DEVICE-SNAPSHOT-001` 增加 grammar 硬要求：同时接受 LF 与 CRLF，
   任何字段不得残留 `CR`。
3. design §3 补记实测的行终止符风险与其静默失败路径，并在反模式清单新增两条
   （「无 marker 即非空」「拔线视为删行」）。
4. acceptance-cases 同步该 expected_result。

零新增任务、零 scope 扩张、不触碰工具选择与既有 pin；TASK-I24-001 仍 `blocked`
（其 readiness 为下一步）。

## Verification closure（2026-07-28）

单任务 TASK-I24-001 done 于 protected main 在案；五条 change-local AC 的证据
可复查。本 PR 仅状态翻转 + 引用，零实现夹带（先例 #224/#239/#570/#601）。

- **任务链（十四 merge）**：propose #272 `cdfc181f`；approval #273
  `1eeb5168`；capture plan r2 #275 `c8d9ba27`、r3 #624 `46ebcc22`、
  (D-2) instrument 决策 #626 `36af5533`、r4 #651 `180367fc`、r5 #657
  `98d1f885`、r6 #659 `6e45a224`；capture evidence #656 `af6d64d6`（session
  #1，S0+C0–C5）与 #658 `6df25c25`（V0 virgin server）；readiness r1 #662
  `88465abc` 与 r2 #663 `04afc7cf`；实现 #664 `ffca996f`；done #665（本
  closure 之前的独立 flip PR）。
- **`I24-HDC-DEVICE-SNAPSHOT-001` = PASS**：注册文法闭合有界（制表 5 列、
  transport/state/hostTag 闭合字面量集、LF 与 CRLF 双终止符、字段禁残留
  `CR`）；zero（两形态）/one/many/order/duplicate/adversarial 由 12 个合成
  向量与 13 条契约测试逐项覆盖；无部分集合。
- **`I24-HDC-DEVICE-EMPTY-001` = PASS**（r6 定义）：`observedEmpty` = 零
  `Connected` 行，marker 行与全 `Offline` 行集双形态命中；`[Empty]` 带残留
  `CR`、零字节 stdout 均判非空；10 条非 stdout 控制（stderr/非零/截断/
  timeout/cancel/server 缺席/endpoint 漂移/身份漂移/编码非法）无一产生
  empty 或消失事件。
- **`I24-HDC-DEVICE-PROVENANCE-001` = PASS**：两次受控采集的来源哈希、工具
  身份与稳定 server 括号在案，raw 全留仓外，`repositoryGoldenFixture:
  false`。受理含 r1 记录的 DEV-1 裁定（括号 4 次而非逐调用，理由与接受方式
  写在 r1，维护者以 merge 裁定）。
- **`I24-HDC-DEVICE-REGISTRY-001` = PASS**：profile `OPENHARMONY-TOOLS@0.5.0`
  / registry `@1.0.0` / lock `INTEGRATION-PROFILES-0.6.0` / resource 清单 /
  macOS mapping 版本与 hash 闭合一致；旧 `readonly-probes.yaml` 与
  `Probes/1.0.0/**` invariant 逐字节未变，旧消费者零新增权威。
- **`I24-HDC-DEVICE-NODISPATCH-001` = PASS**：注册与 Agent/CI 侧 installed
  HDC / device / network / server lifecycle / adoption / subserver / device
  mutation / destructive dispatch **全为 0**；窗口内的全部 HDC 调用均由
  operator 亲手经受控 harness 发出。
- **工具版本差异已登记**：本 family 观测自 hdc `3.2.0f`，与 readonly-probes /
  trace-probes / hardware-matrix 登记的 `3.2.0d` 非同一工具；条目 id 携版本
  且有测试禁止混编（(D-2) 义务履行）。
- **遗留（不阻 verified，如实带入 archive）**：canonical registry 与 bundled
  副本的字节一致守卫无自动化，其载体属 `scripts/**`（本 change 未授权）；
  当前由 lock 相邻两个 SHA-256 与 review 兜底，建议下次授权 `scripts/**`
  时补齐（与 HDC/Trace 同族既有遗留同型）。
- **不声称**：CHG-2026-022 消费侧的 cadence/fan-out/presentation 仍在其自身
  readiness 之后；本 change 不实现也不批准该消费者。

## Archive 暂缓（2026-07-28，实测断链；AF-006 同型，先例 chg-015 / chg-030 #573）

verified 后即做归档前引用扫描，**命中两处目录外精确路径引用**，故按
「archive 前引用扫描命中即暂缓」规矩不入 `archive/`：

| 引用方 | 引用内容 | 性质 |
| --- | --- | --- |
| `openspec/integrations/openharmony/device-observation-probes.yaml` | `entries[].provenance.sourcePath` = `openspec/changes/chg-2026-024-hdc-device-snapshot-registration/evidence/runs/TASK-I24-001/run.md` | **活体生产输入**，且其 SHA-256 被 `INTEGRATION-PROFILES.lock.yaml` 钉死 |
| `Packages/.../Fixtures/HDC/Probes/DeviceObservation/1.0.0/registry.yaml` | 同上（bundled 逐字节副本） | 测试 pack，SHA-256 亦被 lock 与 `resources.json` 钉死 |

`git mv` 会使这两处路径失效。而修正它们会改变两个文件的字节 → 连带
`INTEGRATION-PROFILES.lock.yaml` 的两条 SHA-256、pack 的 `resources.json`
以及契约测试的哈希断言全部级联失效，属超出「archive = git mv + status 翻转」
的改动面，不应夹带在归档 PR 内。

**根因（自陈）**：TASK-I24-001 的 registry 用**精确仓内路径**表达 provenance。
同一 `provenance` 块其实已经携带更稳定的标识
（`sessions[].mergeOID` = `af6d64d6…` / `6df25c25…`，以及 `acceptedBy` 的
PR 号），路径字段属冗余且是唯一的断链源。既有同族先例
（`readonly-probes.yaml` 指向 `changes/archive/...` 的已归档路径）说明
「归档后再更新路径」可行，但那需要一次显式的、跨 integrations/Packages/lock
的协调改动。

**两条收口条件（任一满足即可归档，均须独立立项）**

1. **provenance 去路径化（推荐）**：新起一个小 change，把 registry 的
   `sourcePath` 改为 archive-stable 形态（保留 `mergeOID` + task id，或以
   `archive/`-agnostic 的 change id 引用），同步更新 bundled 副本、lock 两条
   SHA-256、`resources.json` 与契约测试哈希。此路线对**将来每一个** registry
   都有效，不只解本次。
2. **协调式归档**：在一个显式授权的 change 内，把 `git mv` 与上述四处 hash
   级联更新一起做完并逐项取证。代价更高且一次性。

在此之前本 change 以 `verified` 状态留在 `openspec/changes/`，作为已记录的
决定而非遗漏。

**扫描方法更正（同日实测教训）**：首轮扫描误报"零命中"，因为过滤写成
`grep -rn … | grep -v "<change dir>/"`——`grep -rn` 的输出是
`路径:行号:内容`，**内容里**含该路径的行也被 `-v` 滤掉了。正确形态是
`grep -rl … | grep -v '^\./<change dir>/'`（按**文件路径**过滤，不按行内容）。


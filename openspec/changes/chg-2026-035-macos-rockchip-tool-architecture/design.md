# CHG-2026-035 Design — macOS Rockchip 工具执行架构决策

## Context and constraints

- Approved proposal revision：尚无；r1 仅在 proposal PR 合入后登记为 `proposed`。
- Core baseline：`CORE-2.1.0`，零 Core delta。
- Related authority：ADR-0002、DEC-004、DEC-007、macOS platform profile、
  flashing/workflow/desktop UX current specs、CHG-2026-026 r9 与
  `TASK-RKFUI-001G` merged blocked run。
- Trigger fact：#525 记录 exact product six-entitlement Stage A 在
  `selectedEntryNotRegularFile` 停止；bookmark/Process/Stage B/real tool/USB/device
  dispatch 均为 0。candidate envelope 的 pre-bookmark boolean 还存在不真实表达，
  因此不能从该 candidate 推断更晚阶段能力。
- 本 change 解决“下一架构应是什么”，不解决“如何让 001G 再跑一次”。候选选择、
  评估事实与后续实现必须保持三个独立层次。

## Requirement mapping

| Requirement / AC | Decision concern | Verification |
| --- | --- | --- |
| `REQ-FLASH-001` / `AC-FLASH-001-01` | Rockchip Provider 到工具 discovery/launch 的 typed 边界 | option matrix + ADR review |
| `REQ-FLASH-004/005` / `AC-FLASH-005-01` | execute 与 plan-only/handoff 的产品语义不得混淆 | capability compatibility review |
| `REQ-FLASH-015` / `AC-FLASH-015-01` | 架构选择不产生真实设备或 destructive authority | zero-effect diff/run review |
| `REQ-JOB-005` / `AC-JOB-005-01` | fixed typed argv、no shell、semantic process result | authority/effect mapping review |
| `REQ-UX-007` / `AC-UX-007-01` | 不静默安装 helper、提权或修改系统权限 | permission and lifecycle review |
| change-local `RKTA-*` | 比较、结论、边界与 handoff 完整 | documentReview |

## Decision process

### 1. Frozen facts

Readiness 必须 pin 并逐项复核至少以下输入：

- #525 reviewed head、merge OID、blocked run blob 与 sanitized receipt SHA-256；
- ADR-0002、DEC-004/007、macOS profile 与 exact App entitlement blob；
- 适用 current specs/contracts 与 CHG-2026-026 r9 proposal/design/tasks/verification；
- 当前 `rkdeveloptool` registry 的 tool/version/hash/upstream provenance；
- 决策时使用的 Apple 平台、Developer ID/notarization、XPC/helper 与供应链一手文档
  版本/URL/检索日期。

旧 probe 自报字段、未合入 branch、candidate source、聊天描述或二手博客不得升级为
平台事实。事实缺失时矩阵写 `unknown` 并使相应候选不可选择。

### 2. Candidate envelopes

矩阵必须评估五类完整 end-state，不允许只比较 launch API 名称：

| Candidate | Minimum envelope that must be evaluated |
| --- | --- |
| Selected external tool | canonical selection/identity、bookmark/PowerBox lifecycle、child execution 与 image/key/output access、Gatekeeper/quarantine、clean-host install ownership |
| Bundled Rockchip component | exact source/artifact reproducibility、license/notice/SBOM、universal/arm64 architecture、nested signing/notarization、dependency/USB access、update/CVE/rollback |
| XPC/broker/helper | component sandbox/entitlements、IPC caller authentication、authority minting、tool/file/device access、install/update/remove、crash/cancel/reconcile；privileged 与 non-privileged 分列 |
| Plan-only handoff | typed plan/Artifact 完整性、human command transport、result import/provenance、execute capability loss、support/recovery UX |
| Distribution revisit | 非 Sandbox/dual/other packaging 的 threat surface、全量 revalidation、update/clean-host impact，以及 DEC-004/ADR-0002 reopen path |

组合方案必须作为完整第六行重新评估所有 criteria，不能从两行的局部优点拼接出未经
审查的答案。symlink/alias、copy-to-container、dynamic download、quarantine removal、
unknown re-signing、PATH/shell 都只作为 rejected workaround 记录。

### 3. Binary decision rule

每个候选对所有 mandatory criteria 给出 `pass | fail | unknown | requires-new-change`
及证据引用。只有不存在 `fail/unknown`、且所有 `requires-new-change` 都被写成先于实现
的显式 gate 时，候选才可被推荐。

最终 carrier 只允许两种结论：

1. 选择一个完整 end-state，列出 rejected alternatives、residual risks、
   revalidation triggers、rollback 与后续 change dependency；或
2. 判定当前候选均不可行，保持 Rockchip execute blocked，并精确指出需要维护者重开的
   product/Core/distribution 决策。

“继续探索”“先实现再决定”或“001G 多跑几次”不是有效结论。

## Architecture and data flow

本 r1 不选择 production topology。最终 ADR 必须以 concrete 类型/入口补全以下映射：

```text
ArkDeckApp composition root
        |
        v
typed Rockchip workflow + durable selected binding/plan
        |
        v
single authority/permit minting point
        |
        v
selected component boundary(App process | XPC/broker/helper | human handoff)
        |
        v
fixed executable identity + typed argv + input/output leases
        |
        v
process/device effect dispatch + write-ahead intent/durable outcome
```

若结论为 plan-only/no-viable，映射必须明确 process/device effect dispatch 不存在，且 UI、
manifest/History 不得把 plan 或人工外部结果冒充 ArkDeck execute success。

## Data and contract changes

r1 与 `TASK-RKTA-001` 均不修改 Core contract/schema、manifest、journal、Provider
contract、tool registry 或 hardware matrix。decision matrix 与 ADR 是文档 evidence，
不成为 executable authority。

若最终候选需要新增 IPC schema、helper protocol、bundled-tool manifest、result-import
contract 或 Core observable behavior，ADR 只能列出后续独立 change；不得在本
document-review task 中直接添加或实现。

## Authority and production reachability

本 change 本身为 host-only document review，production composition root、authority
产生点与 effect dispatch 均 `not applicable`：任务不构造产品对象，不启动进程或接触
设备。

最终 ADR 必须逐项回答：

- Production composition root：谁组装唯一 production route，fixture/CLI 为什么不能
  冒充 App reachability；
- Authority minting：用户确认、standing authorization、device binding、tool/file
  capability 分别由谁产生并绑定哪个 revision；
- Effect dispatch：外部进程与设备 effect 在哪里发生，write-ahead intent/outcome 如何
  durable；
- Fake/simulation difference：为什么 fixture/plan-only positive 不会跨入真实 route；
- Facts/provenance：tool identity、签名/公证、bookmark/file lease、device observation
  与执行结果由谁生产，调用方能否同时伪造事实与证明。

## Failure, cancellation, and recovery

- 本任务失败仅产生 blocked document-review run，不触发 fallback 或产品变更。
- 矩阵必须覆盖 selector/bookmark denial、component missing/tampered/quarantined、
  IPC authentication failure、helper unavailable、input lease failure、launch failure、
  timeout/nonzero/partial output、App/component crash、cancel at safe boundary、
  unknown external outcome 与 postflight mismatch。
- 任何真实 effect outcome/identity unknown 的候选都必须保留 current
  `waitingForRecovery`/reconcile 语义；不得用 helper 重启或新进程重放猜测补偿。
- 本任务没有 runtime cancellation/recovery；review 中断后从 pinned inputs 重新开始，
  不把半成品矩阵当作结论。

## Security and privacy

- 默认保持 least privilege、exact six-entitlement product fact与禁止
  sudo/pkexec/静默 helper 安装/系统 rule/group/ACL 修改；若候选要求改变，必须标为
  `requires-new-change`，不能在 ADR merge 时隐式扩权。
- 工具只能由 exact identity/provenance 进入 fixed typed argv；禁止 shell、PATH lookup、
  caller-supplied executable/environment、自动 quarantine/xattr mutation。
- evidence 不保存 bookmark bytes、用户路径、签名 ticket 原文、raw Sandbox log、
  secret、设备标识或外部 binary；只保存版本、hash、boolean、稳定错误与公开引用。
- Bundled/broker 候选必须单独分析 dependency confusion、replacement/tamper、IPC confused
  deputy、TOCTOU、update rollback 与 orphaned helper。

## Alternatives and ADRs

- 本 proposal 不预选候选，也不把 candidate order 表达成偏好。
- 后续 decision carrier 计划新增
  `docs/adr/0003-macos-rockchip-tool-execution.md`，同步
  `openspec/planning/open-questions.md` 与 `openspec/platforms/macos/profile.md`。
- 若选择改变 Sandboxed 单一 DMG，ADR-0003 必须明确触发 DEC-004/ADR-0002 的独立
  reopen/supersession，而不是在本 change 内静默覆盖。
- 若选择 bundled Rockchip component，必须明确它不改变 DEC-007 的“不捆绑 HDC”；
  Rockchip tool 与 HDC 不得合并成一个模糊的“toolchain”决定。

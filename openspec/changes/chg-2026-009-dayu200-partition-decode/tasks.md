# Tasks — CHG-2026-009 DAYU200 partition decode(read-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作、零网络、零 subprocess。

## TASK-PD-001 — parameter.txt 只读解码器 + 映射/对账 evidence

- Status:blocked(r2 revision 已由维护者合入 `main`
  `1f7c10e4fe266c27866e7cec79be8160c1e5ce53`;r1 implementation + FAILED/
  BLOCKED evidence 已合入 `main`
  `45f2b605d0b70b4ea1e20928613fab1153b84563`,不得追溯重判或复用为 passing
  evidence。r2 implementation 已合入 `main`
  `0076e44dcaed45605c1cccefc093a82b246a4ef5`;2026-07-19 fresh rerun 时远程
  macOS host 锁屏,签名 broker 的 NSOpenPanel/PowerBox 无法取得人工文件选择,
  collector 在 create-only publication 前安全取消,三项 AC 均无 fresh evidence。
  此外该合入版仍将强制 DEFLATE sliding history 记为 literal cross-chunk
  retention blocker并生成 `partitionAcceptanceSatisfied:false`;在 r2 AC 对该 codec
  state 的边界经维护者批准澄清/修订、且解锁 host 完成 fresh collector 前不得
  标记 `done`。见
  `evidence/runs/TASK-PD-001/r2-fresh-attempt-2026-07-19.md`;本 blocked 状态仅在
  维护者 review/merge 后生效)
- Revision r3 draft(2026-07-19):仅澄清 application-visible non-target plaintext
  retention 与 gzip-DEFLATE 必需的 opaque 32 KiB codec history 边界；本 revision
  PR 不包含 implementation、fresh evidence、readiness、状态翻转或既有 evidence
  重判。r3 仅在维护者 review/merge 后生效，TASK-PD-001 继续保持 `blocked`；合入
  后仍须独立 readiness PR 固定最小 remediation 与 fresh 三项 AC rerun，且 collector
  运行时 host 必须处于可交互解锁状态。
- Objective:在不改变 r2 AC 的前提下，将 decoder 改为只接受预打开的只读普通
  文件 descriptor，并以独立、最小权限的 macOS App Sandbox broker 建立和直接
  传递该 descriptor；随后对 pinned archive 重新生成映射/对账与全部三项 fresh
  evidence。
- In scope:
  1. fd-only decoder + ≤1 MiB bounded stream-discard、封闭文法、deterministic
     evidence 与 r1 正/负分支回归；production decoder 不接受/解析 archive path，
     首次 read 前 `fstat`，非普通或不可验证只读状态的 fd 零 read fail closed；
  2. 独立 artifact `scripts/partition_decode/macos_input_broker/**`：单独的 macOS
     App Sandbox broker target、closed entitlements/policy、签名/验证脚本与
     descriptor-transfer harness。broker 只经系统用户文件选择取得 archive，
     entitlement 不含 USB/serial/raw-disk/network；descriptor 以同一进程内直接
     调用传给 decoder，不得以 path、subprocess、socket/network 或 caller assertion
     代替；现有 `ArkDeckApp` 不参与该 trust boundary；
  3. 对 pinned archive fresh rerun，重新生成 mapping/reconciliation/process audit/
     summary/run；签名 identity、签后 entitlement/policy、artifact hash、OS/arch/
     Xcode/Swift/Python 与 descriptor-transfer chain 均写入 platform evidence。
- Out of scope:r1 evidence 重判；任何真实/模拟设备访问；任何 subprocess、网络、
  HDC/vendor tool 或 device mutation；产品集成、烧写地址推导、gap/DEC-002/支持或
  兼容性状态变更；修改 accepted specs/contracts/profile/lock/hardware matrix。
- Requirements/AC:`DECODE-DAYU200-PARTITION-001`、
  `DECODE-DAYU200-INPUT-BOUNDARY-001`、`DECODE-DAYU200-RECONCILE-001`
  (见 acceptance-cases.yaml；三项均须 fresh evidence)
- Depends on:CHG-2026-007 TASK-RB-001 done(已满足,计划第①步)、
  CHG-2026-003 archived(pinned identity 与成员清单,已满足)、r1 FAILED/BLOCKED
  evidence 与 r2 revision 均已合入 `main`(已满足)
- Allowed paths:`scripts/partition_decode/**`(broker 仅位于固定子树
  `macos_input_broker/**`)、本 change `evidence/**`、本 change `tasks.md`
  (仅本任务状态/完成 evidence 引用)
- Forbidden paths:现有 `ArkDeckApp/**`、`ArkDeck.xcodeproj/**`、产品代码、
  `Packages/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:medium(离线只读,但 broker 是 r2 的零设备安全边界；任何 entitlement/
  policy/signing/descriptor chain 不明确即 fail closed。取消/异常不得接受 partial
  governed evidence；输入只读且输出确定,清理临时输出后可安全重跑。解码结论
  被误用为烧写依据的风险继续由 non-authoritative/不推导地址边界覆盖)
- Hardware required:no；禁止以真实 device node 做负测。需要本地 pinned 镜像
  在场并重新通过 size/SHA-256 identity gate；readiness host 已具备 macOS 26.5.2
  arm64、Xcode 26.6、Swift 6.3.3、CPython 3.14.6 与 codesign。当前无 certificate
  identity，broker 使用并如实记录独立 ad-hoc signature(`Signature=adhoc`)；它仅
  是本地 sandbox/platform evidence，不构成 release signing/support claim。
- Deliverables:fd-only decoder + 单元/descriptor 负测 + 静态零 path-open/
  subprocess/network/device-dispatch 审计；独立 broker source/target/entitlements/
  policy/sign/verify/transfer harness；fresh 映射表/对账表/process audit/summary/
  run 与 signing/platform evidence。
- Verification:按 acceptance-cases.yaml 三个 Test ID fresh 执行；broker artifact
  必须 `codesign --verify --strict` 通过，签后 entitlement/policy 与 source
  allowlist 精确一致，descriptor chain 可复查；设备类负测只用 synthetic/mock
  metadata。缺任一项、出现 path fallback/子进程/网络/设备访问或 r1 evidence
  复用，任务整体不得标记 `done`。结论仅对 pinned 镜像成立，不构成烧写依据、
  产品集成、兼容或支持声明。
- PR boundary:后续 remediation implementation + fresh evidence 在一个独立
  `TASK-PD-001` PR 闭环；本 readiness PR 不携带任何 implementation/evidence
  重判，后续 `ready→done` 仍须独立 status PR。

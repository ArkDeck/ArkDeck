# Tasks — CHG-2026-009 DAYU200 partition decode(read-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。本 change 零设备操作、零网络、零 subprocess。

## TASK-PD-001 — parameter.txt 只读解码器 + 映射/对账 evidence

- Status:ready（r3 revision 已由维护者经 PR #109 合入 `main`
  `b4bf696019e114e0f3fc605f679e3f1b3e6aeeb3`；本分支只起草 readiness，只有
  维护者 review/merge 本独立 PR 后才生效）
- Readiness review（2026-07-19；不执行 TASK-PD-001、不产生或重判 acceptance
  evidence）：
  - Change/dependency gate:satisfied。CHG-2026-009@r3 已批准；CHG-2026-007
    TASK-RB-001 done、CHG-2026-003 archived identity/inventory、r2 implementation
    `0076e44dcaed45605c1cccefc093a82b246a4ef5` 与 blocked rerun record
    `0db5f22c0878d059697d32a3022fa260c83e2798` 均为当前 `main` 祖先。r1/r2
    FAILED/BLOCKED evidence 不得追溯重判或复用为 passing evidence。
  - AC/scope gate:satisfied。r3 已封闭 application-visible plaintext retention 与
    opaque DEFLATE state 边界；三项 AC、fail-closed gate 和 fresh platform evidence
    方法均明确。最小 remediation 源码只涉及下述四个固定文件，不修改已签名
    sandbox broker/collector、accepted spec/contract/profile 或其他 task。
  - Toolchain gate:satisfied。clean `main` 上确认 macOS 26.5.2(25F84) arm64、
    Xcode 26.6(17F113)、Swift 6.3.3、CPython 3.14.6 与 codesign 在场；现有
    `test_decode.py` 35 tests / 0 failures，SDD 0 errors / 0 warnings / 111 AC。
    这些是 readiness audit，不是 r3 acceptance evidence。
  - Interactive execution gate:collector 仍必须由人类在可交互解锁的 console
    session 中经 NSOpenPanel/PowerBox 选择 pinned archive。readiness 起草时只读
    host flag 为 `CGSSessionScreenIsLocked=Yes`，故不得在本 PR 启动 collector；
    后续 implementation PR 须先确认解锁，锁屏/取消/无法选择时在 create-only
    publication 前 fail closed，且不得用旧 output 代替 fresh 三项 evidence。
  - Review boundary:本 PR 只起草 `blocked→ready` 与任务精确范围，不修改源码，
    不创建 run/evidence，不改变 gap/DEC-002、产品集成、compatibility、support、
    hardware 或 release claim；实现与 fresh evidence 仍须后续独立 TASK-PD-001 PR。
- Consolidated by TASK-RLC-001（2026-07-19）:固定 r2 implementation OID
  `0076e44dcaed45605c1cccefc093a82b246a4ef5` 与 blocked-attempt record OID
  `0db5f22c0878d059697d32a3022fa260c83e2798` 已登记于 CHG-2026-014 provenance
  manifest；TASK-RLC-001 implementation PR #110 已合入
  `f7c334857ae5735077254ccbdf3dafac8c8ad83b`。独立 r3 澄清已合入
  `b4bf696019e114e0f3fc605f679e3f1b3e6aeeb3`，但此 disposition 不运行 collector、
  不重判旧 evidence、也不提供 fresh AC 结论；本任务保持 `ready`/非 `done`，仍须在
  可交互解锁 host 上执行独立 TASK-PD-001 implementation 与 fresh 三项 AC，不构成烧写、
  产品集成、conformance、hardware、support 或 release claim。
- Objective:在不改变 r3 AC、fd-only decoder 和既有签名 sandbox broker/collector
  边界的前提下，以最小修改移除仅针对 r2 歧义的硬编码 blocker，建立 fail-closed、
  可验证的 opaque codec configuration/lifecycle audit；随后在解锁 host 上对 pinned
  archive 同一次 fresh rerun 生成映射、对账与全部三项 platform evidence。
- In scope:
  1. `decode.py` 将 audit schema 升为 r3 语义并精确记录：gzip-DEFLATE base window
     bits 15(zlib `wbits=31`)、history upper bound 32768 bytes、无 preset dictionary/
     clone/export/history view、application-held compressed remainder configured/实际
     最大值均不超过 65536 bytes、application plaintext retained into next read 为 0；
  2. codec/remainder 在取得 target 以及任一 DecodeFailure、异常或取消路径均通过
     显式 `finally` lifecycle 关闭，receipt 能证明 destroy 已发生且关闭后 remainder
     为 0；缺失、越界或矛盾 receipt 必须令 `partitionAcceptanceSatisfied:false`，
     不允许把配置常量本身当作运行结果，也不声称 allocator forensic zeroization；
  3. `evidence.py`/`test_decode.py`/`README.md` 删除仅针对 r2 歧义的固定 BLOCKED
     结论，改为由上述封闭 receipt 与既有 identity/stream/grammar/reconciliation/
     zero-dispatch gate 共同判定；增加成功、failure/cancellation cleanup、字段篡改、
     cap 越界与静态无二次 plaintext buffer/codec clone/export 的正负测试；
  4. 使用未修改的签名 broker/collector 对 pinned archive fresh rerun，重新生成
     mapping/reconciliation/process audit/summary/run；同一次 run 记录 signing
     identity、签后 entitlement/policy、artifact hash、OS/arch/Xcode/Swift/Python、
     descriptor-transfer chain 与全部三项 AC 结论。
- Out of scope:r1/r2 evidence 重判；修改 sandbox broker/collector source、policy、
  entitlement 或 descriptor trust boundary；任何真实/模拟设备访问；任何网络、
  HDC/vendor tool 或 device mutation；产品集成、烧写地址推导、gap/DEC-002/支持或
  兼容性状态变更；修改 accepted specs/contracts/profile/lock/hardware matrix。
- Requirements/AC:`DECODE-DAYU200-PARTITION-001`、
  `DECODE-DAYU200-INPUT-BOUNDARY-001`、`DECODE-DAYU200-RECONCILE-001`
  (见 acceptance-cases.yaml；三项均须 fresh evidence)
- Depends on:CHG-2026-007 TASK-RB-001 done(已满足,计划第①步)、
  CHG-2026-003 archived(pinned identity 与成员清单,已满足)、r1 FAILED/BLOCKED
  evidence、r2 implementation/blocked record 与 r3 revision 均已合入 `main`(已满足)
- Allowed paths:`scripts/partition_decode/README.md`、
  `scripts/partition_decode/decode.py`、`scripts/partition_decode/evidence.py`、
  `scripts/partition_decode/test_decode.py`、本 change `evidence/**`、本 change
  `tasks.md`(仅本任务状态/完成 evidence 引用)
- Forbidden paths:`scripts/partition_decode/macos_input_broker/**`、现有
  `ArkDeckApp/**`、`ArkDeck.xcodeproj/**`、产品代码、`Packages/**`、
  `openspec/specs/**`、
  `openspec/contracts/**`、`openspec/planning/**`、hardware matrix、其他
  change/task evidence
- Risk:medium(离线只读,但 broker 是 r3 保留的零设备安全边界；任何 entitlement/
  policy/signing/descriptor chain 不明确即 fail closed。取消/异常不得接受 partial
  governed evidence；输入只读且输出确定,清理临时输出后可安全重跑。解码结论
  被误用为烧写依据的风险继续由 non-authoritative/不推导地址边界覆盖)
- Hardware required:no；禁止以真实 device node 做负测。需要本地 pinned 镜像
  在场并重新通过 size/SHA-256 identity gate；readiness host 已具备 macOS 26.5.2
  arm64、Xcode 26.6、Swift 6.3.3、CPython 3.14.6 与 codesign。当前无 certificate
  identity，broker 使用并如实记录独立 ad-hoc signature(`Signature=adhoc`)；它仅
  是本地 sandbox/platform evidence，不构成 release signing/support claim。
- Deliverables:r3 codec configuration/lifecycle audit + fail-closed validator/summary；
  cleanup/cap/tamper/static branch-complete tests；fresh 映射表/对账表/process audit/
  summary/run 与既有签名 broker 的 signing/platform/runtime-binding evidence。
- Verification:先运行 branch-complete unit/static tests，再由未修改的 broker artifact
  完成 `codesign --verify --strict`、签后 entitlement/policy/source allowlist 与
  descriptor chain 复核；只有解锁 host 上同一次 fresh collector 的三个 Test ID
  全部 PASS 才可起草完成。缺任一 codec receipt、cleanup/cap fault、出现 path
  fallback/网络/设备访问/production child-process dispatch、复用 r1/r2 output 或
  archive locator/raw parameter 泄露，任务整体不得标记 `done`。结论仅对 pinned
  镜像成立，不构成烧写依据、产品集成、兼容或支持声明。
- PR boundary:后续 remediation implementation + fresh evidence 在一个独立
  `TASK-PD-001` PR 闭环；本 readiness PR 不携带任何 implementation/evidence
  重判，后续 `ready→done` 仍须独立 status PR。

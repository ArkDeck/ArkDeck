# Dayu200 Characterization Pre-Task Review Gate

> Status：approved(2026-07-18,由维护者 review/merge approval-only PR 构成;
> 先例 #14/#40)
> Reason（历史,2026-07-14 起草期）：The one-scanner/one-Task source passed
> interactive structural review, but the Change was untracked at drafting time,
> canonical external approval and immutable pins were pending, and the V1 signed
> ledger history contained immutable identity-to-hash collisions in addition to
> contradictory governance declarations.
>
> V2 supersession note（2026-07-18）：本仓库治理已迁移为 V2 git-native
> (PR review/merge 为唯一状态生效机制,main 为唯一事实源)。起草期阻塞
> 原因中的 V1 signed-ledger 前提已整体废止;下方三个未勾选项按 V2 逐项
> 处置并记录于各项内联注记,不假称 V1 恢复动作曾经发生。

- [x] Change is implementation-only, pre-M0B and has Core change level none
- [x] One Task implements one Python-stdlib-only scanner, hazard fixtures, branch-complete tests and the four JSON evidence outputs
- [x] Task Requirement and Acceptance sets exactly equal scope.yaml
- [x] Task verification uses the canonical Test ID, method and minimum evidence for all three change-local AC
- [x] dependsOn is empty and no external producer Task is required
- [x] scripts/archive_characterization/** is writable by the implementation Task while Change source, accepted specs/contracts/locks and hardware matrix remain forbidden
- [x] Archive identity is fixed by byte size and SHA-256; the external locator is not persisted
- [x] Hazard members reject before classification and package members are never executed or persistently extracted
- [x] Package classification consumes only verified `{path,kind,size}` rows after the fixed identity gate; archive locator/basename, payload, archive/member hashes, model/marketing text and similarity guesses are excluded
- [x] The six ordered classification conditions, ARC001..ARC009 hazard codes, first-error precedence, 1048576-byte read bound and test-only fixture identity mechanism are closed in design.md
- [x] unknown is a valid package result and Provider, target compatibility and executable Profile remain unknown/non-executable
- [x] Device, HDC, flashd, vendor-tool, network and destructive dispatch are out of scope and audited as zero
- [x] Interactive human reviewer selected `APPROVE-STRUCTURE` on 2026-07-14 for the exact six-condition decision rule, ARC001..ARC009 matrix, evidence contract and closed write paths; this records scope review only and does not assert canonical identity or external approval
- [x] ~~A human-authorized one-time governance recovery first freezes claims,
      establishes an Agent-inaccessible signer and persistent collision-detecting
      append-only ledger, quarantines every polluted immutable identity, creates a
      legal governance-change path, and publishes an externally verified successor
      baseline with mutually consistent current-state declarations~~ —
      superseded by V2（2026-07-18 注记）:V1 signed-ledger 机制已整体废止,
      V2 以 git-native PR review/merge 为治理机制、main 为唯一事实源;该 V1
      恢复动作从未执行,也不再需要。此项按 supersession 关闭,不构成任何
      V1 ledger 修复声明
- [x] The complete Change directory is tracked in git on `main`（V2 事实源;
      2026-07-18 注记）。起草期 front-matter 的 `core_baseline: CORE-1.0.0` 为
      历史元数据:当前 ratified baseline 为 `CORE-2.0.0`,本 change 为
      implementation-only、`core_change_level: none`,不触及任何 Core
      surface/contract/lock,故该过期 pin 无效力也无需重写;实现 Task 的 run
      record 须记录实际 base revision 与输入 hash
- [x] Protected Change and Task approval subjects can be prepared without
      claiming approval or execution — V2 下由 approval-only PR 机制直接满足:
      PR 起草不构成批准,批准仅由维护者 review/merge 构成（先例 #14/#40）

Approval record（2026-07-18）:维护者 review/merge 本 approval-only PR 即构成
本 change 的正式批准;该 PR 仅翻转 `proposal.md` status 并做事实性同步,
不产生任务执行、implementation evidence 或任何 conformance/release 状态变化。

This checklist is a non-authorizing Change source input. It does not create a
claim, evidence result, approval or Ready state.

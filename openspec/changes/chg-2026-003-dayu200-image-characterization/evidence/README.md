# Evidence

TASK-DAYU200-CHAR-001 已于 2026-07-18 执行:evidence 由维护者经 PR #44 合入
main `6c1ba7b`,任务 `ready→done` 经 PR #47 合入 main `02f4258`。本目录现含
下列五个 allowed outputs 与 `runs/TASK-DAYU200-CHAR-001/run.md`(V2 轻量格式,
含全部命令、hash 与三个 AC 的二值 passed 结论)。Drafting-time archive
observations 仍仅为 Change design input,不构成 evidence。

An approved run may produce only:

- archive-identity.json;
- member-inventory.json;
- package-classification.json;
- process-audit.json;
- finalized summary.md;
- run 记录(runs/TASK-DAYU200-CHAR-001/run.md,V2 轻量格式)。

The implementation source, hazard fixtures and unit tests live only under
scripts/archive_characterization/**; they are Task deliverables, not
verification evidence. Evidence may contain the fixed archive size/SHA-256,
ordered member path/type/size/hash records, ARC001..ARC009 results, the six
classification conditions and dispatch counters. A matching classification must
remain fixedArchiveOnly, non-authoritative and candidateNonExecutable. Evidence
must not contain the external locator, raw member bytes, extracted images,
executable members, private keys, raw logs,
device data or unescaped control characters.

unknown is an acceptable package-family result. Provider and target
compatibility remain unknown, Image Profile readiness remains
candidateNonExecutable, and no evidence in this directory may claim DEC-002,
M0B or hardware support.

The approval gate above was satisfied on 2026-07-18 (approval constituted by
maintainer merge; see proposal.md "Approval" and "Verification closure").
Existing evidence files are never overwritten; any future re-run requires a
new change/task authorization.

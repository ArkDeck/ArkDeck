# CHG-2026-036 Evidence

本目录在 proposal 阶段只定义 evidence 边界，不包含 acceptance result。

后续每个任务在自己的 implementation/evidence PR 中写入
`runs/<task-id>/run.md` 与必要的 sanitized machine-readable receipts，并记录：

- exact task readiness/implementation base 与 reviewed input pins；
- commands/environment、changed paths、result 与逐 AC verdict；
- evidence class（`documentReview|contract|platform|realHardware`）；
- process/network/file/USB/E1/E2/mutation/destructive/system-change counters；
- deviations、privacy transform、remaining risk 与 downstream handoff。

不得提交 Developer ID/notary credential、bookmark bytes、用户绝对路径、raw device
identifier/log、image/key 内容、未审计 binary 或不能由 pinned source 重建的 artifact。
Proposal、approval、readiness 与 status-only PR 本身均不构成 acceptance evidence。

# CHG-2026-035 Evidence

本 r1 proposal PR 只登记 change package，不产生 architecture acceptance evidence，
不选择候选，不创建 ADR，也不执行 App、工具、网络、USB、设备、helper、安装、权限或
destructive 操作。

后续 evidence 只允许在 change 由独立 approval-only PR 批准且
`TASK-RKTA-001` 经独立 D1 readiness 成为 `ready` 后写入：

```text
evidence/runs/TASK-RKTA-001/
```

run 必须记录：

- protected-main base、proposal/approval/readiness merge OID 与全部 input pins；
- #525 blocked run/receipt hash 的逐字节复核；
- 一手资料 URL、版本/commit 与 retrieval date；
- candidate matrix、ADR/DEC/profile consistency 与 AC verdict；
- allowed/forbidden diff、SDD/diff/secret/privacy check；
- product build、external process、network、USB、device、helper、install、privilege、
  E1/E2/destructive dispatch 均为 0。

#525 的 001G run 继续只属于 CHG-2026-026，不能复制、改写或重分类为本 change 的
PASS。proposal、approval、readiness、未合入 ADR、二手资料、candidate 自报或聊天描述
均不构成 `RKTA-*` evidence。

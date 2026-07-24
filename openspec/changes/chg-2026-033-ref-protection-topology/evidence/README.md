# CHG-2026-033 Evidence

本 change 的 proposal PR 没有 execution evidence，也没有 GitHub
control-plane/ref/credential 变更。后续 TASK-RPT-001 evidence 已按独立 run 文件
追加；目录中的每份记录必须以自身 classification、authority、OID、hash 与 acceptance
boundary 为准，不得把目录存在本身当作 PASS。

未来 evidence 仅在 change approved、任务经独立 readiness 成为 `ready`、cross-change
stop gate 闭合后追加：

```text
evidence/runs/TASK-RPT-001/
evidence/runs/TASK-RPT-002/
```

必须如实区分：

- public/read-only discovery；
- human-executed D2 control-plane receipt；
- Agent Deploy Key/API negative probes；
- normal no-bypass merge operability evidence；
- documentReview supersession evidence。

不得把 proposal、public projection、fixture、simulation、旧 #435 JSON 或未合入 PR
记为 live authenticated PASS。token、key、cookie、Authorization header、browser
storage、credential path 与 raw secret-bearing payload 永不入仓。

2026-07-24 的首次完整 topology D2 在多层 Agent ref 的即时 REST
read-after-write 核验处 fail closed；保护对象已回滚，`main` 未变化。该 run 的
byte-identical sanitized receipt、成功/未执行边界、残留 controlled ref 与自动误建
PR #471 记录在 `runs/TASK-RPT-001/2026-07-24-topology-fail-closed.*`。
该记录不构成任何 topology AC PASS；#470 executor、窗口、OID、payload、hash 与
probe UUID 均已失效。

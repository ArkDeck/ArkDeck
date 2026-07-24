# TASK-BAP-003 current ref-protection topology addendum

- Date:2026-07-24.
- Classification:protected-main document review of already merged live GitHub evidence.
- Executor:Agent for read-only Git/document review; GitHub control-plane/ref/credential
  mutation:0.
- Historical source preserved:
  `evidence/runs/TASK-BAP-003/run.md` blob
  `d6eaf28e188b1f5f64317ce4eacad22eae10ab10`.
- Current authority:CHG-2026-033 TASK-RPT-001 execution evidence merge
  `6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961`, operability evidence merge
  `7a221d24133eefed38aa616fcda376fef33f6cf3`, done merge
  `94c23c4123712a46e7fb2f96a0509f84f5f49ba7`.

## Supersession boundary

The original run remains true for its 2026-07-23 execution window: the old
ruleset covered main and produced the recorded GH013 rejection. It is not
rewritten and is no longer the current mechanism proof for main.

Current behavior is supported by:

- `openspec/changes/chg-2026-033-ref-protection-topology/evidence/runs/TASK-RPT-001/2026-07-24-topology-success.json`
  (blob `8eb63bf170e993785acda6345a80558fb6871b76`, file SHA-256
  `9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f`);
- `openspec/changes/chg-2026-033-ref-protection-topology/evidence/runs/TASK-RPT-001/2026-07-24-topology-success.md`
  (blob `6c4541d41c8a166edd201883d10190be031d0bea`);
- `openspec/changes/chg-2026-033-ref-protection-topology/evidence/runs/TASK-RPT-001/2026-07-24-no-bypass-operability.md`
  (blob `73005c421eb3fc36a16b435873a18f6e84b97369`).

The authenticated after hashes are:

```text
branch-protection projection:
f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a
branch-protection full:
04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04
ruleset projection:
9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163
ruleset full:
b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5
```

## Current BAP-CRED-001 conclusion

- Agent Deploy Key ID `158088026` can create/update/delete both single- and
  multi-level `agent/**`.
- The same identity cannot create/update/delete ordinary refs or operate
  `agentx/**`; ruleset `19595282` provides those rejections.
- The ruleset now excludes exact main. Deploy Key direct-main is explicitly
  rejected by exact-main branch protection, which requires a PR and `guard`.
- The only ruleset bypass actor and only main push-allowlist user are human
  `lvye`; Deploy Key, Actions and integrations are absent.
- Agent-side authenticated GitHub hosts are zero after the human-isolated
  execution logout; no maintainer credential value or path is recorded.
- PR #476 proves a human CODEOWNER-approved, `guard`-green normal squash merge
  without selecting ruleset bypass.

This addendum preserves the high-level `BAP-CRED-001` PASS while replacing its
current low-level topology pointer. It does not claim a new task execution,
change TASK-BAP-003 status, or modify historical evidence.

## Archive currency note（2026-07-25）

CHG-2026-033 已由 verification-only PR #497 合入 protected `main`
`ce4a11c3d7cb59686024be9cbd51939c084041d1` 并进入独立 archive PR。上文三条
active-root 路径作为 2026-07-24 addendum 原始事实逐字保留；本 archive PR 生效后，
其 current repository location 为：

`openspec/changes/archive/2026-07-25-chg-2026-033-ref-protection-topology/evidence/runs/TASK-RPT-001/`

目录移动不改变上文固定的三个 Git blob OID 或 JSON 文件 SHA-256。本注只登记路径
currency，不重跑 topology、不改变 `BAP-CRED-001` 结论，也不改写原始 run evidence。

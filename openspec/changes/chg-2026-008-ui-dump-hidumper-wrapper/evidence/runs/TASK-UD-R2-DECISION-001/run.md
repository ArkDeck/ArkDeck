# TASK-UD-R2-DECISION-001 — truthful negative R2 decision run

## Classification

- Change/task: `CHG-2026-008-ui-dump-hidumper-wrapper` /
  `TASK-UD-R2-DECISION-001`.
- Test: `TEST-INT-UD-R2-DECISION-001`.
- Evidence class: `humanOfflineDecision` over previously merged real-hardware
  raw; no new hardware execution.
- Decision: **NEGATIVE**.
- Acceptance result: **PASS — truthful-negative branch**. The fixed redactor
  failed closed, so no positive structural family or locator is registered and
  every downstream R2→R4/R4 gate remains blocked.
- Recorded at: `2026-07-21T13:25:25Z`. The failed transform produced no receipt,
  so it has no receipt `completedAt`; the exact human wall-clock second was not
  independently captured.
- Task state: remains `ready` in this evidence + decision PR. A separate
  status-only PR is required to propose `ready→done` after maintainer review and
  merge.

## Readiness and pinned inputs

- r10 readiness trust root: PR #258, maintainer `lvye` approving review and
  merge OID `a2c095cd087ebacc1072353f147f9af903856775`.
- Phase A evidence: `EVD-UD-CAP-MUT-DAYU200-20260721-003`, merged by PR #248 at
  `79b795b7916c863376b3c1f9c37456b0089283dd`; status merge
  `d5aded75d30fbd7ae048005b692b7f4138b23055`.
- Exact raw origin facts consumed by the human-only transform: remote sidecar,
  capture sequence `16`, `866256` bytes, SHA-256
  `ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077`.
  The controlled raw path and bytes are not recorded here.
- Readiness interpreter: `<PRIMARY_CHECKOUT>/.venv-sdd/bin/python`, Python
  `3.14.6`, PyYAML `6.0.3`, executable SHA-256
  `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`.
- Fixed redactor/policy hashes:

| Input | SHA-256 |
| --- | --- |
| `scripts/ui_dump_redaction/redact.py` | `938cc117da97304b5ede66ff55c84dd9ce0a987600d4a1ecec2c3e01351f53e1` |
| `scripts/ui_dump_redaction/algorithm-v1.json` | `a75778fdf525050c4c0bcf11579e5f09f99a6fa70697bcf79026656a71f20185` |
| `scripts/ui_dump_redaction/safe-literals-v1.txt` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/ui_dump_redaction/redaction-receipt.schema.json` | `f4bffe70a51dc3f6228f24d41b814dc47cc2d6f0cde5f00445070f86cd1ec4b6` |

## Human execution and result

Human maintainer `fuhanfeng` ran the task-local interactive helper with the
controlled raw path entered through a no-echo prompt. The helper accepted no
raw path argument and invoked the fixed redactor as an argv array equivalent to:

```text
<READINESS_PYTHON> scripts/ui_dump_redaction/redact.py
  --algorithm-manifest scripts/ui_dump_redaction/algorithm-v1.json
  --safe-literals scripts/ui_dump_redaction/safe-literals-v1.txt
  --input <CONTROLLED_RAW_PATH>
  --expected-input-sha256 ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077
  --output <EXCLUSIVE_DERIVED_PATH>
  --receipt <EXCLUSIVE_RECEIPT_PATH>
```

Observed stable output and result:

```text
redact: INVALID_UNICODE
exit: 27
```

- The helper preflight reported the pinned branch/r10 ancestry, interpreter,
  PyYAML, all policy/source hashes, and redactor suite `21/21` PASS before the
  human supplied the raw path.
- Redactor classification: stable `INVALID_UNICODE`; no attempt was made to
  diagnose, normalize, filter, modify, or bypass the rejected raw.
- The exclusive owner-only staging directory contained zero entries after the
  failure. Derived-created count: `0`; receipt-created count: `0`.
- No derived/raw comparison, semantic parser decision, candidate scan, or token
  extraction occurred. Candidate cardinality is `notEvaluated`, not zero.
- Human installed-HDC/device/network/GUI/destructive dispatch in this task:
  `0/0/0/0/0`.
- Agent raw read, installed-HDC/device/network/GUI/destructive dispatch:
  `0/0/0/0/0/0`.

The repository copy of `operator-redact.sh` was sanitized after the reported
run to derive the same readiness-pinned interpreter from the worktree's Git
common directory instead of retaining a local checkout literal. The fixed
redactor argv, expected raw hash, policy hashes, no-echo raw-path input, external
exclusive staging, and failure semantics did not change. The current helper is
an evidence convenience artifact, not a new transform or output-family
authority.

## Decision

- No repository-safe positive derived fixture exists.
- No R2 success structural family is registered.
- Existing `option ... missed` error-family matches retain first precedence and
  classify as `failure` independent of exit code.
- All other R2 output is `unknownOutput`; exit zero and raw digest alone cannot
  produce success.
- No locator, candidate format, or candidate cardinality is registered.
- The same-session rule remains in force, but cannot unblock an implementation
  without an approved positive locator.
- `TASK-UD-R2-R4-SEAM-001` and `TASK-UD-CAP-R4-001` remain `blocked`; R4
  request/process/HDC dispatch remains `0`.

## Verification

| Check | Result |
| --- | --- |
| Human fixed-redactor execution against exact Phase A raw hash | `PASS` for fail-closed negative branch; `INVALID_UNICODE` / `27` |
| Redactor synthetic contract | `21/21 PASS` |
| Failed staging residue | `PASS`; owner-only directory, zero derived/receipt entries |
| Decision JSON closed-key and required-value validator | `PASS`; controlled raw reads `0` |
| Decision JSON parse | `PASS` |
| Repository-sensitive literal scan | `PASS`; no local checkout/raw path, physical serial, private-key literal, exact token, or nonce |
| `scripts/check-sdd.sh` with readiness Python | `PASS`; `0` errors, `0` warnings, `111` acceptance IDs |
| Bash syntax / external-cwd help / empty-input fail-closed smoke | `PASS`; empty raw path rejected before staging/redactor |
| Untracked artifact diff check (`git diff --no-index --check --stat`) | `PASS` |

Evidence/decision artifact hashes before adding this run record:

| Artifact | SHA-256 |
| --- | --- |
| `decisions/r2-element-tree-v1.json` | `99cc7275da5545cbba4999bebc74c8754183ebbc4081d516ee392527db202c40` |
| `decisions/r2-element-tree-v1.md` | `edb06025bc5cd9c37de5e29d08793ba206fee026719a10107b20d76091b1e314` |
| `operator-redact.sh` | `495ebfa4b353c4546f248e364605aa70ac01a93ba5195114d757b12c999891f9` |
| `validate-decision.py` | `aef6c607e45182965b6024ef48263ca99e8d91f990427d5be98d0d147a2187ff` |

## Deviations and residual risks

- During coordination, the human operator pasted the controlled raw absolute
  path into the task conversation despite the no-path instruction. The literal
  is not reproduced in repository evidence. No raw bytes, full manifest,
  component token, nonce, connect key, or device serial were pasted. Agent raw
  read count remains `0`.
- The helper did not independently record the exact transform wall-clock
  second or its own transient pre-sanitization hash. The authoritative redactor,
  manifest, allowlist, receipt schema, interpreter, raw-origin hash, stable
  error and exit code are pinned above; the helper change did not alter those
  inputs or semantics.
- Because the fixed v1 privacy transform rejects this raw, this task cannot
  produce the positive fixture/locator needed by Phase B. No redactor change,
  raw preprocessing, new capture, selector implementation, or R4 readiness is
  authorized by this decision.

## Scope statement

This run closes only the truthful-negative path of
`INT-UD-R2-DECISION-001` after maintainer review/merge. It does not claim any
canonical `AC-DUMP-*` PASS, Recipe success, compatibility, support,
conformance, hardware expansion, or release status, and it does not change the
task state in this PR.

# CHG-2026-008 r14 — unfinished-task executor and risk audit

## Classification

- Date:2026-07-28.
- Change/task focus:`CHG-2026-008-ui-dump-hidumper-wrapper` /
  `TASK-UD-R2-RECAPTURE-001`.
- Decision grades:D1 executor/scope matrix + D2 revocation of an unconsumed
  physical device window.
- Base:`78da3e3cca1fe66fddf5171f7a9d1c13b37a08bb`.
- Previous CHG-008 head:#715 merge
  `fe13de4d319bd4fdd07f2439daf9cce8bff34897`.
- Method:protected-main repository, contract and task-state audit.
- Installed-HDC process/server lifecycle/device/fixture/Recipe/raw-read/
  mutation/destructive dispatch:`0 / 0 / 0 / 0 / 0 / 0 / 0 / 0`.

The commits between #715 and the audit base advance CHG-2026-022/025/042 and
observation/bookmark/host-loop implementation/tests. They do not modify
CHG-008, `scripts/ud_capture/**`, the current hardware-evidence schema or the
CHG-2026-025 v3 hardware-evidence draft.

## Decision rule

A task is classified as presently Agent-executable only when all of the
following are true:

1. its status is `ready` on protected main;
2. its dependencies are done and its verification is binary;
3. it requires no real hardware, installed HDC, GUI, external side effect or
   sensitive raw access;
4. its task text does not reserve execution to a human;
5. execution requires no new product, Safety, authorization or privacy
   decision.

“Same argv” does not satisfy items 3–5. E1 `deviceMutation` is not reclassified
as E0/no-risk merely because the command is reversible or runs through a tested
harness.

## Authority and contract finding

Current authoritative hardware evidence remains version `2.0.0`:

- path:`openspec/contracts/hardware-evidence.schema.json`;
- Git blob:`98443833b5bef36f4a1e0fdea9dbaaccf057f4d1`;
- SHA-256:
  `d31fdb1d872567a7c4b69ee833593492adc9c39ce28b3b9b0f3597cc334628b0`;
- semantic boundary:`operator` is a human string and an Agent identity is
  explicitly invalid.

CHG-2026-025 contains a version-3 draft that permits `executor.kind=agent` with
`authorizationRef`:

- path:
  `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/hardware-evidence.schema.v3-draft.json`;
- Git blob:`492aa3d5107c6790f56df1fff336280578494364`;
- SHA-256:
  `4dee32ff9a067511efeb110b4fe21c46fdaa00eee092c46ce8406fd1c886eba5`.

That file is a change-local draft. CHG-2026-025 is not verified/archived:
`TASK-AIN-BKMK-001` is done at this base, but `TASK-AIN-004` remains blocked.
Under the repository authority order, CHG-008 cannot treat another unfinished
change's draft as the current contract.

## Current harness gap

The current human harness remains byte-pinned and well tested, but does not
establish an Agent execution authority:

- `HP-1/HP-2` prove only a same-session target token and `Connected` state; they
  do not produce the machine model + serial digest + firmware readback required
  for Agent evidence;
- `INV-1` foreground selection and sidecar absent/new-regular ownership are
  human decisions, not registered deterministic parser families;
- authorization provenance and durable `maxRuns` reservation are absent;
- the CLI prints the controlled output path, so invoking it directly from an
  Agent session would disclose a path that the task requires to remain outside
  the conversation/model output;
- abort versus teardown still includes human classification.

The harness file hashes remain the #715 pins:

| File | SHA-256 |
| --- | --- |
| `scripts/ud_capture/README.md` | `6e5db1827176a0c16b5a4b21431efa9e4d4dab041f03801a357f74b3db2f2601` |
| `scripts/ud_capture/capture.py` | `b407aaa07260e3252428bdf00431f4d1e451c30f77c55f1f6b15a5d170d19492` |
| `scripts/ud_capture/test_capture.py` | `b29c15b8fdca755f26fdfe4f5156082a8bb4a6fd80d8ceecec178419d4690070` |

## Unfinished-task matrix

| Task | Current dependency/effect | Executor verdict | Current action |
| --- | --- | --- | --- |
| `TASK-UD-R2-DIAG-001` | pinned raw permanently unavailable | none | terminal blocked; never substitute input |
| `TASK-UD-R2-RECAPTURE-001` | ready under #715; E1 deviceMutation + real hardware + sensitive raw | future Agent only after full gates; not no-risk | revoke unconsumed human window and block |
| `TASK-UD-AGENT-CAPTURE-SEAM-001` | new host-only fake/synthetic seam; depends on current Agent contracts | Agent-eligible when ready | blocked pending upstream archive + independent D1 readiness |
| `TASK-UD-R2-REDIAG-001` | host-only but reads sensitive retained raw | human-only | blocked on recapture done + D1 readiness |
| `TASK-UD-R2-R4-SEAM-001` | host-only fake/synthetic implementation | Agent-eligible when ready | blocked on a positive R2 decision + readiness |
| `TASK-UD-CAP-R4-001` | E1 same-session R2/private bundle/R4 real-device capture | human-only | blocked; r14 adds no Agent path |
| `TASK-UD-001` | host-only implementation/tests/integration registration | Agent-eligible when ready | blocked on capture/decision/golden prerequisites |

Therefore there is no unfinished CHG-008 task that is both no-risk and ready for
immediate Agent execution at this base. The tasks that are safe for Agent
implementation are explicitly identified, but their fact prerequisites cannot
be bypassed.

## r14 disposition

On maintainer review/merge of the exact r14 head:

1. the unconsumed
   `UD-R2-RECAPTURE-DAYU200-20260728-001` human window is revoked;
2. `TASK-UD-R2-RECAPTURE-001` becomes blocked;
3. `TASK-UD-AGENT-CAPTURE-SEAM-001` is registered as blocked;
4. no Agent, human or CI installed-HDC/device dispatch is authorized;
5. future Agent recapture requires seam done, a current Agent-capable evidence
   contract, and a new D2 exact-device authorization/readiness.

This record does not approve CHG-2026-025, copy its draft into current
contracts, create an authorization, implement the seam, consume a device
window, read raw data, or claim Recipe success/compatibility/conformance.

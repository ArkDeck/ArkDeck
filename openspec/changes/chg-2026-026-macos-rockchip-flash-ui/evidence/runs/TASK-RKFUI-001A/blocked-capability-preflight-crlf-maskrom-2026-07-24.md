# TASK-RKFUI-001A capability preflight — CRLF and Maskrom blocked

- Time: `2026-07-24T04:35:12Z`
- Executor: autonomous agent
- Base: `60ea5266e506f88b81c0ef8a2c6744c770b5b3d5`
- Authorization inputs: PR #440 r2 + PR #452 r3 + PR #460 guarded probe
- Classification: real-hardware E0 capability preflight, blocked before E1
- Run ID: `98458089-1d62-459e-ab59-c7d3aad52945`
- Result: **blocked; device mutation 0**

## Result

Two requests to start the exact reviewed E1 command were rejected by the execution environment
before process start because no pre-existing, maintainer-accepted per-device typed capability
evidence was available. The user supplied the explicit impact approval for this DAYU200 run, but
that interaction does not replace the repository's D2 evidence-acceptance gate. No command,
binding, intent or usage reservation occurred.

A separate E0-only collector then rechecked the exact target, firmware, pre-existing external HDC
server and clean observation-tool pins. Those checks matched. The exact `rkdeveloptool ld`
stdout was 52 bytes with SHA-256
`b474e0ab05ecc648dd39169e60d979e0c7d2cca832abbfc95d56f3f1be4c5238`;
it used CRLF. The approved registry and both production/probe parsers only accept LF, so the
contract parser correctly stopped with `unexpectedCarriageReturn`.

Diagnostic-only byte inspection, which is not contract acceptance, showed one
`0x2207:0x5000 Maskrom` candidate while the pinned HDC target was concurrently online. No
evidence proves whether they are the same or different physical devices. The candidate therefore
remains an independent wrong-mode/identity blocker and cannot be filtered out or treated as
offline.

The canonical sanitized receipt is
`blocked-capability-preflight-crlf-maskrom-2026-07-24.json`, SHA-256
`bbaff003cb9dde3b86125fad5aff4e1973b1d23ed4b112fc882a314ec53a76ff`. Raw connect keys,
identities, LocationID and stdout remain only in controlled task state outside every git
repository.

## Read-only observations

| Check | Observation | Result |
| --- | --- | --- |
| HDC target | exactly one target; pinned serial digest matched | match |
| firmware | `OpenHarmony 7.0.0.33` | match |
| HDC server | exact same-UID listener/command/executable; lifecycle mutation 0 | match |
| discovery tool | `rkdeveloptool ver 1.32`, clean pinned SHA/upstream, no quarantine | match |
| exact `ld` bytes | 52-byte homogeneous CRLF; stderr empty | unregistered family |
| diagnostic-only record | one `0x2207:0x5000 Maskrom` candidate | wrong mode |
| physical correlation | HDC online and Maskrom candidate concurrently visible | unknown |

## Safety counters and gate conclusion

- E0 HDC commands: **4**.
- E0 exact `rkdeveloptool ld`: **1**.
- E1/deviceMutation and `reboot loader`: **0**.
- E2/destructive, Flash/erase/format/unlock/update and `ppt/wlx/rd`: **0**.
- HDC server lifecycle, host shell, `sudo`, helper/driver/system mutation: **0**.
- Binding materialization, `enterUpdater` intent and usage reservation: **0**.

Capability and auto-rebind verdicts remain `unknown`; this is not typed capability evidence.
The next permissible PR is a governance-only r4 revision registering a strict homogeneous
LF/CRLF remediation task. That remediation must preserve the Maskrom block. Only after its
implementation is merged, the environment has no pre-existing RockUSB candidate and a new E0
typed capability receipt is accepted through maintainer review may the one-shot E1 gate be
reconsidered.

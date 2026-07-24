# TASK-RKFUI-001A E0 capability preflight — Maskrom still present

- Time: `2026-07-24T06:31:21Z`
- Executor: autonomous agent
- Base: `2e449569a3dda7c5b6bad7ad083df9934169c840`
- Authorization inputs: PR #440 + #452 + r4 PR #461 + TASK-RKFUI-001B PR #464/#465
- Classification: real-hardware E0 capability preflight, blocked before binding preparation
- Run ID: `c11244c4-7a1c-43c9-bc94-86167961c6f8`
- Result: **blocked; E1/device mutation 0**

## Result

After TASK-RKFUI-001B was merged and recorded done, the independent E0-only preflight rechecked
the exact DAYU200 serial digest, OpenHarmony `7.0.0.33`, pinned HDC client and pre-existing
same-UID server, and the clean `rkdeveloptool 1.32` artifact. Every target, firmware, HDC and
tool pin matched.

The strict post-r4 parser accepted the real 52-byte homogeneous CRLF stdout, but it still
contained one `0x2207:0x5000 Maskrom` observation. Its stdout SHA-256 is
`b474e0ab05ecc648dd39169e60d979e0c7d2cca832abbfc95d56f3f1be4c5238`, exactly the same
shape recorded by the prior blocked preflight. The pinned HDC target was concurrently online,
and there is still no evidence proving whether the HDC and Maskrom observations identify the
same or different physical devices.

Because r4 requires pre-existing RockUSB candidate count `0`, collection stopped before
`OriginalTargetSnapshot`, revision-1 `CurrentDeviceBinding`, typed capability evidence, intent,
usage reservation or E1 dispatch. The canonical sanitized receipt is
`blocked-capability-preflight-maskrom-still-present-2026-07-24.json`, SHA-256
`db7d0b6f98b0030f63eba785054f66a211a2b719fe7dae1c30acb227914afcc2`; raw connect key,
identity, LocationID and stdout bytes remain only in private controlled task state outside every
git repository.

## Read-only observations

| Check | Observation | Result |
| --- | --- | --- |
| HDC target | exactly one target; pinned serial digest matched | match |
| firmware | `OpenHarmony 7.0.0.33` | match |
| HDC server | exact same-UID listener/command/executable; lifecycle mutation 0 | match |
| discovery tool | `rkdeveloptool ver 1.32`, pinned SHA, ad-hoc signature, no quarantine | match |
| strict `ld` parse | complete homogeneous CRLF; one semantic observation | accepted grammar |
| pre-existing candidate | `0x2207:0x5000 Maskrom` | **blocking wrong mode** |
| physical correlation | HDC online and Maskrom concurrently visible | unknown |

The first in-sandbox start was denied before any command because targeted `/bin/ps` inspection
was not permitted. The E0 collector was then run outside the sandbox under the approved
read-only command scope. That environmental start failure produced no HDC/device/tool dispatch
and is not counted as a device retry.

## Safety counters and gate conclusion

- E0 HDC commands: **4**.
- E0 exact `rkdeveloptool ld`: **1**.
- Binding and typed capability evidence materialization: **0**.
- `enterUpdater` intent and usage reservation: **0**.
- E1/deviceMutation and `reboot loader`: **0**.
- E2/destructive, Flash/erase/format/unlock/update and `ppt/wlx/rd`: **0**.
- HDC server lifecycle, host shell, `sudo`, helper/driver/system mutation: **0**.

The required candidate-count-zero predicate is false, so this run cannot mint the per-device
typed capability evidence or unlock the one-shot E1 gate. Capability and auto-rebind verdicts
remain `unknown`. Per r4, this physical/identity blocker cannot be removed or reinterpreted by a
code or governance PR; the environment must first present no pre-existing RockUSB candidate,
after which a fresh E0 preflight may be collected.

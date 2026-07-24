# TASK-RKFUI-001A E0 capability preflight — rkdeveloptool source drift

- Time: `2026-07-24T14:20:39.782469Z`
- Executor: autonomous agent
- Base: `bacf2b7137c29a99cfde02d162e5cdac8d4e3613`
- Authorization inputs: PR #440/#452/#461/#464/#465/#481/#482/#484
- Classification: real-hardware E0 capability preflight, blocked before RockUSB discovery
- Run ID: `296eac0e-83c7-4010-a069-52b98086616c`
- Result: **blocked; `ld`, USB observation, binding, capability evidence and E1 all 0**

## Result

After PR #484 restored E0 preparation, the fresh preflight matched the r5 HDC executable path,
`Ver: 3.2.0f` client/server semantics, executable SHA-256 and pre-existing external same-UID
server. It also matched exactly one HDC target by serial digest and read back
`OpenHarmony 7.0.0.33`.

The clean `/opt/homebrew/bin/rkdeveloptool` file still matched version `1.32` and SHA-256
`bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`.
However, the approved probe derives its upstream source receipt from the executable parent
checkout. That path is currently a regular file under the `/opt/homebrew` repository, whose
HEAD is `7c2bb3b2972fb1ec0788dac8ab0bfeb24ba435a7`, not the registered upstream commit
`304f073752fd25c854e1bcf05d8e7f925b1f4e14`. The registered commit is not an object in the
observed checkout.

The collector therefore stopped before codesign/quarantine checks, exact `["ld"]`, USB topology,
binding preparation or typed capability evidence. Binary hash equality does not authorize
silently replacing or ignoring the source-provenance check. This run does not prove that the
pre-existing RockUSB candidate count is zero; the candidate count is **not observed**.

The canonical sanitized receipt is
`blocked-capability-preflight-rkdeveloptool-source-drift-2026-07-24.json`, SHA-256
`98bc3d03d7ed028397bea8198dd5e429d6d91c2f40afe88e65bc95c77dc82984`. Its private
collector receipt SHA-256 is
`3f9e5006d907efd93e3636b2b4f4971cc7e02642ec4390004f6d26397fa9734b`; raw connect-key and
stdout bytes remain only in private controlled task state outside every git repository.

## Diagnostic predecessor

The first E0 collector run
`044f837c-1063-41ad-9e18-d8bf9248dd42` stopped after two read-only HDC checks because the
temporary, repository-external collector expected the wrong `checkserver` text layout. Raw bytes
showed the actual registered facts as
`Client version:<version>, server version:<version>`, with both versions exactly
`Ver: 3.2.0f`. No target, firmware, RockUSB or USB command ran in that diagnostic.

The collector-only parser was corrected without changing repository code. The canonical run
above then rechecked HDC from the beginning and is the source of the target/firmware and
rkdeveloptool blocker evidence. The diagnostic receipt is retained privately with SHA-256
`c53911be13e1ae9db16e4a896a0b9798a2b0887f20d3bdbea98c84b764827ebc`; it is not capability
evidence.

## Read-only observations

| Check | Approved | Observed | Result |
| --- | --- | --- | --- |
| HDC path/version/hash | exact DevEco path / `3.2.0f` / `05b2bf7a…f83` | exact match | PASS |
| HDC server | pre-existing same UID, pinned executable, lifecycle mutation 0 | exact match | PASS |
| HDC target | one DAYU200 serial digest over USB | one exact digest | PASS |
| firmware | `OpenHarmony 7.0.0.33` | exact match | PASS |
| discovery binary | `1.32` / `bbd7bdc0…9923` | exact match | PASS |
| discovery source | upstream `304f0737…` | parent checkout `7c2bb3b2…`; expected object absent | **blocked** |
| codesign/quarantine | ad-hoc / absent | not dispatched | blocked upstream |
| pre-existing RockUSB | candidate count 0 required | `ld` not dispatched; count unknown | **not proven** |
| USB topology | real USB observation required | not dispatched | blocked upstream |

## Safety counters

Across the diagnostic predecessor and canonical run:

- HDC read-only commands: **6**; canonical target/firmware readbacks: **2**.
- Host-only HDC process inspections: **6**.
- RockUSB tool identity commands: **2** (`-v` and source-checkout `rev-parse`).
- Exact `rkdeveloptool ld` and USB topology observations: **0**.
- Original target/binding and typed capability evidence materialization: **0**.
- Impact confirmation, `enterUpdater` intent and usage reservation: **0**.
- E1/deviceMutation, E1 retry and `reboot loader`: **0**.
- E2/destructive, Flash/erase/format/unlock/update and `ppt/wlx/rd`: **0**.
- HDC server lifecycle, host shell, `sudo`, helper/driver/system mutation: **0**.

The one-run E1 allowance remains unconsumed.

## Remaining gate

TASK-RKFUI-001A cannot claim a fresh candidate-count-zero result or produce per-device typed
capability evidence from this run. A separate scoped remediation must choose and review an
immutable source-provenance closure for the exact binary, or an exact approved upstream checkout
artifact. It must not repin to an unrelated Homebrew HEAD, discard the upstream commit check, or
use equal binary bytes as an unreviewed provenance substitute. Until that remediation is merged
and a new E0 preflight passes every pin in a real USB-visible environment, E1 remains blocked.

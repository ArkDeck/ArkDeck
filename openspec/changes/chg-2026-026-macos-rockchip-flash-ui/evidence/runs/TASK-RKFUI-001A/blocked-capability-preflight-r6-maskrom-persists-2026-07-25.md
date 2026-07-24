# TASK-RKFUI-001A fresh E0 capability preflight — r6 Maskrom persists

- Time: `2026-07-24T16:11:50.971550Z` (`2026-07-25` Asia/Shanghai)
- Executor: autonomous agent
- Base: `47cec786315e79e0aad8a3209c6a7c600e6cfc60`
- Readiness inputs: PR #440/#452/#461/#464/#465/#481/#482/#484/#491/#493/#496
- Classification: real-hardware E0 capability preflight
- Run ID: `1ff87214-a8d2-4667-b47f-cfa75df5d328`
- Result: **blocked; one pre-existing `0x2207:0x5000 Maskrom` candidate; E1/E2 0**

## Result

After PR #496 restored fresh E0 preparation, this run rechecked the exact DAYU200 serial digest,
OpenHarmony `7.0.0.33`, HDC `Ver: 3.2.0f` executable/hash and pre-existing external same-UID
server. All target and HDC pins matched without starting, stopping, migrating or reconfiguring
the HDC server.

The r6 protected-main source-provenance tuple was validated before tool dispatch:

- artifact SHA-256
  `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`;
- upstream commit `304f073752fd25c854e1bcf05d8e7f925b1f4e14`;
- source acceptance `PR#445@cbad982cc211c7d8579a025b8c35f4ed1a519f16`;
- reviewed evidence SHA-256
  `d0b5089954e19a4aba354846fe6108b2d5c89bfc12ab0396c2cd7eb4a082189a`.

The actual `/opt/homebrew/bin/rkdeveloptool` independently matched version `1.32`, the pinned
artifact SHA-256, ad-hoc signature and quarantine-absent gates. No live Git/source-inference
command was dispatched.

The sole exact `rkdeveloptool ld` returned a valid 52-byte homogeneous CRLF record for one
`0x2207:0x5000 Maskrom` candidate. Its stdout SHA-256 is
`b474e0ab05ecc648dd39169e60d979e0c7d2cca832abbfc95d56f3f1be4c5238`, identical to the
previous persistent-Maskrom observation. The pinned HDC target was concurrently online, and
physical identity correlation remains unknown. A separate read-only `system_profiler`
observation completed successfully but exposed no `0x2207` semantic entry; that narrower view
cannot override or reclassify the registered clean-tool observation as candidate count zero.

The candidate-zero gate therefore failed before OriginalTargetSnapshot, revision-1 binding or
typed capability evidence materialization. The canonical sanitized receipt is
`blocked-capability-preflight-r6-maskrom-persists-2026-07-25.json`, SHA-256
`bfbb993a0fdb323144eac3582df4b8b502e2cc88b0b184221ba14ca3cd5d371b`. Raw connect key,
LocationID and command output remain only in mode-protected private task state outside every Git
repository.

## Collector and input closure

The temporary E0-only orchestrator reused the reviewed r6 registry loader, source-provenance
validator, fixed argv-array subprocess runner, server inspector, command receipt writer, trust
checks and HDC/RockUSB/USB parsers from
`scripts/rockchip_loader_transition_probe/probe.py`. Collector SHA-256:
`91f412c0cf345f3e4e27b0f16e5dd291266564b25a236738b207884ccbc99470`.

Before external commands it exact-matched these base input byte hashes:

| Input | SHA-256 |
| --- | --- |
| `tasks.md` | `3eac8a5f9e1cb79086b34c3ffce6143382ca68cc8801efc077b2b944298ddd45` |
| loader-transition registry | `446df409a45a83dce75bc1ee2fcb128cfce13c413d6f86dc097e6fee7887ec7d` |
| `probe.py` | `41ba6bce86fac8ec32d87785473e6e3c2304e99e7e95bf2d2994e30a2d86646c` |
| `test_probe.py` | `1d5ec6cc9e45d798b7b080a73522144a375a5604b98617b111ce886d729b2531` |
| evidence README | `cfc9b12af6bbd7fa3a2301d439d00596fd1b44fd09afc956038870fb733f1864` |

The collector had no caller-supplied command, target, HDC path, retry or mutation argument.
Static review found only the reviewed fixed-argv E0 surfaces and no call to `materialize_e1`.
Host-only verification before the run completed 31 unit tests plus `selftest-host`.

## Read-only observations

| Check | Observation | Result |
| --- | --- | --- |
| HDC target | exactly one target; pinned serial digest matched | match |
| firmware | `OpenHarmony 7.0.0.33` | match |
| HDC client/server | `Ver: 3.2.0f`; pinned executable/hash; external same-UID server | match |
| immutable source provenance | exact r6 tuple and reviewed evidence bytes | match |
| discovery artifact trust | `rkdeveloptool ver 1.32`; pinned SHA; ad-hoc; no quarantine | match |
| strict `ld` parse | complete homogeneous CRLF; one semantic observation | accepted grammar |
| pre-existing candidate | `0x2207:0x5000 Maskrom` | **blocking wrong mode** |
| physical correlation | HDC online and Maskrom concurrently visible | unknown |
| typed capability evidence | not materialized | not eligible |

## Safety counters and gate conclusion

- E0 HDC commands: **4**.
- E0 exact `rkdeveloptool ld`: **1**.
- E0 USB topology reads: **1**.
- OriginalTargetSnapshot/revision-1 binding materialization: **0**.
- Typed capability evidence materialization: **0**.
- Impact confirmation, `enterUpdater` intent and usage reservation: **0**.
- E1/deviceMutation and `reboot loader`: **0**.
- E2/destructive, Flash/erase/format/unlock/update and `ppt/wlx/rd`: **0**.
- HDC server lifecycle, host shell, `sudo`, helper/driver/system mutation: **0**.
- Retry: **0**.

The fresh E0 candidate-count-zero predicate is false. TASK-RKFUI-001A cannot mint a per-device
typed capability evidence candidate or enter the one-run E1 gate, so capability and auto-rebind
verdicts remain `unknown`. This run is not retried. The physical environment must first present
zero pre-existing RockUSB candidates; only a later fresh E0 run may then seek a
maintainer-merged typed capability evidence gate.

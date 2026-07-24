# TASK-RKFUI-001A E0 capability preflight — HDC drift and Maskrom blocked

- Time: `2026-07-24T13:28:00Z`
- Executor: autonomous agent
- Base: `70c043d901e1180af1cc3383f3345ae9edabc5c3`
- Authorization inputs: PR #440/#452/#461/#464/#465/#468
- Classification: real-hardware E0 capability preflight, blocked before target readback
- Run ID: `02941894-1fce-4d07-bf39-f0e51df051b4`
- Result: **blocked; E1/device mutation 0**

## Result

The post-PR #468 E0-only collector stopped at the HDC executable pin before issuing any HDC
target or firmware command. The exact approved path now contains `Ver: 3.2.0f`, SHA-256
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`, instead of the
r3 pin `Ver: 3.2.0d` /
`48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`.

Targeted listener/process inspection still found one pre-existing same-UID server at the pinned
path, with zero Agent server-lifecycle mutation. A bounded `checkserver` receipt reported both
client and server as `Ver: 3.2.0f`; that fact does not retroactively replace the merged r3 pin.
An earlier direct diagnostic `checkserver` returned `Connect server failed`; the server process
start still preceded this run and no generation change was observed. That transient result is
not used as readiness evidence, and the fresh E0 after repin must recheck server health.

The clean discovery tool remained exact, but the real out-of-sandbox USB observation again
returned the same 52-byte homogeneous CRLF `0x2207:0x5000 Maskrom` record, SHA-256
`b474e0ab05ecc648dd39169e60d979e0c7d2cca832abbfc95d56f3f1be4c5238`. A preliminary
sandboxed scout had reported offline; because that environment could not prove equivalent USB
visibility, it is diagnostic-only and is not used as candidate-count-zero hardware evidence.

The canonical sanitized receipt is
`blocked-capability-preflight-hdc-drift-maskrom-2026-07-24.json`, SHA-256
`37839dc5c6f03d4dfb315a075b4418d8e180ff33afd7a3b25958d2c9bdf78722`. Raw stdout,
process identity and LocationID remain only in private controlled task state outside every git
repository.

## Read-only observations

| Check | Approved | Observed | Result |
| --- | --- | --- | --- |
| HDC path | exact DevEco absolute path | same path | match |
| HDC client version | `Ver: 3.2.0d` | `Ver: 3.2.0f` | **drift** |
| HDC executable SHA-256 | `48395ba8…d260` | `05b2bf7a…f83` | **drift** |
| HDC server | pre-existing same UID, pinned path | client/server `3.2.0f`, lifecycle mutation 0 | path/ownership match; pin drift |
| HDC target/firmware readback | exact DAYU200 / `7.0.0.33` | not dispatched | blocked before command |
| discovery tool | `1.32` / `bbd7bdc0…9923` / clean | exact match | match |
| pre-existing RockUSB | candidate count 0 required | one `0x2207:0x5000 Maskrom` | **blocked** |

## Safety counters and gate conclusion

- E0 HDC host checks: **2** (`-v`, `checkserver`); target/firmware HDC commands: **0**.
- E0 exact `rkdeveloptool ld`: **1**.
- Original target, binding and typed capability evidence materialization: **0**.
- Impact confirmation, `enterUpdater` intent and usage reservation: **0**.
- E1/deviceMutation and `reboot loader`: **0**.
- E2/destructive, Flash/erase/format/unlock/update and `ppt/wlx/rd`: **0**.
- HDC server lifecycle, host shell, `sudo`, helper/driver/system mutation: **0**.

The r3 exact HDC window is no longer usable. A scoped readiness revision must explicitly accept
the new HDC version/hash, followed by a separate registry/probe closure PR. Even after that
repin, the independent Maskrom blocker must be absent in a fresh E0 run before per-device typed
capability evidence can be materialized or accepted. Capability and auto-rebind verdicts remain
`unknown`.

# TASK-RKFUI-001A blocked E0 preflight — firmware drift

- Time: `2026-07-24T03:14:35Z`
- Executor: autonomous agent
- Base: `fee0f9f507f7a008cc75952bb895056205c6d4f1`
- Classification: controlled E0/read-only real-device preflight
- Result: **blocked before E1 dispatch**

## Result

The exact target and host tools were available, but the current device firmware did not match
the D2 window merged by PR #440:

| Pin | Approved | Observed | Result |
| --- | --- | --- | --- |
| DAYU200 serial SHA-256 | `958780b2…7a7e` | `958780b2…7a7e` | match |
| transport / target count | USB / 1 | USB / 1 | match |
| HDC | `Ver: 3.2.0d` / `48395ba8…d260` | exact match | match |
| pre-existing HDC server | same pinned executable, no lifecycle mutation | external same-UID pinned executable | match |
| clean `rkdeveloptool` | `1.32` / `bbd7bdc0…9923` / no quarantine | exact match | match |
| firmware | OpenHarmony `7.0.0.34` | OpenHarmony `7.0.0.33` | **mismatch** |

The firmware fact came from one fixed read-only argv:

```text
hdc -t <redacted-connect-key> shell param get const.product.software.version
```

It exited `0`, returned the semantic value `OpenHarmony 7.0.0.33`, and produced no stderr.
The actual argv, including the controlled connect key, hashes to
`6114667935f67bb5b122c412b98a7d18f4f30b4e4e3b3a97146b7af4409268ae`.
The machine-readable sanitized receipt is
`blocked-preflight-firmware-drift-2026-07-24.json`; raw serial/connect-key bytes remain outside
every git repository.

## Safety counters

- E0/read-only HDC dispatches: 5 (`-v`, `checkserver`, `list targets`,
  `list targets -v`, fixed firmware readback).
- E1/deviceMutation: **0**; `reboot loader`: **0**.
- E2/destructive, Flash/erase/format/unlock/update, `ppt/wlx/rd`: **0**.
- HDC server start/stop/migrate/reconfigure: **0**.
- Host shell, `sudo`, helper/driver install, ACL/group/system rule mutation: **0**.
- PR #440 `maxRuns = 1` budget consumed: **0**.

## Gate conclusion

The approved `7.0.0.34` combination cannot authorize the attached `7.0.0.33` device. Per
`POL-SAFETY-001` and the task drift gate, capability remains `unknown` and the task stops before
probe implementation or E1 dispatch. A scoped proposal revision must explicitly accept the
`7.0.0.33` combination; this run cannot retroactively repin or approve it.

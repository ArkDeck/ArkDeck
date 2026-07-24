# TASK-RKFUI-001A r3 implementation preflight — server discovery blocked

- Time: `2026-07-24T03:49:52Z`
- Executor: autonomous agent
- Base: `49490a8f8e0212998119cb590de4df48f46d0f1c`
- Authorization: PR #440 r2 + PR #452 r3
- Classification: real-hardware characterization entry, blocked before device command
- Run ID: `a58a13a3-c080-449a-b3d6-f511d7ef531f`
- Result: **blocked before E0 HDC or E1 dispatch**

## Result

The reviewed harness loaded the exact r3 target, firmware, HDC, clean observation-tool, window,
binding and command pins. Its first fail-closed server gate reported zero candidates because the
initial implementation enumerated every host process with `ps -axo`; in the Codex Python child
environment that view omits the pre-existing external HDC server.

No fallback, server lifecycle command or device command was issued. The canonical sanitized
receipt is `blocked-preflight-server-discovery-2026-07-24.json`, SHA-256
`92e05201930e75cdba22ec20ee6c40f5995f89d9cc97e881ef8acd157e0973ee`.
Raw task state remains in the user-private ArkDeck characterization directory outside every git
repository.

## Read-only diagnosis and remediation

Read-only host inspection after the blocked receipt proved all required server facts:

| Check | Observation | Result |
| --- | --- | --- |
| loopback listener | exactly one same-UID listener at `127.0.0.1:8710` | match |
| targeted process record | external `hdc -m -s ::ffff:127.0.0.1:8710`, parent PID 1 | match |
| executable identity | pinned DevEco HDC absolute executable | match |
| server lifecycle mutation | start/stop/migrate/reconfigure count 0 | match |

The harness now discovers exactly one listener with fixed
`lsof -nP -a -iTCP:8710 -sTCP:LISTEN -Fpu`, then uses a fixed targeted `ps -p <discovered-pid>`
query and a second fixed `lsof -a -p <pid> -d txt -Fn` executable check. PID is discovered from
the pinned local listener, not accepted from the caller. Any missing/multiple listener, UID drift,
process-record drift, command-shape drift or executable mismatch still fails closed.

Host-only verification after the fix:

- `python3 -m unittest scripts/rockchip_loader_transition_probe/test_probe.py -v`:
  22 tests passed.
- `python3 scripts/rockchip_loader_transition_probe/probe.py selftest-host`: passed.
- Python compile check: passed.
- `ARKDECK_PYTHON=python3.11 ./scripts/check-sdd.sh`:
  0 errors, 0 warnings, 111 acceptance IDs.
- Real host-only server identity function: exact listener/PID/UID/command/executable match,
  lifecycle mutation count 0.

## Safety counters and gate conclusion

- E0 HDC commands: **0**.
- E0 `rkdeveloptool ld`: **0**.
- E1/deviceMutation and `reboot loader`: **0**.
- E2/destructive, Flash/erase/format/unlock/update and `ppt/wlx/rd`: **0**.
- HDC server lifecycle, host shell, `sudo`, helper/driver/system mutation: **0**.
- Usage reservation / `maxRuns = 1` consumption: **0**.

Capability and auto-rebind verdicts remain `unknown`; this preflight is not Loader capability
evidence. No second `characterize` command was issued from the unreviewed implementation. The
fixed closed probe and this honest blocked receipt are submitted together for maintainer review
before any later execution gate is considered.

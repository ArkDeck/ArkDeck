# Published Windows service-image verification — 2026-10-14

## Released source and package

Maintainer merge of #2639 published clean protected main
`b29a1774d1f28fe71844a9b1ee140b8cd808bfaf`. The official Windows RC producer,
development signing and private smoke exited 0. The xcopy manifest inventories
365 files. The signed MSIX is 73,675,643 bytes, SHA-256
`4a5a23e7aa6284161d3db301b9753d1a1c54ea87c52f3ce613c9c3bb065c40f0`.
The source check also compares all three repaired production files with the
reviewed #2639 head. No candidate binary is used for these observations.

The SDK could not find its symbol-package tool; the installable package and
signature were produced, but no separate symbols package was generated.

## Native elevation boundary

The signed, published `windows_spk3` guard server has SHA-256
`453b499484754a9eec2570c12cda6a894d3f79260f087a62dc8e6a038ab04368`.
A local diagnostic client uses the same native pipe-open flags as the published
raw connector. It verifies the owned server PID and keeps its process and handle
alive until that server reports authentication. It never reads or writes a
control frame. Both cases use fresh isolated pipes and preserve their raw output.

| Same-account native observation | Actual result |
| --- | --- |
| Unelevated client and server | Authentication passed; zero frames sent; one frame-consumer entry |
| UAC-elevated client and unelevated server | Authentication refused for SID or elevation difference; zero frames sent; zero frame-consumer entries |

The elevated worker independently proves the same account and actual
administrator token. Thus the observed refusal isolates the elevation mismatch.
Both clients remain alive through the server result; all client/server exits are
0. This closes the actual local elevation observation, not the separate
second-account or remote-host cases. No device command, account creation or
transport-policy change is involved.

## Retained first mixed attempt and diagnosis

The new MSIX registered successfully. The first xcopy `doctor` request then
returned `clientTimeout` (exit 75) before any App case ran. That complete call
took 33.8 seconds including startup; the CLI's existing timeout was unchanged.
The workflow exited 1. The original signed Runtime was restored, all 57 complete
Job items matched, and the package and temporary trust were removed.

The same-account diagnostic run separated startup and service inspection:
published health passed in 9.88 seconds, status in 0.19 seconds and verify in
0.17 seconds. A subsequent default-budget doctor passed in 18.66 seconds. This
does not erase the first timeout or establish a latency fix. The diagnostic run
again restored the original Runtime and all 57 complete Job items.
An independent default doctor on the restored predecessor also passed in
20.17 seconds. These observations do not establish a new service-image
regression or a performance qualification.

The fresh mixed attempt confirms health before doctor, preserves a separate raw
directory and uses the same package bytes and unchanged CLI timeout. It remains
pending the next actual desktop UAC confirmation; mixed App qualification and
promotion over the existing installation are not claimed by this record.

## Long soak

A fresh default 24-hour run on the released source began at
2026-10-13 23:40:59 UTC after 60.37 seconds of quiet-host observation: 1.131 busy
CPUs on 16 logical CPUs, below the unchanged limit of 4, with no conflicting
build commands. It retains the 86,400-second duration, 300-second restart
interval, ten jobs per cycle and 32 MiB/16-handle growth limits. The run is still
in progress and is not a completed soak or hardware acceptance result.

## Local targeted checks

Raw records remain outside Git under
`D:/temp/arkdeck-windows-acceptance-20261013`.

- Official `package-rc.ps1 -Smoke`, development signing and private smoke:
  exit 0 (`package-service-status-released.log`,
  `rc-service-status-released/rc-manifest.json`, `smoke.json`).
- Official fixed-cache release builds of `arkdeck-soak` and the
  `windows_spk3` example, signing and signature readback: exit 0
  (`perf-service-status-released-tools`).
- Native equal-elevation and actual UAC-elevation probes: exit 0
  (`elevation-service-status-control-released/summary.json`,
  `elevation-service-status-released/summary.json`).
- First mixed workflow: exit 1; registration/removal exit 0; restoration and
  trust cleanup passed (`service-status-release-run.json`,
  `service-status-release-postflight.json`,
  `service-status-release-trust/msix-trust-lifecycle.json`).
- Separate startup/status/verify/doctor diagnosis and full original-state
  restoration: exit 0 (`service-status-account-diagnosis.json`,
  `service-status-account-diagnosis-restoration.json`).
- Predecessor default-doctor control: exit 0, 20.17 seconds
  (`original-doctor-control.json`, `raw-original-doctor-control`).
- Default long soak: running (`long-soak-service-status-released`); no final
  pass is claimed.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings and 121 acceptance
  IDs (`service-status-published-sdd.log`); `git diff --check`: exit 0.
- No production source, contract or App source changed in this follow-up;
  local Rust tests, contract generation and the full local CI gate were not
  repeated. Actual mixed App tests did not run in the failed first attempt.

## CI

Released #2639 passed Swift CI `38429049434`, including all three host workspace
and contract-parity lanes, and final SDD Guard `38436113755`. The maintainer
merged it at 2026-10-13 23:25:26 UTC. This follow-up reports its own current-head
documentation checks separately; the new observations do not modify those green
source commits.

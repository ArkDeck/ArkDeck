# Windows ClientKit packaged-peer image access — 2026-10-14

## Published reproduction

The second mixed workflow used exactly the signed #2639 release from
`b29a1774d1f28fe71844a9b1ee140b8cd808bfaf`, with the same package bytes as the
[first attempt](windows-service-image-published-20261014-run.md). Health now
precedes doctor in each readback, with the original CLI timeout unchanged.

All four combinations passed health, doctor, service status/verify and full
57-Job readback: matching xcopy, packaged CLI to xcopy Runtime, matching MSIX,
and xcopy CLI to packaged Runtime. Actual App tests reported:

| Actual App case | Result |
| --- | --- |
| Packaged App to xcopy Runtime | 1 passed, zero skips |
| Matching packaged App, English/Chinese capture readback | 5 passed, zero skips |
| Xcopy App to packaged Runtime | 1 failed, zero skips |

The last failure is the real Overview doctor label with a recovery reason
`InstanceMismatch: Access is denied`. Unlike the previous service-status
failure, the preceding Rust CLI inspections all passed. The reverse App reached
the C# ClientKit transport, whose ancestor opens still used metadata-only
access and lacked Rust's reviewed packaged-peer scope. The subsequent restart
refusal assertion did not run because the App assertion ended this workflow.

Registration/removal exited 0; the smoke exited 1. The restoration verifies the
original signed Runtime and every one of the original 57 complete Job items.
Temporary machine/user TrustedPeople entries and the package are absent; the
pre-existing user Root trust remains. No installation promotion occurred.

## Implementation

ClientKit now opens each physical ancestor with `FILE_READ_ATTRIBUTES |
FILE_TRAVERSE`, without delete sharing. This is the effective NTFS lock already
published on the Rust side in #2637. Partial image-open failures release all
ancestor handles.

As in #2638, only native access-denied errors for a process with a nonempty
kernel package family may enter the synchronous peer-image scope. It refuses
an existing thread token and requires the peer primary token's user SID and
elevation to equal the caller's primary token. It opens the same kernel-reported
image and complete namespace with unchanged sharing and reparse checks, then
restores the caller before signature verification or any control frame. The
scope cannot survive an await; a wrong-thread or failed revert terminates the
process. The retained process handle, creation time, image file identity,
installed path, package/signer pins and pipe PID recheck remain in force.

Five native regression tests cover actual ancestor rename denial and release,
retained locks after reversion, image-open failure cleanup, existing-token
refusal without replacement, and invalid-process refusal without a leaked
thread token. The existing wrong-owner/image/signer tests still observe zero
frames. These isolated checks do not replace a published mixed-App rerun.

## Local targeted checks

Raw logs and TRX remain outside Git under
`D:/temp/arkdeck-windows-acceptance-20261013`.

- `dotnet test windows/ClientKit.Tests/ArkDeck.ClientKit.Tests.csproj --filter
  'FullyQualifiedName~ProcessIdentityTests|FullyQualifiedName~PipeAuthenticationTests'`:
  exit 0, 11 passed, zero skips (`clientkit-peer-identity.log`,
  `clientkit-peer-checks/clientkit-peer-identity.trx`). The first sandbox attempt
  built successfully but could not create the external result directory; the
  permitted run above produced the actual test results.
- Full affected ClientKit test project with `ARKDECK_CLIENTKIT_DAEMON` pointing
  to the published signed #2639 daemon: exit 0, 56 passed, one skipped
  (`clientkit-peer-all.log`, `clientkit-peer-checks/clientkit-all.trx`). Actual
  signed-daemon health/doctor and wrong-pin checks passed in a private endpoint
  with no account state owner. The sole skip requires a production Artifact
  Signing sample that is not available on this host.
- `dotnet test windows/App.Tests/ArkDeck.App.Tests.csproj --filter
  'FullyQualifiedName~SurfaceTests|FullyQualifiedName~ShellContractTests'`:
  exit 0, 17 passed, zero skips (`clientkit-peer-consumers.log`,
  `clientkit-peer-checks/app-clientkit-consumers.trx`).
- `dotnet build windows/App/ArkDeck.App.csproj -c Release -p:Platform=x64`:
  exit 0, zero warnings/errors (`clientkit-peer-app-build.log`).
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings and 121 acceptance
  IDs (`clientkit-peer-sdd.log`); `git diff --check`: exit 0.
- Actual published mixed workflow and cleanup:
  `service-status-retry-run.json`, `service-status-retry-postflight.json`,
  `service-status-retry-smoke`, `service-status-retry-trust`. The workflow failed;
  restoration, full inventory preservation and cleanup independently passed.
- No Rust source, contract input, shared strings or generated files changed;
  Rust/Swift tests, contract generation and the full local CI gate were not run.

## CI and remaining qualification

Parent #2640 merged as protected main
`d929ee0e541b9dc877eb27cd1244767c22d767f6`, after docs-only Swift CI
`38487774808` and final SDD Guard `38487891704` passed. This source repair is
submitted separately for maintainer review and its own current-head CI.

A fresh signed package from the repaired protected main must still pass all
seven actual App cases, the restart pre-stop refusal and the cleanup inventory
checks before promotion. The separately retained 24-hour soak ended on a
control deadline after eight completed cycles; no run is currently active and
no soak pass is claimed. This C# repair makes no Runtime latency or hardware
qualification claim.

# Mixed Windows package peer image locks — 2026-10-13

## Reproduction and repair

The earlier registered MSIX App could authenticate the xcopy Runtime as a
server, but a full exchange failed when that Runtime tried to open the packaged
client's image namespace. Native opens of the protected `WindowsApps` ancestor
returned Win32 5, including zero-access and traverse-access opens. Skipping that
ancestor would discard the accepted namespace protection.

A read-only experiment launched only the owned signed packaged sleeping probe.
After verifying its actual package family, equal user SID and equal elevation,
temporarily using its primary token allowed all three directory opens. Reverting
the thread restored Win32 5. This changed neither a directory ACL nor Runtime
identity data (`msix-token-probe.json`).

`ProcessIdentity` now retries an access-denied image/namespace open only when
the retained peer process has an actual package family. The short scope checks
the primary token's user SID and elevation before entering, refuses an existing
thread identity, opens the same image and every ancestor with unchanged flags,
and reverts before returning their retained handles. It is bound to the calling
thread. Revert failure terminates the process instead of continuing with the
peer's authority, following the Windows
[impersonation](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-impersonateloggedonuser)
and [revert](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-reverttoself)
contracts.

Protocol handling and signature checks run after the scope has ended. Pipe
owner checks, SQOS identification-only mode, native PID readback, image identity,
signer/package pinning, liveness checks and no-replay behavior remain in place.
Unpackaged access refusals and errors other than access denial are not retried.
Pre-launch installed-image verification retains its existing path; this retry
is confined to peer process identities with retained process handles.
This repairs an existing platform path; no Catalog operation, RuntimeCapability
or device authority rule is changed.

## Native isolated observations

The SPK-3 example adds an isolated fixed-byte roundtrip using the actual platform
transport. It requires an `arkdeck-spk3-*` pipe, checks the expected signer, and
keeps both peers alive until the bounded parent harness has read both results.
It never speaks the account Runtime protocol or dispatches a device operation.

| Actual registered form | Observation |
| --- | --- |
| Both unpackaged | Bidirectional authentication and native peer PIDs matched |
| Packaged client, unpackaged server | Same; both processes exited 0 |
| Unpackaged client, packaged server | Same; both processes exited 0 |
| Both packaged | Same; both processes exited 0 |
| Packaged server, wrong expected signer | Refused by the client; zero frames sent |

The candidate probe was built from this increment on parent
`0d9236abcec3a765ad7a0103bc34565a2953c546`, signed using the existing development
certificate and installed under a separate probe package name. The manifest
records dirty candidate provenance, exact source and executable/package hashes.
This is candidate platform validation, not released App acceptance or hardware
evidence. The
[separate published MSIX run](../TASK-XPA-022/msix-published-2026-10-13-run.md)
records the already merged App package's 5/5 real UIA results.

The user's standing temporary-trust authorization was used with a fresh UAC
confirmation. The exact public certificate was added to LocalMachine
TrustedPeople at 11:41:36 UTC and removed at 11:41:47 UTC. The helper had a
10-minute cleanup deadline. The probe package was removed, the temporary trust
entry was absent afterward, and original CurrentUser Root trust remained.

## Local targeted checks

Logs remain under `D:/temp/arkdeck-windows-acceptance-20261013` outside Git.

- Three native unit tests passed: retained directory locks after reversion,
  rejection of an existing thread token, and reversion after open failure and
  unwind (`peer-image-unit-final.log`, exit 0).
- Official-runner SPK-3 example build: exit 0 (`peer-image-probe-build.log`).
  Signed package producer and SDK validation: exit 0 (`peer-image-candidate`).
- Actual unpackaged and registered-package probes: exit 0;
  `peer-image-candidate/unpackaged/summary.json`, `mixed/summary.json`,
  `cleanup.json`; trust lifecycle in `peer-image-trust`.
- The generated routing manifest refreshes only `identity.rs` through the
  official source inventory; fixture hashes and routing stay unchanged.
- Official runner `clippy` for platform and its ten direct consumers,
  `--all-targets -- -D warnings`: exit 0 (`peer-image-checks/clippy.log`).
  The fixed session cache and two build jobs were used throughout.
- Required `fmt --all --check`: Windows argv error 206; equivalent batched
  `rustfmt --check` passed all 356 target roots (exit 0, `fmt-batched.log`).
- Full manifest load: exit 0, 927 sources / 6,499 fixtures / 333 targets
  (`manifest.log`).
- Combined `python rust/scripts/run-cargo.py test` with the same eleven `-p`
  selections and `--no-fail-fast`: exit 101 after 1,281 seconds; 1,658 passed,
  17 ignored and 34 failed across 17 targets (`test.log`, exact argv in
  `checks.json`). Every failed function already routes to the historical
  Catalog view: Agentd has six failures and HostStore 28, matching the parent
  run. `classification.json` records each unchanged route. These failures are
  not counted as passes; PR CI runs the existing routed views.
- Platform has 266 passed / zero failed; Bootstrap 13, CLI 277, client 13,
  ArkForge provider 95, HDC provider 207, workspace provider 35, Rockchip
  binding one and soak five all passed. All three account-selection tests
  passed with the original account Runtime temporarily stopped through the
  published service command.
- The final restoration's published health, service status and full Job
  readback all exited 0. The original signed xcopy Runtime was ready and all
  57 complete Job items were unchanged (`raw-peer-image-test-maintenance`).
- SDD: exit 0, zero errors/warnings and 121 acceptance IDs (`sdd.log`);
  `git diff --check`: exit 0. No contract input,
  Swift source or App source changed; those local checks and the full local
  CI gate were not run.

## CI

The effective directory-lock repair #2637 passed required SDD Guard
`38390710097` and Swift CI `38390710325`, including Linux/macOS/Windows workspace
and contract-parity lanes, and was merged by the maintainer at 11:59:43 UTC.
Protected main `1aa911417` has exactly the tested parent tree. This increment
starts there and reports its own current-head CI; it requires maintainer review
before published mixed App/CLI/Runtime acceptance and a new full-duration soak.

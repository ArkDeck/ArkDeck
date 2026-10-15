# Windows ArkForge client integration refresh

ArkDeck's five ArkForge dependencies now share reviewed upstream revision
`eedaa3e3bae641374e453cad302eb214d55d6b08`. This includes the Windows named-pipe
listener lifetime repair and the client used by the completed upstream Windows
campaign. The materializer supplies the client's new explicit `intent` field as
`fullRestore`; preview, primary flash and recovery retain the existing closed
recipe. The fake external-port regression checks that intent on every request.

This update does not install an ArkForge daemon bundle or publish AF-W1. A real
Windows integration still needs the matching bundle and independent agreement
between ArkDeck's Windows attachment topology and ArkForge's connector topology.
The existing task remains blocked on its real-device acceptance; upstream
standalone campaign receipts are not ArkDeck hardware evidence.

## Local targeted checks

Checks used the session's fixed Cargo runner cache on Windows x64, two build
jobs. Log paths below are private local filenames, with no device identifiers.

- `python rust/scripts/run-cargo.py fmt --all --check` hit Windows argument
  length error 206. Equivalent batched `rustfmt --check` over all Cargo target
  roots passed, exit 0 (`arkdeck-arkforge-integration-checks-2/fmt-batched.log`).
- `python rust/scripts/check-arkforge-pin.py --run-vectors` through the runner
  passed, exit 0 (`arkdeck-arkforge-integration-checks-2/pin.log`): the exact
  locked upstream wire and StepPermit vectors are unchanged.
- `clippy -p arkdeck-provider-arkforge -p arkdeck-hoststore -p arkdeck-agentd
  --all-targets -- -D warnings` through the runner passed, exit 0
  (`arkdeck-arkforge-integration-checks-2/clippy.log`).
- `test -p arkdeck-provider-arkforge` passed, exit 0, 88 tests
  (`arkdeck-arkforge-integration-checks-2/provider-test.log`).
- `test -p arkdeck-hoststore` reached 397 passes and then failed the unchanged
  `debug_hap_plan::native_swift_plans_match_with_nothing_admitted_or_dispatched`
  historical Catalog fixture, exit 101
  (`arkdeck-arkforge-integration-checks-2/hoststore-test.log`).
- `test -p arkdeck-agentd` passed its 53 spawning cases, including Flash
  execution, unknown-outcome handling and the recovery broker. It later failed
  the unchanged `windows_artifact_owner_process` historical Catalog fixture,
  exit 101 (`arkdeck-arkforge-integration-agentd-test.log`). Both historical
  suites already have separate routes in `rust/scripts/catalog-test-views.json`;
  assertions and expected bytes were not changed.
- The initial provider compile exposed the missing `intent` field; the passing
  provider test and clippy above include its repair. No local full CI gate was run.

## CI

Pending the PR's `guard` and `swift` checks. macOS and the routed historical
contract checks are left to their existing CI lanes. No real-device execution
or hardware-support promotion is claimed by this software increment.

## Windows CI prerequisite discovered during integration

Run `38713739746` passed the Linux, macOS and Windows contract-parity lanes but failed the
Windows workspace lane because the registered `Git/mingw64/bin/git.exe` no longer exists on runner image
`windows-2025-vs2026/20261007.264.1` (Git `2.56.0.windows.2`). The failure was a deterministic
installed-layout mismatch, not a load-related invalid run. Git for Windows documents the
[2.56 UCRT64 migration](https://github.com/git-for-windows/build-extra/blob/main/ReleaseNotes.md).

The Windows system-tool resolver now checks the registered `Git/ucrt64/bin/git.exe`, then the
older MINGW64 layout only if a path entry is absent. Every ancestor, executable, ACL, signature,
publisher and digest still receives the existing verification. A verification error, including
an error categorized as NotFound after the file opened, never becomes layout fallback. The
launcher, PATH, arbitrary locations and unsigned copies remain inadmissible. This repairs a
prerequisite exposed by the integration's required CI without changing destructive policy.

Local targeted checks: the final source matches the fixed-cache mirror used by
`arkdeck-git-layout-checks-2`. Batched workspace formatting and workspace clippy with
`--all-targets -- -D warnings` both exited 0. The platform system-tool tests passed 9/9;
hoststore Windows workspace-profile tests passed 5/5; agentd's
`windows_workspace_provider_process` passed 4/4. Logs are retained locally in that directory
as `fmt.log`, `clippy.log`, `system-tool.log`, `workspace-tools.log` and `workspace-process.log`.
The local host exercises the signed MINGW64 installation; CI exercises the current runner
image. The UCRT64/legacy selection, no-fallback-on-verification-error and unsafe-directory
cases are also covered independently. No local unified gate was run.

CI: PR #2644's replacement head will rerun the required `guard` and `swift` checks. The failed
run above is retained; no assertion was relaxed and it was not reclassified as a load flake.

# TASK-XPA-018 — the Trace cache purge and diagnostics export on Windows (2026-10-01)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched. Every daemon ran over a fresh development root below the temporary directory,
  holding recorded Swift state where a leaf reads it.
- **Base:** protected `main` `d492cfd3` (#2429, coverage wave 4).
- **Scope:** the lead's slice was the Windows CLI leaves that are `partial` for a reason other
  than the HDC tuple. Wave 4 (#2429) landed first and measured `runtime storage root`,
  `workspace project update|remove`, `workspace preset update|remove` and `capability inspect`.
  This PR takes the two leaves wave 4 left: `trace cache purge` and `diagnostics export`.

## What changed

| Leaf | Change | Test | What it proves |
| --- | --- | --- | --- |
| `trace cache purge` | The macOS `Host::trace_cache_purge` now builds on Windows. The Windows stub, which refused before admission (ruling 18), is removed. The purge runs while the Job owner holds its active-Session census and the Artifact owner its Trace retention census, as on macOS. | `windows_trace_export_process.rs`, `windows_trace_offline_process.rs` | With no Job and nothing retained, the inactive derived entry is removed (`removedEntryCount` 1, no original Trace Artifact removed). A restart and a second purge find nothing. With a recorded Job's Artifacts held, the entry is kept (`skippedActiveEntryCount` 1, bytes unchanged). Parameters are refused (`invalidParams`). Through the CLI the purge answers `arkdeck.trace-cache-purge/1`. |
| `diagnostics export` | none (it already worked) | new `windows_diagnostics_export_process.rs` | The recorded `capture.diagnostics@1` Job is admitted by the Job store owner, with its Artifacts laid down. Its summary exports with the recorded bytes, and so does its sensitive Trace with `--allow-sensitive`. An Artifact of a recorded Job that is not a diagnostics capture is refused (`invalidInput`) before anything is written. |

Both ran through the real CLI against a copy of the daemon signed with the host-trusted
development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT` set; no test reported `SKIPPED`). Each test
asserts that its leaves are Windows `implemented` in the manifest the CLI renders.

Coverage (`maintainer contracts export`): Windows `implemented` 68 → 70, `partial` 72 → 70. The six
coverage-digest pins in `rust/tests/fixtures/maintainer-contracts/oracle.json` were substituted
(`4ea3ae91…` → `70c3ddee…`), as #2378, #2409 and #2429 did.

The purge's maintenance (`trace_maintenance`) was already on NTFS: its entry, quarantine and
removal primitives run in the Trace cache owner's unit tests on Windows. What was missing was
the Host composition only.

## Found, and left for their own PRs

- **`artifact.export` refusing a sensitive Artifact does not conform, on every host.** Without
  `allowSensitive`, the owner answers `sensitiveAccessDenied` (phase `artifactOwner`, no new
  dispatch), as Swift's `RuntimeArtifactResourceHandler` did (#1663). `artifact.export`'s
  published error codes do not list it (`artifact.read`'s do), so the control layer replaces the
  refusal with `internalError` "the result does not conform to the current contract". This hits
  `diagnostics export`, `trace export` and `artifact export` of a sensitive Artifact without the
  permission. The fix is a contract change through `generate-control-contract.py`, as #2389
  published codes Swift answered but never recorded.
- **`workspace preset register`:** a build, test or signing preset pins a DevEco toolchain
  through the Bootstrap registry. The Windows daemon does not give the workspace project owner
  that pinning yet (`host::toolchain_pinning` is macOS-only). #2428 composes the Bootstrap
  registry on Windows; the pinning follows it.

## Still `partial` for reasons other than the HDC tuple, and not in this slice

- `trace inspect`, and the analyzer operations (`analyze trace|trace-summary|hilog-summary|
  crash-signature`): they need the ArkTrace analyzer (`trace_streamer`), which this repository
  pins only for macOS arm64.
- The `workspace.*` Catalog operations and `workspace continuation run|submit`: the workspace
  provider and DevEco toolchain on Windows (GJ-5, H3).
- `artifact import flash-bundle`, `flash.*` and `recovery flash-invocation list`: the Flash
  lane (F1). `debug.*`: M1. `control-action.*`: S1.
- `job plan|submit|run`: the HDC tuple for device Jobs, and the owners above for host-only
  Jobs.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`.
- See the commit message for the local results and the macOS cross-check.

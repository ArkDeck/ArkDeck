# TASK-XPA-005 — GJ-5's workspace continuation end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-5. Fourth layer of P2's stack, on
`agent/xpa-005-windows-job-archive-20261005`. It fixes `health`'s provider list on every Rust host
and measures `workspace continuation submit|run` through the real signed CLI and the signed test
daemon (`agentd/tests/spawning/workspace_continuation_cli.rs`).

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## Decision (delegated minor decision, pending the next rulings batch)

The lead decided this on 2026-10-05. The Swift daemon and the `workspace-continuation` oracle are
the reference: Swift's `health` listed the Runtime's registered providers
(`providerIDs` = `registeredProviderIDs`, sorted), and the oracle's health names `hdc` and
`workspace`. The Rust control layer answered `providers: []` on every host, which is a parity
defect on macOS and Windows alike.

## Fix

`arkdeck-control`: `health` now lists `Control::registered_providers`. This is the set `doctor`
already reported as `providers.registered`: a provider is registered when the host answers any of
its operations at all, and the set is sorted, as Swift's `registeredProviderIDs` is. `doctor`
reads the same helper, so its report is unchanged.

Each host lists exactly what it composes. Nothing is listed on one platform by rule:

- The Windows development root measured here lists `hdc` and `workspace`, the oracle's list. It
  also lists `analyzer` whenever the composition holds analyzer profiles (the census's
  `analyzer`). In the full test run that was the case: this build had placed its analyzer beside
  the daemon. In an isolated run it was not.
- The test therefore requires `health`'s list to equal `doctor`'s `providers.registered`, to be
  sorted, and to contain the oracle's providers.
- A host that composes neither lists neither: for example, `arkdeck-control`'s own read-only test
  host still answers `[]`.

## Recorded frames

`ControlFrames/health.jsonl` can be recorded by `arkdeck-control`'s
`current_health_frame_is_published_and_can_be_recorded` (`ARKDECK_CATALOG_CONTRACT_RECORD`). That
test runs over a host that composes no provider, and re-recorded with this change it still answers
`providers: []`.

The committed frame is an older recording: it has the Catalog digest and contract identity of its
time, and those differ from the re-recorded frame. Its `providers` is also `[]`. It is a schema
corpus, and no test replays its bytes, so this layer leaves it as it is.

The CLI tests that pin `providers` do so in their own fake Runtimes' answers, not the control
layer's. The Swift `health` that this layer replays is the `workspace-continuation` oracle's, and
the measured daemon's list now equals it.

## What

The source Job is a completed `target observe` (`observe.device@1`, the oracle's `deviceReadOnly`
kind of source). Each answer is the one Swift's draft makes of the Runtime's own reads (`Draft`).
`arkdeck-cli/tests/workspace_continuation.rs` replays that draft against the oracle.

- **Health.** `runtime health` lists the oracle's providers (`hdc`, `workspace`).
- **`inspect`.** It answers the draft, eligible and `readOnly`.
- **Refused identity.** The identity `sample`, which Swift refuses, is refused with `invalidInput`
  (exit 65) and nothing is sent.
- **`submit continue-001`.**
  - It accepts a new Job without running it: not dispatched, not deduplicated. Its projection is
    the draft's, with the key set of the oracle's projection.
  - The Job records Swift's fresh request byte for byte (`request_json`). It has the key set of
    the oracle's `continue-001` request, and the same document type, schema, operation, inputs,
    requested outputs, identities and client name. Its provenance names the source Job.
- **`run continue-001`.** It runs that Job once: deduplicated, dispatched, `succeeded`, with the
  draft's projection. The fake receives the device-list reads and then exactly the `observe-device`
  oracle Job's five calls.
- **`run` again.** It answers the settled Job without dispatching, and nothing is sent.
- **Coverage.** `workspace.continuation.submit` and `workspace.continuation.run` join
  `WINDOWS_MEASURED_LEAVES`. The coverage was regenerated with `arkdeck maintainer contracts export`
  (two entries `partial` → `implemented` on Windows), and `oracle.json` is not re-pinned.

## `runtime tool select`, retried after #2501 and #2521

A selection of the second registered stand-in still answers `previewDrifted`
(`tool.selectionFactsUnavailable`). `runtime hdc status` on that daemon gives the reason:
`hdc.identityFamilyUnavailable`, health `hdc.commandlessIdentityDoesNotProveHealth`.

1. **Health proof.** #2501 proves the server's health only through the commandless identity of a
   registered published version (`arkdeck-provider-hdc` `status.rs`, `registered_version`). A
   fixture tuple admits a stand-in's digest, but its version is not a published identity, so the
   impact read is unavailable.
2. **No second tool on a real host.** CHG-2026-078 registers one Windows tuple, so no second tool
   can be a selection candidate there either.
3. **Approval.** The approval is answered only at a real console (#2521's pseudo-console harness
   in `arkdeck-platform`).

Reaching `selected` would need one of:

- a second registered Windows tuple (an integration-profile change), or
- a test-only identity seam in the provider's published-version table.

Both widen what admits an HDC's identity, so `runtime.tool.select` stays Windows `partial`, and the
census row says so for a ruling.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.

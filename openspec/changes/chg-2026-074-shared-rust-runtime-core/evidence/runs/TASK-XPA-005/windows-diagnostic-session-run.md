# TASK-XPA-005 — GJ-1's interactive diagnostic session end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. First layer of P2's stack, on `main`. It
measures `diagnostics session status|mark|stop` (`diagnostic.session.*`) through the real signed
CLI and the signed test daemon, over the `diagnostic-session` oracle
(`rust/tests/fixtures/diagnostic-session/interactive.json`, #2465).

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

`a_diagnostic_session_is_marked_and_stopped_over_the_signed_test_daemon`
(`agentd/tests/spawning/diagnostic_session_cli.rs`):

- **The oracle's fake.** The oracle was recorded by the Rust producer
  `capture_diagnostics::diagnostic_session_publishes_host_marks_and_stops_after_an_unknown_anchor`
  over the Swift fake device of `capture-diagnostics-trace`, with the long recording's start and
  finish (`--trace_begin`, `--trace_finish_nodump`) answered in the observed ring lifecycle
  vocabulary. The signed test daemon answers the same way when the test sets
  `ARKDECK_TEST_SIGNED_DAEMON_RING_VOCABULARY` (`signed_daemon::RingVocabulary`, test only; every
  call is still logged and answered by the shared fake). The daemon reads the producer's fixed
  clock, the synthetic census names the oracle's board, and device mutations are proved against the
  replay root's Job state, as the GJ-1 preset tests do.
- **The session.** The producer's request goes through `job submit --request-file`; the Job is the
  oracle's (`job-859b86ab…`). `job run` is left running while the CLI polls
  `diagnostics session status` until `recording`, marks it once (`problem-observed`) and stops it.
  The run then succeeds, the session's status reads `succeeded` with no `clockObservation` (the
  closed live answer), and a later mark is refused.
- **The Artifacts.** `artifact list --job` answers the oracle's seven Artifacts. Five rows are the
  oracle's rows exactly (identity, digest, size, lease, binding, retention), and the bytes of
  `artifact-index.json` and `capture-summary.json` are the oracle's bytes. `markers.json` and
  `diagnostic-session.json` hold the host instants the session reads from the wall clock (arming,
  marks, stop, the clock observation). With those set aside, their documents equal the oracle's,
  and so do their rows apart from the identity, digest, size and lease that derive from their bytes.
- **An unanchored ring.** With the fake in `ringNotHeld` mode, a second session is interrupted after
  the anchor's readback. Nothing is sent after it, no marker is recorded, and a mark is refused.
- **Coverage.** `diagnostics.session.status`, `diagnostics.session.mark` and
  `diagnostics.session.stop` join `WINDOWS_MEASURED_LEAVES`. The coverage was regenerated with
  `arkdeck maintainer contracts export` (three entries `partial` → `implemented` on Windows), and
  `oracle.json` is not re-pinned.

## Left out

- `capture.diagnostic-session@1` itself stays Windows `partial`. No leaf fronts it; it is reached
  through `job submit` alone, a generic leaf that is counted only under the lead's ruling of
  2026-10-04. The run above is that `job submit` and `job run` path, so a ruling that counts the
  operation can cite this test.
- `diagnostics inspect` over the session's Artifacts is not part of this slice.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.

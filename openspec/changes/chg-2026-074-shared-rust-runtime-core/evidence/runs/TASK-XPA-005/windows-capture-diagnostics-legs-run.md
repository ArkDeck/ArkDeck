# TASK-XPA-005 — every leg and leaf of `capture.diagnostics@1` on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. This layer is stacked on the GJ-1 CLI-leaves
layer (#2518, `agent/xpa-005-windows-gj1-cli-leaves-20261004`). It completes
`capture.diagnostics@1` on Windows: its read, file and Trace legs replayed byte for byte at owner
level, and all six of its CLI leaves measured end to end through the real signed CLI.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The fake's three leg tables** (`arkdeck-provider-hdc/tests/common/oracle_fake.rs`). They port
  `capture-diagnostics-read-legs`, `-file-legs` and `-trace`'s `hdc-answers.sh` case for case, by
  mode:
  - **Read legs:** the component detail, the Faultlogger index and entries, and the liveness reads,
    including degraded, truncated, large, headerless, ambiguous and unavailable answers.
  - **File legs:** the component tree and screenshot, each written to the device's
    `/data/local/tmp` (kept in the fake's `device-tmp`), read back, received at the host path the
    call names, and removed. This includes the empty-tree, missing-tree, not-PNG, empty-landing,
    nothing-landed, refused-cleanup and timed-out-cleanup modes, on four devices.
  - **Trace legs:** the probe's parameters and help texts (`resources/`), the tag list, blocking
    and ring-buffered captures with their anchors, and the dump. Each call also appends its own line
    to `hdc-calls.log`, as the probe's reads run concurrently.

  The fake's answers are now bytes, since the degraded component detail is not UTF-8. They are cut
  at the plan's `capture_bytes` as the tool runner cuts them, and the truncation is reported. A
  child that outlives its budget (`exec sleep`) or dies on a signal (`kill -9 $$`) is the
  dispatch's unobservable outcome, worded as `ProcessDispatch` words it.
- **Found while porting.** The read legs' fragment prints a `HiviewService` banner through a
  `printf` whose format starts with `-`. The oracle's `/bin/sh` read that as an invalid option, so
  the banner never reached stdout, and Swift's 203-byte ledger lacks it. The port leaves it out, and
  says why.
- **The shared replay** (`hoststore/tests/support/hdc_oracle.rs`):
  - `assert_authorized_replays` (new, `Mutations::Authorized`): Jobs admitted and run under the
    durable mutation authority, every answer compared with its message. No Job is required to have
    consumed a use, since some end before their first write.
  - **Read from the fixture:** a host receive root where the oracle fixed one (`receiveRoot`, the
    replay root's `receive`); the `resources/` the answers read; and the per-exchange, sorted
    comparison of a concurrent `hdc-calls.log`.
  - **New methods and state:** `job.show`, and the fake's per-run state (`tag-list-read`) cleared
    before each run.
  - **Relabelling** (`debug_hap::HostLabels`): a learned Runtime capability ID is also read as
    Swift's inside a refusal's words (`lineageBlocked("… capability <ID>-G1 …")`). A file-leg plan
    names the Windows receive path, so its digest and the capability ID derived from it are this
    host's.
- **The owner-level replays** (`hoststore/tests/windows_gj1_replays.rs`):

  | Oracle | Exchanges | Calls | Mode |
  | --- | --- | --- | --- |
  | `capture-diagnostics-read-legs` | 66 | 57 | read-only |
  | `capture-diagnostics-file-legs` | 77 | 83 | mutation authority |
  | `capture-diagnostics-trace` | 72 | 300 | mutation authority, compared per exchange |

  For each, every answer, the fake's calls, the Target document, and the Jobs' index, records,
  Journals, Artifacts, Sessions, capability store and landings are Swift's byte for byte. Host
  paths are read in the oracle's spelling and digest-derived values relabelled. No refusal wording
  differed.
- **The CLI leaves** (`agentd/tests/spawning/gj1_device_leaves.rs`). `every_capture_preset_completes_over_the_signed_test_daemon`
  runs one signed test daemon with the board, over the Trace legs' fake.
  - `screen capture`, `ui-dump capture`, `ui-dump component-detail`, `debug logs` and
    `trace capture` each complete through the real signed CLI, with no pause and every Artifact
    read back.
  - Each sends its legs' commands and removes every owned file it wrote on the device.
  - The device mutations are proved against the test daemon's own Job state (`MUTATION_ROOT`, as
    #2505's replays prove theirs).
- **Coverage.** `WINDOWS_MEASURED_LEAVES` gains the five preset leaves. The coverage was
  regenerated with `arkdeck maintainer contracts export`, and `capture.diagnostics@1` is now
  Windows `implemented`. `oracle.json` is not re-pinned (the lead's decision).

## Found and fixed: the receive root under an 8.3 `TEMP`

The 8.3 short-`TEMP` gate found this. The Windows receive root of #2499 was
`std::env::temp_dir()rkdeck-receive`, which takes `TEMP`'s spelling, and that may be an 8.3
short name (an account name longer than eight characters gives one). A landing is inspected and
published by the canonical path it resolves to. So with a short `TEMP`, every received file was
refused at publication (`artifactIntegrityFailed`, no Artifact), and `screen capture` failed.
`Host`'s Windows receive root is now the temporary directory's canonical, plain long spelling
(`windows_receive_root`). The receive argv and the plan digest name that spelling. The presets
test passes under both `TEMP`s.

## Found, not changed here (product gap)

- **A Windows development root refuses every device mutation.** Its mutation-state root is the
  account's `%LOCALAPPDATA%\ArkDeck\Agentd\jobs-state` (`windows_lifecycle::mutation_root`), which
  its own Job store never is. So `screen capture`, `ui-dump capture` and `trace capture` are
  refused ("Runtime mutation state continuity cannot be proved") on the production development
  root, even beside a registered tuple's managed HDC.
- The account daemon proves continuity but composes no HDC.
- So on a real Windows host today, the file and Trace legs run in no production composition.
  Anchoring the proof at a development root needs the acknowledged development authority beside a
  managed HDC, which Windows does not compose yet. That is a gate-level decision for the lead and
  the maintainer, not taken here.

## Left out

- **`agent.resume` as a measured leaf** is the next layer.
- **Delegated minor decisions, pending the next rulings batch:**
  - the `HiviewService` banner left out, as the oracle's shell left it out;
  - a capability ID relabelled inside a refusal's words;
  - the CLI presets measured over the test daemon's own mutation root.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.

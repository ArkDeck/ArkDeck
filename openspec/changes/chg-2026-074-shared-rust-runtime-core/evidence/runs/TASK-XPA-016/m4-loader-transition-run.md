# TASK-XPA-016 — M4 run record: the Loader transition

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M4 (GJ-4), lane B's "Rockchip
live-mode and post-flash binding" item, third slice: the Loader side of the flash executor,
after the live-mode probe (#1934) and the post-flash HDC observation (#1936). Host measurement
only — not hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device
was contacted and no HDC executable was launched: the only child process is the shared POSIX
`sh` fake HDC driver, answering a fragment written for this record.

Base: protected main `3d880989` (#1932). Branch `agent/xpa-016-loader-transition-20260914`,
stacked on #1936's `e9510ac7` (it extends that slice's ports and clock).

## What was missing

GJ-4's flash flow begins with the one HDC command that mutates the device — `hdc -t <key> shell
reboot loader` — and Swift believes it only when the exact bound Loader appears afterwards,
confirmed by ArkForge; when it does not, the exact HDC-normal readback decides between "the
transition did not complete" (a failed step with a closed diagnostic an operator may see) and
"unknown", and both carry the command's evidence so that the actual cause survives somewhere
other than a macOS crash report (the four campaigns lost on 2026-08-04). Rust had the dispatch
and, since #1934/#1936, the USB and Loader ports; it had nothing that runs the transition and
settles it, and the signal-death sentence lived only in the dispatch.

## What Swift does

`RockchipRuntimeActionHost.swift`. `enterLoader` (431–527): if `exactLoaderIdentity` (1102–1119:
`usbProbe.singleLoader`, whose digest must be the adopted identity — "Loader USB serial does not
match the adopted target identity", else "bound Loader USB identity is unavailable or ambiguous:
E") succeeds, `confirmLoader` (1121–1137: ArkForge's confirmation at the topology just observed,
request id `<jobID>-<stepID>-already-loader`, any refusal "ArkForge dual-source Loader observation
failed: E") and the step returns `transition: already-loader` with no receipt; otherwise
`enterLoaderArguments` (`RockchipDeviceBinding.swift` 64–71, `["-t", key, "shell", "reboot",
"loader"]`, 20 s, 64 KiB) runs — a receipt that is not clean (exit 0, not truncated, empty
stderr) becomes the unresolved `.outcomeUnknown("HDC reboot-loader returned no clean semantic
receipt")`, a pre-spawn `.failed` is rethrown at once, any other runner failure is unresolved —
then `waitForLoader` (1078–1100: the exact Loader confirmed at its topology, a readback a second
for `enterLoaderReadbackTimeoutSeconds`, 45 s by default, else "the bound DAYU200 did not appear
as one exact Loader target") returns `transition: normal-to-loader` with the HDC receipt when
there is one. On its failure, `transitionEvidenceSummary` (935–953: `[hdcExitStatus=N|none
hdcOutputTruncated=true hdcStderr="…" hdcFailure=…]`, stderr through `evidenceText` 955–968: the
first 200 bytes, control characters and quotes as spaces, runs squeezed, `…` when longer,
`<N non-UTF-8 bytes>` when undecodable) is composed; if `exactHDCNormalIdentity` still answers,
`confirmedNotExecutedWithDiagnostic("exact bound HDC-normal USB readback proves the Loader
transition did not complete at topology T <evidence>", diagnostic)` with
`enterLoaderCommandCleanLoaderNotObserved` for a clean command and `enterLoaderHDCNoCleanReceipt`
otherwise (`RockchipFlashExecution.swift` 6–9); else the unresolved failure verbatim; else
`.outcomeUnknown("HDC reboot-loader exited but the exact bound Loader was not observed
<evidence>")`. `waitForLoader` (560–577, 45 s) and `rebindLoader` (579–600, exact + confirm,
summary with `bindingRevision`) are the same readback. `RockchipHostProcessDiagnostics`
(`signalDeath`, `signalNumber(inFailureDescription:)`) is the shared sentence.

## What Rust now does

- `rust/crates/arkdeck-provider-hdc/src/rockchip_loader.rs` (every host; no Swift file changes):
  `RockchipLoaderTransition::new(&dyn HdcDispatch, &dyn UsbProbe, &dyn LoaderObserver, &dyn Clock)`
  with `enter_loader(&TransitionRequest { connect_key, stable_identity_sha256, job_id, step_id },
  &ReadbackBudget)`, `wait_for_loader`, `rebind_loader`; `enter_loader_plan` (Swift's argv, 20 s,
  64 KiB); `ReadbackBudget::DEFAULT` (45 s, 1 s); `LoaderTransition { transition:
  Transition::{AlreadyLoader, NormalToLoader}, loader, receipts }` and its summary;
  `LoaderTransitionFailure::{Failed, OutcomeUnknown, ConfirmedNotExecuted { detail, diagnostic:
  FlashRuntimeDiagnostic }}` (Swift's four-way `RuntimeDispatchFailure` as this arm raises it);
  `transition_evidence_summary` and the `waitForLoader`/`rebindLoader` summaries. Every decision
  and every string above is Swift's; Rust's receipt always knows the exit status, so Swift's
  `hdcExitStatus=unknown` never occurs, and `evidenceText`'s control-character mapping covers
  the control category (Swift's set also covers format characters).
- `src/host_diagnostics.rs`: `signal_death` / `signal_number` / `DIAGNOSTIC_REPORTS_DIRECTORY`
  (Swift `RockchipHostProcessDiagnostics`), now shared by `dispatch.rs` (which had its own copy)
  and the transition.
- `src/live_mode.rs`: `UsbProbe::single_loader` (required, as in Swift's protocol) and
  `LoaderObserver::confirm_loader` (defaulting to a fresh observation, as Swift's extension does).
- Not done here, on purpose: the observation-reuse cache keyed by the managed-control step id
  (`loaderReuseKey`/`BoundHDCKey`, 120 s) through which the disconnect, Loader and rebind arms
  reuse one transition observation — it is the executor's state, consulted before these calls —
  and the descriptor/typed-action table (`rockchip.*.v1`) that selects an arm.

With this slice every HDC arm of Swift's Rockchip executor has a Rust counterpart in
`arkdeck-provider-hdc` (live mode, the waits, the bound reconnect and build verification, the
Loader transition). What remains of M4 for lane B is not device-free: the two ports need the
ArkForge lane's `arkforged` client (SPK-9's preconditions), and the transition's timings are
runbook §5 facts.

## Tests

`cargo test -p arkdeck-provider-hdc` — lib 51/51 (12 in `rockchip_loader`, 2 in
`host_diagnostics`), `tests/rockchip_loader.rs` 2/2 (macOS, under the fake's lock), the other
integration binaries unchanged; `cargo clippy -p arkdeck-provider-hdc --all-targets -- -D
warnings` clean on the host and `--target x86_64-unknown-linux-gnu` / `x86_64-pc-windows-msvc`
for the library; `cargo fmt --all -- --check` clean. The unit tests port Swift's
`testEnterLoader*` cases over a scripted dispatch, a USB port that refuses its first Loader
lookups (a board still rebooting) and knows at most one HDC-normal device, an ArkForge
confirmation that records what it was asked, and a clock that advances only when the readback
pauses.

| Test | Proves |
| --- | --- |
| `an_exact_loader_already_there_skips_the_command` | `already-loader`, no dispatch, no receipt, the summary, one confirmation at the observed topology with request id `job-1-enter-loader-mode-already-loader` (Swift `testEnterLoaderAlreadyInExactLoaderSkipsHDCAndRecordsReadback`) |
| `a_clean_command_is_believed_only_by_the_exact_loader_readback` | exactly `["-t","device-1","shell","reboot","loader"]` 20 s / 64 KiB, the Loader on the second readback: `normal-to-loader` with the clean receipt, one pause, request id `…-post-transition` |
| `a_timed_out_command_is_settled_by_the_exact_loader_readback` | an unobservable dispatch then the Loader: `normal-to-loader` with no receipt (Swift `testEnterLoaderSettlesTimedOutHDCWithExactLoaderReadback`) |
| `a_failed_command_with_the_normal_device_still_there_is_confirmed_not_executed` | exit 1 with the board's two-line refusal: the exact detail with `hdcExitStatus=1`, the stderr on one line and `hdcFailure=HDC reboot-loader returned no clean semantic receipt`, diagnostic `enterLoaderHDCNoCleanReceipt` (Swift `testEnterLoaderConfirmedNotExecutedCarriesTheHDCReceiptSummary`) |
| `a_clean_command_without_a_loader_is_confirmed_not_executed_by_the_normal_readback` | exit 0, no Loader in 2 s, HDC-normal still there: `[hdcExitStatus=0]`, diagnostic `enterLoaderCommandCleanLoaderNotObserved` |
| `a_signalled_command_names_the_signal_and_its_crash_report` | `signal_death(6)` in the evidence (`hdcExitStatus=none hdcFailure=process died on signal 6; …`, readable back with `signal_number`); without the normal readback the unresolved failure is rethrown verbatim (Swift `testEnterLoaderFailureNamesTheTerminatingSignalAndItsCrashReport`, `…KeepsTimedOutHDCUnknownWithoutExactLoader`) |
| `a_timed_out_command_stays_unknown_without_either_readback` | exactly "process timed out before completion" |
| `a_clean_command_with_nothing_observed_is_unknown_with_its_evidence` | "HDC reboot-loader exited but the exact bound Loader was not observed [hdcExitStatus=0]" (Swift `testEnterLoaderUnknownFallbackCarriesTheHDCExitStatus`) |
| `a_refused_dispatch_is_a_failed_step_before_any_effect` | a refused dispatch is `Failed` at once: one port lookup, no readback |
| `the_evidence_clause_is_bounded_and_single_line` | 4 000 stderr bytes truncated: `hdcOutputTruncated=true`, `…`, under 400 bytes, one line; quotes, tabs, a bell as spaces; undecodable and cut-off UTF-8 as `<N non-UTF-8 bytes>`; no receipt as `hdcExitStatus=none` (Swift `testEvidenceSummaryTruncatesStandardErrorAndKeepsItSingleLine`) |
| `wait_for_loader_gives_up_at_the_deadline` | "the bound DAYU200 did not appear as one exact Loader target" after exactly the deadline's readbacks; a zero deadline reads nothing |
| `the_loader_must_be_the_adopted_identity_and_confirmed_by_arkforge` | another board's digest, an ambiguous port, a refusing ArkForge — each with Swift's text; a confirmed rebind with the request id passed through and the `waitForLoader`/`rebindLoader` summaries |
| `a_signal_death_names_the_signal_and_points_at_its_crash_report`, `any_other_failure_carries_no_signal` | the sentence and the round trip (Swift `testSignalDeathNamesTheSignalAndPointsAtItsCrashReport`) |
| `a_clean_reboot_loader_is_proved_by_the_loader_readback` (subprocess) | the driver runs the command once (its log is exactly the argv line), returns cleanly, the Loader appears on the readback |
| `a_refused_reboot_loader_is_confirmed_not_executed_with_its_stderr` (subprocess) | the driver's real two-line stderr and exit 1 become the exact `ConfirmedNotExecuted` detail |

## Not run, and why

- No real HDC and no device: whether a DAYU200 reaches Loader in about four seconds on
  `reboot loader` is the bench fact the 45 s readback budget encodes.
- The USB and ArkForge ports are doubles: the ArkForge lane serves `single_loader` and
  `confirm_loader` over `arkforged` (SPK-9's preconditions, `spk-9-run.md` §4, still stand).
- The reuse cache and the typed-action table are not exercised: they are the executor's.

## Facts for the maintainer from the port (not blocking this slice)

1. `RockchipHostProcessDiagnostics.signalNumber(inFailureDescription:)` has no production
   consumer left in Swift (only the contract test at `RockchipRuntimeCompositionContractTests.swift`
   2073–2075 calls it) while its doc comment still says the flash preflight reads it back. Ported
   anyway, as the cheapest half of the sentence.
2. `enterLoader` keeps a private copy of the cleanliness rule (471–472) beside
   `requireSemanticSuccess` (1230–1231): the same predicate, a different message and a
   non-throwing consequence. Both are ported; the transition arm reports the short message, not
   the rich reasons.
3. `capturePostFlashDiagnostics` computes `request.durationSeconds + 15` inline (751) while the E0
   HDC adapter uses `HDCHilogCaptureRequest.commandTimeoutSeconds`, whose documented purpose is
   the 45 s floor; the two agree only for the production 30 s. Not ported here (the capture arm is
   lane A's `capture.diagnostics@1` family).

# TASK-XPA-020 — Windows Device screen workspace, 2026-10-07

The Device page previously displayed candidates and adopted Target details without its
existing H.3 screen workspace. This increment displays a whole verified Runtime screenshot,
reads a historical screenshot from its original Job, and sends the published pointer and
keyboard operations. A current picture permits one input; confirmed, unknown or dispatched
failed input makes it stale. A new explicit capture is required before another input.
A failed recapture retains the previous image only as stale. A History selection immediately
invalidates input and its generation, and keeps its readonly same-Job read pending until an
in-flight action settles; the old result cannot restore current liveness or repeat a mutation.

Compatibility: the software-first approved Windows task completes the existing H.3 delivery
slice. Current-Catalog GJ-2/Device hardware acceptance remains pending; historical hardware
results are unchanged. These host fixtures are not `REAL_DEVICE_PASS`.

The accepted request is compared semantically with the entire stored typed request, including
outputs and client provenance. Before the only `job.run`, its operation, Target, materialized
revision and identity must match. The terminal read must preserve that request, Catalog,
provider, plan and materialized binding. Loss, malformed replies and drift never resend a run.
Device run deadlines use only the fresh matching available descriptor's 1–900-second timeout
plus the existing 10-second handshake allowance; other ordinary calls retain 10 seconds.

Private keyboard content is uploaded in memory, cleared afterward, and represented in the Job
only by the committed lease and fresh input epoch. The commit receipt uses the actual
generation-1 to generation-2 transition. A lost commit is neither aborted nor repeated.
Pointer mapping preserves the press anchor, letterboxing and device-pixel bounds; keyboard
pointer controls, a visible live coordinate region and same-Job History links are included.

Recording requests 2–300 frames with the existing storage estimate and published byte budget.
Both whole products are checked against the same Job and physical binding: sensitive
`frames.tar` and standard `sequence.json`. The parser bounds tar members/expansion, checks
checksums, names, counts, image dimensions and measured spacing. Attempted-frame timings that
cannot match the actual frames are refused; missing images or cadence are never invented.
Windows Media composes a local MP4, reopens it to check dimensions/duration and measures its
whole size/SHA. If native composition is unavailable, verified frames/timings remain available
for explicit local export. The movie is a local derivative, not a Runtime Artifact.
Save As holds an ordinary, non-reparse source without write/delete sharing, checks its complete
size/SHA before any destination write, and verifies a new staging file before publication.
A changed retained movie is refused while preserving the previously selected destination.

The shared lower dependency also exposes only fixed 120-second diagnostic-session status,
mark, stop and preparation-cancel calls, each on its own authenticated health-first connection.
The last method is the published `job.cancel`. It supplies no caller-controlled method or
deadline. Required shared resources add 84 Device keys, 21 unchanged macOS Diagnostics keys
and six Windows Trace-license presentation keys; unrelated source bytes/values are retained.
The Diagnostics and Trace-license consumer implementations belong to dependent increments.

## Local targeted checks

Base: `d02b2288d6f7faaf9b0674f813414cca99929aaa`. All dotnet commands used the existing worktree
cache and `-m:2 -p:UseSharedCompilation=false`. Earlier commands used `tools/gate_slot.py`;
the final affected Device test/build/UIA commands used the single explicitly coordinated host
lane without that legacy lock, following the current AGENTS guide. No actual Runtime,
DevEco/Harmony SDK, HDC or device was accessed; the installed Windows/WinUI SDK was used.
Logs are in the local scratchpad `device-workspace-20261007`.

| Command / observable check | Result | Log |
| --- | --- | --- |
| `dotnet test windows/App.Tests/ArkDeck.App.Tests.csproj --no-restore --filter 'FullyQualifiedName~DeviceScreenTests\|FullyQualifiedName~DeviceRecordingTests\|FullyQualifiedName~DiagnosticChannelTests\|FullyQualifiedName~ShellContractTests\|FullyQualifiedName~CatalogueTests'` | Exit 0; 38 passed, 0 skipped | `core-native-shared2.log`, `device-core-shared2.trx` |
| `dotnet test windows/ClientKit.Tests/ArkDeck.ClientKit.Tests.csproj --no-restore --filter 'FullyQualifiedName~DeviceRunDeadlineTests\|FullyQualifiedName~ClientTests'` | Exit 0; 17 passed, 0 skipped | `client-native-shared.log`, `device-client-shared.trx` |
| `dotnet test windows/App.Tests/ArkDeck.App.Tests.csproj --no-restore --filter 'FullyQualifiedName~DeviceScreenTests\|FullyQualifiedName~DeviceRecordingTests'` after the recapture/history/export fixes | Exit 0; 22 passed, 0 skipped (18 repeated plus four new regressions; 42 distinct Core cases overall) | `core-review-fixes.log`, `device-review-fixes.trx` |
| `dotnet test windows/App.Tests/ArkDeck.App.Tests.csproj --no-restore --no-build` filtered to `CatalogueTests.TheGeneratedStringsMatchTheSharedSource`, `BothLanguagesCarryEveryKeyWithTheSourceValues`, and `SharedEntriesKeepTheMacOSValues` | Exit 0; three affected repeated cases passed against all 111 added keys | `strings-review-final.log`, `device-final-strings.trx` |
| `dotnet build windows/App/ArkDeck.App.csproj --no-restore` after those fixes | Exit 0; 0 warnings, 0 errors | `app-review-fixes.log` |
| `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj --no-restore --filter 'FullyQualifiedName~DeviceScreenFlowTests'` with the explicit newly built App and `ARKDECK_APP_UITESTS=1` | Exit 0; one passed in 13.105 seconds; actual native composition/reopen: two frames, one measured second, 400 × 800 | `ui-review-fixes.log`, `device-ui-review-fixes.trx`; earlier successful run retained in `ui-native-second.log`, `device-ui-second.trx` |
| `python windows/scripts/generate-ui-strings.py --check` | Exit 0 | `generator-freeze.log` |
| `PYTHONUTF8=1 'C:/Program Files/Git/bin/sh.exe' scripts/check-sdd.sh` | Exit 0; 0 errors, 0 warnings | `sdd-freeze.log`; earlier `sdd-final2.log` retained |
| `git diff --check` (tracked unstaged files) | Exit 0 | `diff-freeze.log` |

Earlier failing logs are retained: fixture raw-string compilation, WinUI namespace ambiguity,
the added positional `JobShown` field breaking a Flash deconstruction (corrected to an init
property), incomplete scripted wire descriptors, and the UI test's unsupported NumberBox
Value pattern (corrected to RangeValue). The first sandbox dotnet invocation emitted SDK setup
only and is not counted as a test pass. No assertion, wire schema or acceptance predicate was
relaxed. The scripted fixture carries published contract-shaped descriptors and recorded
image bytes; its Jobs/products are explicitly synthetic. Its own App process was closed by
the official test harness. No native encoder/hardware result is inferred from compilation.
Exact failed log names: `core-native-first.log`, `app-native-first.log`,
`core-native-final.log`, `core-native-shared.log`, and `ui-native-first.log`.
The unexecuted first sandbox invocation remains in `core-first.log`.
The first SDD command could not find `sh` on PATH and did not run SDD; the explicit installed
Git shell command above supplied the actual result. The generator's required-mode usage error
was followed by `--write` and the final `--check`; it did not change unrelated source entries.

## CI

Not yet run for this increment. Root owns commit/publication onto the reviewed lower stack;
hosted required checks and maintainer review remain separate from these local checks.

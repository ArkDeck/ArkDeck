# Windows: what remains (2026-10-07 App coverage increment)

Source: the official `cli-feature-coverage.json` generator and its exact Windows
App source/fixture mapping. The App increment is pending maintainer review and
protected-main publication; this census does not claim those changes are in the
currently installed Runtime.

The 162 Windows CLI features remain unchanged: 149 `implemented`, 11 `partial`
and 2 `notImplemented`. The 68 App capabilities are separately Windows-required
under accepted ruling 10: 59 `implemented` software targets, one `partial`
installed-update target and eight accepted `deferred` rich TraceViewer targets.
There are 230 Windows-required entries and 33 non-App macOS-only entries; the
scope/status digest of all 195 non-App entries is unchanged. GUI status comes
from exact Windows source/fixture records, with hardware, Narrator and installed
release validation stated separately; a measured CLI equivalent proves no GUI.

CLI measurements include `debug.hap@1`,
`deploy.native-library.app-owned@1` and `cleanupDebt.continue` (TASK-XPA-009 domain leaves);
`device.observations`, `target.availability` and `trace.probe` (TASK-XPA-005 device reads);
`runtime.hdc.status`, `.impact-preview`, `.restart` and `control-action.list`, `.show`,
`.reconcile` (TASK-XPA-005, live with the registered `hdc.exe`);
`device.display-name.set` and `.clear` (TASK-XPA-005: a defect fixed by the lead's delegated
decision of 2026-10-05, pending the next rulings batch: the Host's candidate name owner now names a
candidate in the composed Target observation owner's current observation);
`workspace.sign-openharmony-hap@1` (TASK-XPA-011, live with the host's DevEco Studio, over a test
build's fixture signing and the Swift oracle's stand-in signer);
`workspace.symbolize-crash@1` (TASK-XPA-011: the Swift oracle's published crash, symbolized by the
daemon's own `--symbolize-crash` mode through the real CLI). A non-App CLI feature is `implemented` on Windows only
when each CLI leaf it reaches is in `WINDOWS_MEASURED_LEAVES` (a signed-CLI process test on
Windows); a generic leaf (`agent run`, `agent resume`, `human-action resume`, `job plan|submit|run`)
is counted only once every operation it reaches answers on Windows as Swift does (lead's ruling of
2026-10-04).

The App source registry covers every one of the 68 IDs and refuses missing,
duplicate, unknown or orphan IDs. Actual native Save/Folder cancellation and
whole-file/scope checks supplement the existing native Open flow. The design
mapping closes all 59 controlled exports and 32 independently built previews
under §H.1/§H.3 native semantic projection; source-reference checks are distinct
from the named native UIA flows and accessibility runs. Retired Automation,
upstream ArkTrace canvas, pixel-gallery parity and audible Narrator acceptance
are not promoted. The remaining App update validation needs an installed,
signed same-publisher higher-version MSIX and its release feed; the unpackaged
refusal fixture cannot establish that result.

Owners: every owner of the macOS owner census is composed by the Windows daemon
(`Host::owner_census` lists the same names on both), so no owner is absent. Carved: the development root
still refuses `ARKDECK_DEVELOPMENT_USB_RELATIONS(_WITH_REGISTERED_HDC)`,
`ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER`, `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY`,
`ARKDECK_APP_INGRESS` and `ARKDECK_ARKTRACE_DESCRIPTOR` (`windows_lifecycle::NOT_COMPOSED`);
the ArkTrace analyzer profiles are absent (no ArkTrace distribution on Windows).

Blocker classes: **external** (AF-W1 / ArkForge), **board** (needs the real board, GJ-1/2/3/5
board window), **now** (Swift-oracle parity work we can do now), **dependency** (waits on reachable operations), **closed** (keeps an existing ruling),
**ruling** (needs a ruling).

## Leaves and operations not `implemented` on Windows

| Feature (CLI leaf) | GJ | Class | Blocker, and the oracle that would measure it |
| --- | --- | --- | --- |
| `input.tap@1`, `input.swipe@1`, `input.long-press@1` | 1 | done | Measured: every `pointer-input` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`); Windows `implemented` |
| `input.keyboard@1` | 1 | done | Measured: `artifact import keyboard-input` and `input keyboard` through the real CLI against the macOS Rust owner test's answers (`keyboard_input_run.rs`, #2473), ported into the shared fake (`gj1_inputs.rs`); no Swift oracle exists; Windows `implemented` |
| `capture.screen-sequence@1` (`screen record`) | 1 | done | Measured: every `screen-sequence` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`), capability names relabelled as in the GJ-2/3 replays; Windows `implemented` |
| `port-forward.create@1`, `.remove@1` | 1 | done | Measured: every `port-forward` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`); Windows `implemented` |
| `capture.diagnostic-session@1` | 1 | dependency | Reached through `job submit` alone (a generic leaf); count only after every reachable operation has parity. Its live control `diagnostic.session.mark|status|stop` is measured over the `diagnostic-session` oracle through the real CLI (`diagnostic_session_cli.rs`, TASK-XPA-005) |
| `runtime.tool.select` | 1 | done | Signed CLI over the test-only tuple/impact ports verifies immutable approval, one managed replacement, restart settlement, action show/reconcile/list, dedupe and selected generation two (`account_tool_selection.rs`). Production HDC tuple/health trust is unchanged; delegated minor decision of 2026-10-05, pending the next rulings batch |
| `workspace.continuation.run`, `.submit` | 5 | done | Signed CLI over the `workspace-continuation` oracle verifies submit, run, retained bytes and refusal/repeat paths (`workspace_continuation_cli.rs`). `health` lists assembled provider ports without consulting availability or initializing durable owners; cross-platform regression checks unchanged Session owner bytes |
| `workspace.symbolize-crash@1` and named crash capture | 1, 5 | done | Measured by the signed CLI (`workspace_symbolize_leaf.rs`): the Swift oracle's crash resolves to its ArkTS source, and a named crash captured by the Windows daemon is symbolized through its lease. `crashLogs: true` alone selects the index; `crashLogName` selects the dump. The former's `missing` dump row is expected, not a Windows defect |
| `flash.reconcile-alias` | 4 | done | Signed CLI checks 21 `flash-host-reads` alias exchanges and the `post-flash-alias` reissued lineage, exact private/archive bytes, restart durability and zero HDC dispatch (`flash_alias_cli.rs`) |
| `debug.template@1`, `debug.template.run` | 2 | done | Signed CLI checks all four closed template Jobs, sensitive/raw binary Artifacts, failure paths and unknown-intent restart/reconcile without replay (`debug_template_cli.rs`). Delegated reference: macOS Rust `debug_template_run.rs` owner semantics plus existing Swift `debug-probe` normal payloads; pending next rulings batch |
| `analyzer.analyze-trace@1`, `analyzer.summarize-trace@1`, `trace.inspect` | — | external | Await a reviewed Windows ArkTrace `trace_streamer` distribution (ruling 72); keep the descriptor/trust refusal. Delegated scope decision: do not substitute a fixture for a trusted distribution |
| `agent.run`, `agent.resume`, `human-action.resume`, `job.plan`, `job.submit`, `job.run` | all | dependency | Count only when every reachable operation answers as Swift does; external `flash.dayu200` and the missing Windows ArkTrace distribution prevent completion |
| `flash.dayu200` | 4 | external | Real flash through the ArkForge lane (AF-W1) |
| `runtime.service.install`, `runtime.service.update` | — | closed | Keep ruling 42: the client-started daemon has no installer. Runtime RC updates continue through reinstall (ruling 78); delegated decision of 2026-10-05 keeps these leaves `notImplemented` |

No item is blocked only on the board: each device leaf above replays a Swift oracle through the
shared fake HDC. The GJ-1/2/3/5 board window confirms them on the DAYU200 (`REAL_DEVICE_PASS` is
board-only).

## Windows owner workload

TASK-XPA-025's Windows software gap is closed: the Rust soak now runs the same
bounded simulated-provider Job, journal, recovery and Artifact owners as macOS,
over signed/PID-verified named-pipe generations. Benchmark consumers seed/read
those owners; Windows durability names `FlushFileBuffers`. Fresh private roots,
installed-state refusal, unknown-intent refusal and the 32 MiB/16-handle growth
limits remain enforced (`windows-owner-soak-20261005-run.md`). This port does not
change CLI feature counts or TASK-XPA-024's optional Viewer FFI boundary.

The software checks use tiny correctness workloads. Quiet-host Windows reference
capture, long soak, performance spread checks and baseline adoption remain Phase A
acceptance work; no fixture result is hardware evidence or performance approval.

## Remaining acceptance and dependencies

The presently actionable CLI increments above are measured. Remaining generic
leaves depend on AF-W1 and a trusted Windows ArkTrace distribution; service
install/update keep their existing closed decision.

The host workspace Session publication repair is released in #2597, protected
main `d238a55c7b693adc7edbf6314699e920f0ee1e08`. It retains the original complete
consumed Runtime authority and verifies the original Job, Journal, plan and
tool provenance before publishing a closed host mutation. Windows external-tool
versions come from the same-SHA retained executable's fixed PE FileVersion; no
version child is dispatched. The Runtime's own compiled package version applies
only to its exact executable path, native identity and SHA. Existing
`job reconcile --job` can settle a retained
publication without redispatching the operation or renewing its authority.
Unknown outcomes and incomplete provenance still refuse. This repair changes
neither CLI feature counts nor the original Job outcome.

The root's new independent host repair chain has succeeded patch/build/test
publications at generations 7/8/9, with whole build HAP/log and test-log readback
and exact fixed-input checks. Its three host dispatches completed in
1007.746156 seconds with 2,750,419 declared Job Artifact bytes, within one round,
40 minutes and 512 MiB; the expired original chain is not reset. The retained
historical build/test publications at generations 5/6 are unchanged. A separate
independent `debug.hap` smoke succeeded once and published generation 10;
`debug-hilog.txt`, `install-readback.json` and `process-readback.json` were read
whole and hash-checked. This establishes the smoke's software checks, with no
UI, device-info or screenshot claim and no formal device PASS. The Runtime was
then stopped through its typed operation with state preserved.

The resumed GJ-1 run on 2026-10-06 achieved `REAL_DEVICE_PASS`: all 88 recorder
criteria hold on source `d238a55c7b693adc7edbf6314699e920f0ee1e08` and Catalog
`c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036`.
Observe's three and capture's six published Artifacts were read whole and
hash-verified before and after restart; capture's eight missing inventory
declarations remain honestly recorded. Physical unplug produced Runtime HAR
exit 75 with zero new dispatches; a fresh status/show reference was resumed once
with exit 0, and all three HAR Artifacts were read whole and hash-verified.
Typed stop/status (Raw 83/84) exited 0 with a complete drain, absent socket and
preserved state. The canonical record is
`docs/design/references/v1.6-goal/gj-headless-rerun-2026-10-06-windows.json`;
the run note is
`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-006/windows-gj1-2026-10-06-run.md`.
The earlier user-skipped window remains historical truth.

GJ-2/3/5 remain incomplete, but their signing payloads are prepared. Maintainer
review and protected-main publication of #2606 adopted the exact same-HAP pair,
signed ARMv7 forward library and signed ghost rollback baseline in
`scripts/gj_record/baselines/gj-pair-armv7-20261006/manifest.json`. The HAP digest
is `ec5ce24958a16047c784a4af0f2197db86009abe1a3fbb193363a8bdd825e4bf`;
the lost historical files no longer block execution. Standalone library SDK
signature checks are preparation, not proof of device loading or rollback.

The real GJ-2 capture originally failed `artifactIntegrityFailed` because Windows
HDC emits registered help/tags in CRLF. Released #2608 registers only four exact
CRLF representations; Raw bytes and whole hashes are retained. Production
release-library checks over all four saved real outputs pass, and tampered,
mixed-line-ending and truncated inputs still refuse. Binary Trace validation is
unchanged. Complete HiLog/UI/Trace, typed service restart and durable Job/Artifact
readback still require a fresh successful device run; old Raw is never joined.

The installed protected-main Runtime `f245a1d9c34c6deb56d9f50236db0a5284cc062b`
was exercised in the retained account. Its native startup exits 69 because an
unknown-owner HDC listener occupies the registered endpoint. The retained exit,
stdout/stderr and absent/present/absent pipe observation establish this failure;
POL-HDC-001 forbids adopting or stopping that listener. #2614 preserves this
child's exit when readiness loses its pipe, and #2615 documents the existing
packaged CLI warm-up before the connect-only App. Both are software fixes,
pending maintainer approval, not a waiver of that ownership gate.

GJ-3's released #2609 readback includes actual backup/restored whole hashes,
PID/maps and reload facts. Its new full forward/post-publication ghost failure/
automatic rollback/reload runs on both hosts await paired GJ-2. GJ-5 retains
nine independent checks: eight known-success Jobs, crash count 0→1, unhealthy
reproduction then healthy verification, and a revision-conflict negative with
zero new dispatch and identical adjacent 21-Job ledgers. Signing material and
preset are present. Released #2611 fixes the recorder's actual `result.status`
projection; canonical paired GJ-5 still needs its own fresh full run.

The signed/notarized macOS RC build 4 is already downloadable from release run
37461315601. Its protected-main ancestor has the same Catalog/contracts; reuse
does not require another build. The prepared executable entry is
`scripts/gj_record/mac-entry/entry.py`. No currently accessible Mac has proved
DAYU200 USB access: a usable Mac SSH endpoint/account with existing safe
authentication, followed by the same board at its fixed USB port, is required.

GJ-4 is independent: ArkForge's production `windows-acceptance.yml` has no AF-W1
run, and no downloadable matched `arkforge.release-bundle/v1` Windows release.
The ArkForge release/protected `windows-production` environment and qualified
DAYU200 runner owners must provide both. Ordinary Windows/Rust CI is not AF-W1,
and an acceptance JSON alone is not the release Bundle. The prepared published
DAYU200 OpenHarmony 7.0.0.43 image has whole SHA-256
`781d2eaebe2f8d10a25d13102a38259b134210480b2153786032a3bdea675fed`.
The draft is one primary flash, 1800 seconds and 128 MiB, preserving protected
partitions and overwriting userdata. Bundle/AF-W1 must first pass Runtime
admission; the named destructive HardwareCampaign and user execution window
authorization remain outstanding. No flash was dispatched.

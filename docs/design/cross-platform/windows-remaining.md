# Windows: what remains (census as of `main` 2026-10-05)

Source: `openspec/contracts/cli-feature-coverage.json` after #2578, symbolize and continuation increments.
Of the 162 features the Windows CLI must serve, 145 are `implemented`, 15
`partial` and 2 `notImplemented`; 101 are macOS-only. Measured since: `debug.hap@1`,
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
daemon's own `--symbolize-crash` mode through the real CLI). A feature is `implemented` on Windows only
when each CLI leaf it reaches is in `WINDOWS_MEASURED_LEAVES` (a signed-CLI process test on
Windows); a generic leaf (`agent run`, `agent resume`, `human-action resume`, `job plan|submit|run`)
is counted only once every operation it reaches answers on Windows as Swift does (lead's ruling of
2026-10-04).

Owners: every owner of the macOS owner census is composed by the Windows daemon
(`Host::owner_census` lists the same names on both), so no owner is absent. Carved: the development root
still refuses `ARKDECK_DEVELOPMENT_USB_RELATIONS(_WITH_REGISTERED_HDC)`,
`ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER`, `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY`,
`ARKDECK_APP_INGRESS` and `ARKDECK_ARKTRACE_DESCRIPTOR` (`windows_lifecycle::NOT_COMPOSED`);
the ArkTrace analyzer profiles are absent (no ArkTrace distribution on Windows).

Blocker classes: **external** (AF-W1 / ArkForge), **board** (needs the real board, GJ-1/2/3/5
board window), **now** (Swift-oracle parity work we can do now), **ruling** (needs a ruling).

## Leaves and operations not `implemented` on Windows

| Feature (CLI leaf) | GJ | Class | Blocker, and the oracle that would measure it |
| --- | --- | --- | --- |
| `input.tap@1`, `input.swipe@1`, `input.long-press@1` | 1 | done | Measured: every `pointer-input` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`); Windows `implemented` |
| `input.keyboard@1` | 1 | done | Measured: `artifact import keyboard-input` and `input keyboard` through the real CLI against the macOS Rust owner test's answers (`keyboard_input_run.rs`, #2473), ported into the shared fake (`gj1_inputs.rs`); no Swift oracle exists; Windows `implemented` |
| `capture.screen-sequence@1` (`screen record`) | 1 | done | Measured: every `screen-sequence` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`), capability names relabelled as in the GJ-2/3 replays; Windows `implemented` |
| `port-forward.create@1`, `.remove@1` | 1 | done | Measured: every `port-forward` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`); Windows `implemented` |
| `capture.diagnostic-session@1` | 1 | ruling | Reached through `job submit` alone (a generic leaf). Its live control `diagnostic.session.mark|status|stop` is measured over the `diagnostic-session` oracle through the real CLI (`tests/spawning/diagnostic_session_cli.rs`, TASK-XPA-005) |
| `runtime.tool.select` | 1 | ruling | `runtime.tool.register` is measured (`--kind hdc` over the account composition, `tests/spawning/account_tool_selection.rs`, TASK-XPA-012). After #2501 a selection still drifts (`tool.selectionFactsUnavailable`): the server's health is proved only by the commandless identity of a registered published version (`status.rs`, `hdc.identityFamilyUnavailable` for a fixture tuple's stand-in), CHG-2026-078 registers one Windows tuple, so no second tool can be a candidate on a real host, and the approval takes a real console (#2521). Reaching `selected` needs a second registered tuple or a test identity seam |
| `workspace.continuation.run`, `.submit` | 5 | done | Signed CLI over the `workspace-continuation` oracle verifies submit, run, retained bytes and refusal/repeat paths (`workspace_continuation_cli.rs`). `health` lists assembled provider ports without consulting availability or initializing durable owners; cross-platform regression checks unchanged Session owner bytes |
| `workspace.symbolize-crash@1` and named crash capture | 1, 5 | done | Measured by the signed CLI (`workspace_symbolize_leaf.rs`): the Swift oracle's crash resolves to its ArkTS source, and a named crash captured by the Windows daemon is symbolized through its lease. `crashLogs: true` alone selects the index; `crashLogName` selects the dump. The former's `missing` dump row is expected, not a Windows defect |
| `flash.reconcile-alias` | 4 | now | Reconciler reached by the CLI; `post-flash-alias` / `flash-host-reads` oracles, needs a fake lineage |
| `debug.template@1`, `debug.template.run` | 2 | ruling | No Swift oracle records the `debug.template@1` Job's HDC answers; measuring needs a ruling on the reference |
| `analyzer.analyze-trace@1`, `analyzer.summarize-trace@1`, `trace.inspect` | — | ruling | No ArkTrace distribution (`trace_streamer`) on Windows; `ARKDECK_ARKTRACE_DESCRIPTOR` refused |
| `agent.run`, `agent.resume`, `human-action.resume`, `job.plan`, `job.submit`, `job.run` | all | ruling | Generic leaves; counted only when every operation they reach answers as Swift does, which `flash.dayu200` (external) and the ArkTrace analyses (ruling) prevent |
| `flash.dayu200` | 4 | external | Real flash through the ArkForge lane (AF-W1) |
| `runtime.service.install`, `runtime.service.update` | — | ruling | Refused by ruling 42 (the client-started daemon has no installer); reopening needs a ruling |

No item is blocked only on the board: each device leaf above replays a Swift oracle through the
shared fake HDC. The GJ-1/2/3/5 board window confirms them on the DAYU200 (`REAL_DEVICE_PASS` is
board-only).

## Order of the "now" work

By Golden Journey leaves unblocked: GJ-2/GJ-3 domain leaves (`debug hap`, `debug native deploy`,
`recovery cleanup continue`; done); GJ-1 restart and control actions (done); GJ-1 device
reads (`device wait|list`, `target availability` and `trace probe` done); GJ-1 inputs,
screen record and port forwards (new fake answers); diagnostic sessions; tool register/select;
GJ-5 continuation; Job archive.

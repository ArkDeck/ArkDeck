# Windows: what remains (census as of `main` 2026-10-05)

Source: `openspec/contracts/cli-feature-coverage.json` on `main` after #2541, #2543, #2547, #2549,
#2550/#2553 and #2552. Of the features the Windows CLI must serve, 114 are `implemented`, 46
`partial` and 2 `notImplemented`; 101 are macOS-only. Measured since: `debug.hap@1`,
`deploy.native-library.app-owned@1` and `cleanupDebt.continue` (TASK-XPA-009 domain leaves);
`device.observations`, `target.availability` and `trace.probe` (TASK-XPA-005 device reads);
`runtime.hdc.status`, `.impact-preview`, `.restart` and `control-action.list`, `.show`,
`.reconcile` (TASK-XPA-005, live with the registered `hdc.exe`). A feature is `implemented` on Windows only
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
| `device.display-name.set`, `.clear` | 1 | ruling | No Swift oracle records them. Through the composed Target observation owner (Windows' registered tuple, macOS' development HDC alike) the Host's candidate name owner reads only the legacy provider's snapshot, which that path never retains, so both refuse with `resourceConflict` "No current observation snapshot exists" (seen through the signed CLI, `gj1_device_reads.rs`). Fixing it changes shared Host behaviour without an oracle to hold it to |
| `input.tap@1`, `input.swipe@1`, `input.long-press@1` | 1 | now | `pointer-input` oracle; needs fake answers for it |
| `input.keyboard@1` | 1 | now | No Swift oracle (keyboard input lands with #2473 on macOS); measure against the macOS Rust answers once it merges |
| `capture.screen-sequence@1` (`screen record`) | 1 | now | `screen-sequence` oracle; needs fake answers |
| `port-forward.create@1`, `.remove@1` | 1 | now | `port-forward` oracle; needs fake answers |
| `capture.diagnostic-session@1` | 1 | ruling | Reached through `job submit` alone (a generic leaf). Its live control `diagnostic.session.mark|status|stop` is measured over the `diagnostic-session` oracle through the real CLI (`tests/spawning/diagnostic_session_cli.rs`, TASK-XPA-005) |
| `job.archive`, `job.archive.preview` | — | now | Composed on Windows (#2468); no Swift oracle (Swift retired), measure against the macOS Rust answers |
| `runtime.tool.select` | 1 | now | `runtime.tool.register` is measured (`--kind hdc` over the account composition, `tests/spawning/account_tool_selection.rs`, TASK-XPA-012). Selecting a registered candidate still answers only a drifted action: its impact needs the HDC lifecycle owner's healthy server proof (#2501) |
| `workspace.continuation.run`, `.submit` | 5 | now | `workspace-continuation` oracle |
| `workspace.sign-openharmony-hap@1` (`workspace sign`) | 5 | now | The owner replays `workspace-sign-oracle` (#2508), but the leaf is measured only as the development root's refusal: a development root composes no signing credential owner. Counting it needs the signed CLI against a dev-signed installed-mode daemon with a registered signing preset, as `workspace build` is (`windows_workspace_hvigor_live_process.rs`) |
| `workspace.symbolize-crash@1` (`workspace symbolize`) | 5 | now | The daemon's `--symbolize-crash` mode answers the `crash-symbolizer-oracle` on Windows (#2549); the leaf reads a crash dump that a device capture published, and no Windows run publishes one yet. Measuring it needs that Artifact on the signed test daemon (a capture over the shared fake, or the `workspace-test-symbolize-oracle` root) |
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

# Windows: what remains (census as of `main` 2026-10-05)

Source: `openspec/contracts/cli-feature-coverage.json` on `main` after #2541, #2543, #2547, #2549,
#2550/#2553 and #2552. Of the features the Windows CLI must serve, 114 are `implemented`, 46
`partial` and 2 `notImplemented`; 101 are macOS-only. A feature is `implemented` on Windows only
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
| `debug.hap@1` (`debug hap`) | 2 | now | Domain leaf not measured; `debug-hap` oracle, shared fake `DebugHap` answers, signed test daemon (as `gj23_replay.rs`) |
| `deploy.native-library.app-owned@1` (`debug native deploy`) | 3 | now | Same, `deploy-native-library` oracle, `NativeLibrary` answers |
| `cleanupDebt.continue` (`recovery cleanup continue`, `cleanup-debt continue`) | 2 | now | `gj23_replay.rs` already sends `cleanup-debt continue` through the CLI; neither spelling counted |
| `runtime.hdc.status`, `runtime.hdc.impact-preview`, `runtime.hdc.restart` | 1 | now | Confirmed restart measured live with the registered c2 `hdc.exe` (#2501, #2521, in review); needs the signed-CLI leaf test and the leaves counted |
| `control-action.list`, `.show`, `.reconcile` | 1 | now | Same composition (#2461 owner, #2501); signed-CLI test over the restart's control action |
| `target.availability` | 1 | now | Presence through the registered tuple's listing (#2486); `target-adoption` / `hdc-status` oracles |
| `device.observations` (`device wait`, `device list`) | 1 | now | Composed; `observe-device` oracle via the shared fake, as `gj1_device_leaves.rs` |
| `device.display-name.set`, `.clear` | 1 | now | Local leaves over a device observation; same fake |
| `trace.probe` | 1 | now | `trace-probe` oracle, already replayed at Control level (`trace_probe_control.rs`); no signed-CLI test |
| `input.tap@1`, `input.swipe@1`, `input.long-press@1` | 1 | done | Measured: every `pointer-input` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`); Windows `implemented` |
| `input.keyboard@1` | 1 | now | No Swift oracle (keyboard input lands with #2473 on macOS); measure against the macOS Rust answers once it merges |
| `capture.screen-sequence@1` (`screen record`) | 1 | done | Measured: every `screen-sequence` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`), capability names relabelled as in the GJ-2/3 replays; Windows `implemented` |
| `port-forward.create@1`, `.remove@1` | 1 | done | Measured: every `port-forward` oracle case through the real CLI over the shared fake's ported answers (`gj1_inputs.rs`); Windows `implemented` |
| `capture.diagnostic-session@1`, `diagnostic.session.mark|status|stop` | 1 | now | `diagnostic-session` oracle (#2465); composed on Windows |
| `job.archive`, `job.archive.preview` | — | now | Composed on Windows (#2468); no Swift oracle (Swift retired), measure against the macOS Rust answers |
| `runtime.tool.register` (`--kind hdc`), `runtime.tool.select` | 1 | now | Tuple registered (#2472), selection composed (#2524, #2541); `tool-selection-registry` oracle |
| `workspace.continuation.run`, `.submit` | 5 | now | `workspace-continuation` oracle |
| `workspace.sign-openharmony-hap@1` (`workspace sign`) | 5 | now | `workspace-sign-oracle`; in flight (#2508) |
| `workspace.symbolize-crash@1` (`workspace symbolize`) | 5 | now | `workspace-test-symbolize-oracle`; in flight (#2512) |
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
`recovery cleanup continue`); GJ-1 restart and control actions (after #2501/#2521); GJ-1 device
reads (`device wait|list`, display names, `target availability`, `trace probe`); GJ-1 inputs,
screen record and port forwards (new fake answers); diagnostic sessions; tool register/select;
GJ-5 continuation; Job archive.

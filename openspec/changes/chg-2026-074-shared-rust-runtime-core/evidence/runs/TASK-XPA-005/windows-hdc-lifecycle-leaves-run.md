# TASK-XPA-005 — the registered Windows HDC's lifecycle leaves through the CLI: status, impact preview, restart and control actions

Change: CHG-2026-074-shared-rust-runtime-core over CHG-2026-078. Milestone WM1 (GJ-1).

Base: the `trace probe` layer (`windows-trace-probe-run.md`) on protected `main` `4d163ba1b`,
which carries the confirmed restart (#2501) and its console approval (#2521).

Host: the Windows 11 x64 reference host, non-elevated, with DevEco Studio 26.0.0.43's
`hdc.exe` (`3.2.0g`, SHA-256 `c7951849…6101e`, the registered c2 tuple). No board was attached,
because a restart addresses only the server. Before the run nothing listened on
`127.0.0.1:8710`, and nothing did after it. The daemon started the server, restarted it and
stopped both. No other server was touched. Nothing installed was read or written.

## What

`arkdeck-platform/tests/windows_console_restart.rs` (#2521) runs the real `arkdeck.exe` against
a dev-signed copy of the real daemon. The daemon composes the registered `hdc.exe` as its managed
server. The test now also measures the control-action leaves:

1. **`runtime hdc status`, `runtime hdc impact-preview --action restart` and
   `runtime hdc restart`.** These request the impact approval, as in #2521.
2. **`control-action reconcile` while the action awaits its approval.** A fresh reading of the
   unchanged server proves the reviewed impact. The answer equals `control-action show`, and
   `control-action list --kind hdcLifecycle --state awaitingImpactApproval` lists the action.
3. **The challenge.** It is refused from a redirected stdin and refused when answered wrong at the
   pseudo console. Typed exactly, the restart runs and the action ends `succeeded` with one
   dispatch and a strictly newer, proved server (`runtime hdc status`).
4. **`control-action reconcile` of the finished action.** It reads the action unchanged.
   `control-action list --state succeeded` lists the action as `succeeded`, and the
   awaiting-approval list no longer does.

The six leaves `runtime.hdc.status`, `runtime.hdc.impact-preview`, `runtime.hdc.restart`,
`control-action.show`, `control-action.reconcile` and `control-action.list` join
`WINDOWS_MEASURED_LEAVES`. `arkdeck maintainer contracts export` regenerated the coverage: the six
features move to `implemented` on Windows, and nothing else changes. The census drops their rows.

## Live-only, and what CI still covers

**Live only.** This run's evidence needs `ARKDECK_LIVE_WINDOWS_HDC` and a free
`127.0.0.1:8710`, which CI does not have. Without them the test says SKIPPED and checks nothing.
The live-only parts are:
- every leaf above against a real managed server;
- the impact reading that `reconcile` proves;
- the restart and its proved replacement;
- the console challenge.

`windows_hdc_restart_tests.rs` and `windows_hdc_restart_live_process.rs` (#2501) are live-only
too.

**What CI still covers without a live server:**
- the union control-action owner over the Windows daemon's pipe: `control-action.list` paged
  through its owner-only snapshot and read back after a restart (`windows_lifecycle_process.rs`);
- the HDC control-action owner's own logic: preview, approval, reconcile, drift, invalidation
  and list (`arkdeck-hoststore` `hdc_control_action_tests.rs`);
- the HDC control-action chain on Windows in process against the recorded Swift oracles
  (`windows-hdc-control-actions-run.md`, #2439);
- the CLI's parsing and rendering of all six leaves (`arkdeck-cli` tests).

## Measured (live)

| test | result |
| --- | --- |
| `windows_console_restart` `the_console_approves_a_confirmed_restart` | pass: the redirected resume is refused (exit 2, nothing dispatched), the wrong answer is refused (exit 77, nothing dispatched), and the typed answer runs the restart (exit 0, `succeeded`, one dispatch, newer generation, `arkDeckManaged`); reconcile and list are as above |

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/s1-restart`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-cli -p arkdeck-platform --no-fail-fast` | exit 0: 517 passed, 0 failed; SKIPPED only the live console test (gates run without `ARKDECK_LIVE_WINDOWS_HDC`; its live run is above) and the wildcard-listener cases outside GitHub Actions |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | exit 0 |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check origin/main...HEAD` | exit 0 |
| `arkdeck maintainer contracts check` | exit 0: 242 checked, clean |

## CI

To be recorded by the next slice.

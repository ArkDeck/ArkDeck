# TASK-XPA-011 — `workspace symbolize` end to end through the real CLI on Windows (WM3 GJ-5)

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM3 (GJ-5).

Base: the integration branch `agent/xpa-005-windows-integration-20261005` at `6116bcaad` (#2578).

Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, nothing listened on `127.0.0.1:8710` because of this run, and nothing installed was read
or written. Host tests are not Windows acceptance.

## What

`arkdeck-agentd/tests/spawning/workspace_symbolize_leaf.rs` runs the real signed `arkdeck.exe`
against the signed test daemon (`signed_daemon.rs`):

1. **Registration.** `workspace project register` registers an OpenHarmony project whose
   `entry/build/default/outputs/default/mapping/sourceMaps.map` is the Swift symbolizer oracle's
   `device` source map (`crash-symbolizer-oracle`). `workspace preset register --kind symbol
   --template openharmony.arkts-symbol@1 --relative-source-map …` registers its symbol preset.
2. **The crash.** It is the one the Swift oracle's device capture published
   (`workspace-test-symbolize-oracle/artifacts/job-input-crash`, a device-bound
   `capture.diagnostics` `crash-log.txt`). It is laid into the root's Artifact store, kept, before
   the daemon starts, exactly as the macOS process test (`workspace_symbolize_process.rs`) lays it.
3. **Without a symbolizer** (no `ARKDECK_ANALYZER_PATH`), `workspace symbolize --inputs-file …` is
   refused before admission: exit 65, `invalidInput`, "workspace.symbolize-crash@1 is runtime
   unavailable: workspace.symbolPresetUnavailable", `newDispatchCount` 0.
4. **With the daemon's own build as its symbolizer**, the same leaf run as a person runs it
   (`--inputs-file` naming the project, the crash's lease and the preset; no `--target`, so the
   host scope is the project) ends `succeeded`:
   - `artifact list --job` names one `symbolized-crash.txt`, `sensitive`;
   - the report is byte for byte what `arkdeck_hoststore::symbolize_crash` writes for that map and
     dump, and resolves the frame to `entry/src/main/ets/fixture/CrashProbe.ets:30`.

**Measured leaf.** `workspace.symbolize` joins `WINDOWS_MEASURED_LEAVES`. The leaf is driven
exactly as a user drives it, and its answer depends only on a published device crash Artifact, not
on how that Artifact was captured. `arkdeck maintainer contracts export` regenerated the coverage:
`workspace.symbolize-crash@1` moves to `implemented` on Windows, and nothing else changes.

## Left open: symbolizing the daemon's own capture

Over the shared fake's read-leg answers (`capture-diagnostics-read-legs`), a Windows
`diagnostics capture` with `crashLogs: true` publishes `crash-log.txt` as `missing`: no bytes and
no lease. So a crash this Windows daemon captured itself cannot yet be symbolized here. The root
cause was not found in this slice. The census (`docs/design/cross-platform/windows-remaining.md`)
records it as its own row and drops the `workspace symbolize` row.

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/s1-trace`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot, `arkdeck-cli`
built first.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | GATES_FMT |
| `cargo clippy --workspace --all-targets -- -D warnings` | GATES_CLIPPY |
| `cargo test -p arkdeck-cli -p arkdeck-agentd -p arkdeck-hoststore --no-fail-fast` | GATES_TEST |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | GATES_SHORT |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | GATES_SDD |
| `git diff --check origin/main...HEAD` | GATES_DIFF |
| `arkdeck maintainer contracts check` | GATES_CONTRACTS |

## CI

To be recorded by the next slice.

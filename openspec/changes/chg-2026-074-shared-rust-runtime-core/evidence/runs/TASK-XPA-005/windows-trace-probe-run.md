# TASK-XPA-005 — GJ-1 `trace probe` on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1 (GJ-1).

Base: protected `main` `4d163ba1b` (after the GJ-1 device reads, #2570).

Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, and nothing installed was read or written. Host tests are not Windows acceptance.

## What

**The Runtime.** The Windows daemon now composes Swift's Trace Runtime probe beside the Debug one
(`Host::trace_probe` and `arkdeck-hoststore`'s `trace_probe`, previously macOS-only). It runs over
the same HDC composition: on Windows that is the registered tuple's managed server, or a test
build's fake, as `debug.probe` already does (TASK-XPA-008). Without that HDC it answers as before,
"Trace Runtime probing is not configured". macOS is unchanged.

**The fake.** The shared fake gains the Trace probe oracle's answers
(`trace-probe/hdc-answers.sh`):
- the `hitrace` and `bytrace` help, the tag list and the nine parameters, by mode, from the
  registered resources;
- each call appended to `hdc-calls.log` as the fragment appends it;
- a signal death answered as `kill -9 $$` is, and the 30-second tag read as past its budget;
- the one-second sleeps before an answer dropped: only the log observes the order of the probe's
  concurrent reads, and the log is read sorted.

**The replay.** `gj1_device_reads.rs`
`the_real_cli_probes_trace_as_the_swift_oracle` runs the real signed CLI against the signed test
daemon over the oracle's adopted Target. For each of the oracle's 22 exchanges that the CLI can
spell, `trace probe --target` must answer exactly as Swift's daemon did: the result, or the wire
code and message. The fake must receive Swift's reads, each exchange's concurrent reads sorted as
the oracle records them.

**Not spelled by the CLI (2).** `probe.emptyTarget` (an empty `--target`) and
`probe.noParameters` are not sent: only a direct client sends them.

**Measured leaves.** `trace.probe` joins `WINDOWS_MEASURED_LEAVES`. The regenerated coverage moves
`trace.probe` to `implemented` on Windows, and nothing else changes. The census drops its row.

## Measured

| test | result |
| --- | --- |
| `gj1_device_reads::the_real_cli_probes_trace_as_the_swift_oracle` | pass: 20 answers and every read Swift's |

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/s1-trace`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-cli -p arkdeck-agentd -p arkdeck-hoststore -p arkdeck-provider-hdc --no-fail-fast` | exit 0: 1168 passed, 0 failed, no SKIPPED |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | exit 0 |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check origin/main...HEAD` | exit 0 |
| `arkdeck maintainer contracts check` | exit 0: 242 checked, clean |

## CI

To be recorded by the next slice.

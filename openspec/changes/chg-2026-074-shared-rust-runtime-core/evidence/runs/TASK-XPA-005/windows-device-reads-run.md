# TASK-XPA-005 — GJ-1 device reads on Windows: `device wait`, `device list`, `target availability`

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1 (GJ-1).

Base: protected `main` `814d22fb5` (after #2559, #2501 and #2521).

Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, and nothing installed was read or written. Host tests are not Windows acceptance.

## What

`arkdeck-agentd/tests/spawning/gj1_device_reads.rs` (Windows) runs the real signed
`arkdeck.exe` against the signed test daemon. The daemon composes the production Windows
development root, the shared fake HDC in process, and a synthetic USB census.

**The census per exchange.** The test daemon takes a new input, `CENSUS`: a file naming the boards
the census lists. The test rewrites it before each exchange that plugs boards, with that
exchange's `usbRelations`. A new epoch restarts the read count, and after `reads` reads the census
lists `usbRelationsAfter` (the board replugged mid-adoption). Each board is listed in its
HDC-normal personality and read through the production census relations
(`UsbRegistryRelations`). `target_observation_control.rs` proves on macOS that this reader adopts
exactly as the oracle's relations do.

**The fake.** The shared fake gains the Target adoption answers: the device list unauthorized, or
1001 connected rows, by mode, and otherwise the `capture.diagnostics@1` table it continues with.

**The replay.** The Swift Target adoption oracle (`rust/tests/fixtures/target-adoption`, 21
exchanges) goes through the CLI:
- `device.observations` through `device candidates`;
- `target.adopt` through `target adopt`;
- `target.availability` through `target availability`.

**What must equal Swift's.** Each answer behind the CLI envelope must be the recorded one: the
result, or the wire code, message and details. Comparisons read observation identities as the
oracle's labels and every time as `<time>`, as the macOS Control replay reads them. Then:
- the fake's calls (19);
- `targets.json` and `target-display-names.json`.

**Not spelled by the CLI (3).** The CLI cannot spell these: `adopt.invalid` (no parameters),
`adopt.leadingZero` (generation `01`, which the CLI's positive-integer grammar refuses) and
`availability.missing`. Swift's oracle sent them to its daemon directly. They are not sent, and
the remaining calls and files still equal Swift's.

**Availability's own legs.** Swift's daemon reported its managed HDC and its operations. This
composition's legs are checked against its own sources:
- the tool leg is `absent`, `runtime_tool_unavailable` (no managed server, as on macOS);
- the operations are exactly what `operation list` answers.

**Over the adopted Target:**
- `device wait --state connected` re-proves the exact observation in a fresh snapshot: Connected,
  `relationProven`, still the adopted Target's.
- With the board unauthorized, waiting for Connected stops at the client's own two-second deadline
  with `clientTimeout`: the last observed generation, `newDispatchCount` 0, nothing adopted or
  cancelled.
- Waiting for Unauthorized proves it on the same observation.
- `device list` (Swift's legacy leaf) answers exactly the Target list.

**Measured leaves.** `device.wait`, `device.list` and `target.availability` join
`WINDOWS_MEASURED_LEAVES`. `arkdeck maintainer contracts export` regenerated
`openspec/contracts/cli-feature-coverage.json`: `device.observations` and `target.availability`
move to `implemented` on Windows, and nothing else changes. The stale note on
`WINDOWS_MEASURED_LEAVES` about `device candidates` is dropped, because that leaf is measured.

## Found: device display names

`device display-name set|clear` refuse with `resourceConflict`, "No current observation snapshot
exists". This happens through the composed Target observation owner, which is Windows'
registered tuple and macOS' development HDC alike.

The cause is the Host's candidate name owner (`Host::candidate_display_name`). It reads only the
legacy provider's retained snapshot, and the composed observation path never retains one. No Swift
oracle records these leaves. Fixing this changes shared Host behaviour, so it is left for a
ruling, and the census row says so.

## Measured

| test | result |
| --- | --- |
| `gj1_device_reads::the_real_cli_observes_adopts_and_reads_availability_as_the_swift_oracle` | pass: 18 exchanges, 19 calls, both Target files Swift's |

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/s1-remaining`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-cli -p arkdeck-agentd -p arkdeck-provider-hdc --no-fail-fast` | exit 0: 626 passed, 0 failed, no SKIPPED |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | exit 0 |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check origin/main...HEAD` | exit 0 |
| `arkdeck maintainer contracts check` | exit 0: 242 checked, clean |

## CI

To be recorded by the next slice.

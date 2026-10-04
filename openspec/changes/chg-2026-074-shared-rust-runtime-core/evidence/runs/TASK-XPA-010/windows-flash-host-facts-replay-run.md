# TASK-XPA-010 — the Flash host facts oracle replayed on Windows through Control

Change: CHG-2026-074-shared-rust-runtime-core. This follows #2441 (the HDC-dependent Flash owners on
Windows) and #2449 (the in-process fake HDC). F1 queued it and the lead handed it to M1: add a
separate `FlashHostFacts` answer arm to the in-process fake, without changing the `DebugHap` or
`NativeLibrary` arms, and port agentd's `tests/spawning/flash_host_facts_control.rs` to Windows,
byte for byte against the recorded Swift answers.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The fake's third arm.** `arkdeck-provider-hdc/tests/common/oracle_fake.rs` gains
  `Answers::FlashHostFacts`, picked by the fragment's first line
  (`# flash.prerequisites answers ...`). It ports `rust/tests/fixtures/flash-host-facts/hdc-answers.sh`
  case for case: `list targets -v` by mode (`hdcKey`, `newKey`, `offline`, `empty`, `malformed`,
  and any other mode's failure on stderr with exit 1), the product's full name for either key, and
  `unregistered fixture output` with exit 23 otherwise. The other two arms and `OracleFake::new` are
  unchanged.
- **The spawning binary on Windows.** `tests/spawning/main.rs` builds on macOS and Windows. On
  Windows it compiles only the modules `host.rs` needs (`bootstrap_readers`, `host`,
  `managed_hdc`), the fake by path, and `flash_host_facts_control.rs`. Every other spawning test stays macOS-only, unchanged.
- **The Host's test-only seam.** `host.rs` gains, under `#[cfg(all(windows, test))]` only, a
  `flash_test_hdc` field and `with_flash_test_hdc`. In a Windows test build, `flash_hdc` returns that
  fake when one is composed, else the host's own HDC. Without `test` (every production Windows
  binary), `flash_hdc` is the host's HDC as #2453 left it, which is none until a Windows HDC tuple
  is registered, and the field and builder do not exist. macOS is unchanged.
- **The replay on Windows.** The same three tests run with the same assertions:
  - all 74 exchanges compared to Swift's answers, byte for byte, and to Swift's HDC calls;
  - the 8 previews that reached the lane, with their lane calls;
  - the root's leftovers, their bytes and their modes.

  Platform spellings:
  - The Application Support root and the fake's root are fresh directories below `TEMP`. Every
    level of the root is the host store's private directory.
  - A recorded mode is the DACL the store reads. A written file inherits owner-only. A mode with
    group or other bits (`644`) grants the local Users group read access, as
    `hoststore/tests/rockchip_startup.rs` does. The final check reads `600` and `700` as a document
    the store opens owner-only, and `644` as one it refuses.
  - `arkforged` is written `arkforged.exe`, the image a Windows lane measures (Windows reads a
    provider executable as an `.exe`). A relative daemon name stays relative.
- **The gate, proven.** For each of the 19 exchanges that reached the fake, the same request is
  also sent over the composition without the seam, as the production Windows daemon composes it.
  The fake must see no call.

## Measured on Windows

| Test (`cargo test -p arkdeck-agentd --test spawning`) | Result |
| --- | --- |
| `the_rust_daemon_replays_the_swift_flash_host_facts_oracle` | ok: 74 exchanges, 8 lane previews, 19 with HDC calls, each also run with no HDC composed |
| `a_host_without_the_facts_answers_as_swifts_daemon_without_its_observers` | ok |
| `members_swift_ignores_change_neither_the_reads_nor_the_answers` | ok |
| `the_daemon_modules_compiled_here_keep_no_tests_beside_them` | ok |

A mutation check, reverted before commit: answering `hdcKey` mode's list with the other key turns
exchange 38 (`prerequisites.hdcUnprepared`) red. The full name the fake answers is not projected
into any answer, on macOS or Windows.

## Left out

- The production Windows daemon still composes no HDC. `ARKDECK_DEVELOPMENT_HDC_PATH` stays
  refused until the Windows HDC tuple is registered (CHG-2026-078).
- The CLI's `flash` leaves over this oracle (`arkdeck-cli/tests/flash_host_facts.rs`) stay
  macOS-only. On Windows they need a daemon with an HDC.
- **Delegated minor decision, pending the next rulings batch.** The replay probes through a Host
  seam compiled into test builds only (`cfg(all(windows, test))`), not through the production
  composition. It is a stand-in in tests and relaxes no gate. The production composition's
  no-HDC answer is checked beside each exchange.

## Local targeted checks

The environment set `CARGO_TARGET_DIR=D:/cargo-target/m1-fhf`, `CARGO_BUILD_JOBS=2` and
`ARKDECK_DEV_SIGNER_THUMBPRINT`. The checks ran on `origin/main` `382c98a9` with this change.

| Command | Exit |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-agentd -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-cli --no-fail-fast` (0 SKIPPED) | 0 |
| `cargo test -p arkdeck-agentd --test spawning` and `-p arkdeck-provider-hdc` with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 |
| `sh scripts/check-sdd.sh`, `git diff --check` | 0 |
| macOS: `cargo check` and `cargo clippy -D warnings`, `--target aarch64-apple-darwin --workspace --all-targets`, with `xcrun`, `ar` and `cc` stubbed | 0 |
| Linux: the same for `--target x86_64-unknown-linux-gnu` | 0 |

## CI

This is recorded by the next slice.

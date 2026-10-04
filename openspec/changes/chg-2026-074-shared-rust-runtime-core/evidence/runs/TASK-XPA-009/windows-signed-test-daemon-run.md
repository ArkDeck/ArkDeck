# TASK-XPA-009: the signed test daemon, a Windows harness for device Jobs end to end over a fake HDC

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM2 (GJ-2 and GJ-3), slice CI2.
Base: protected `main` `955cf537` (#2469).
Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, and nothing installed was read or written. Host tests are not Windows acceptance.

## Why

GJ-2 (`debug.hap@1`) and GJ-3 (`deploy.native-library.app-owned@1`) have to be measured end to end
on Windows: `job plan|submit|run` through the signed CLI, answered as Swift's oracles answered.

- **What blocks it.** The production Windows daemon composes an HDC only for a registered Windows
  HDC tuple. It has no fake-HDC input, and a development root runs no fixture HDC (rulings 26 and
  51). A fake cannot carry a registered tuple's digest, and the trust check is not weakened for
  one.
- **What allows it.** Ruling 71 lets a test build compose a stand-in through a seam compiled into
  `cfg(all(windows, test))` only, which relaxes no gate.

The lead chose option (a): the daemon composed in process inside the agentd test binary, the fake
given through a test-only constructor, and the real signed CLI talking to it over the pipe. This
slice builds that harness, as its own PR. Two later slices use it:

- M1's Windows `fn hdc()` and the planner, admitter and runner wiring;
- the GJ-2 and GJ-3 replays: 63 and 40 exchanges, relabelled as rulings 48 and 61 rule.

## What

- **The child.** `arkdeck-agentd/tests/spawning/signed_daemon.rs` (Windows) adds the test
  `signed_daemon::the_signed_test_daemon`. It returns at once in any ordinary run. When its two
  variables name a fixture and a fake root, it serves as `arkdeck-agentd`'s Windows serve does
  (`src/main.rs`), in this order:
  1. takes the development root through `windows_lifecycle::start`, which applies the same tuple
     gate and refusals;
  2. composes the bundled code-sign helper beside its executable (`code_sign_helper::bundled`);
  3. composes the owners through `Authority::compose`, and refuses if a managed HDC server comes
     out of it;
  4. only then gives the Host the shared oracle fake (`oracle_fake.rs`) for the fixture's
     `hdc-answers.sh`, answering as the recorded driver whose digest is the fixture's `hdc`;
  5. recovers Jobs and staged Sessions, sweeps Artifacts, prints the listening line, serves
     `arkdeck_agentd::serve_control`, drains, releases the root and prints the stopped line.
- **The parent side.**
  - `signed_copy` copies this test binary and signs the copy with the host-trusted development
    signer (`scripts/windows-dev-identity.ps1 sign`), as the process tests sign
    `arkdeck-agentd.exe`.
  - `SignedDaemon::start` runs the copy with `--exact` on that test, with every `ARKDECK_` and
    `OHOS_HDC_` variable removed.
  - `SignedDaemon::cli` runs the real `arkdeck.exe` with `ARKDECK_DAEMON_PATH` and
    `ARKDECK_DAEMON_SIGNER_SHA256`, so the CLI's peer check is the production one.
  - `stop` asks for the stop through the root's scope and waits for the drained end.
- **The Host seam.** `with_flash_test_hdc` becomes `with_test_hdc(dispatch, tool_sha256)`, with a
  `test_hdc()` accessor for the planner, admitter and runner wiring. It is still compiled into
  `cfg(all(windows, test))` only, so `arkdeck-agentd.exe` has neither the field nor the
  constructor. The Flash host facts replay passes the fixture's driver digest.
- **The modules the child compiles.** `tests/spawning` now also compiles `windows_lifecycle`,
  `windows_hdc_gate`, `code_sign_helper`, `arkforge_lane`, `arkforge_execution`,
  `development_usb` and `hilog_summary_analyzer`. Their unit tests stay beside them inside
  `daemon_unit_tests!`:
  - `src/main.rs` expands that block under `cfg(test)`, so the daemon's unit-test build runs them
    as before;
  - `tests/spawning` expands it to nothing, so they never run in that binary;
  - the binary's existing guard (`the_daemon_modules_compiled_here_keep_no_tests_beside_them`) now
    lists these modules and requires the block to be each module's last item.

## Measured

`the_real_cli_drives_the_signed_test_daemon_over_its_pipe` starts the signed copy over a fresh
development root, with the debug-hap fixture's fake. Then:

- **The daemon's own signer.** `arkdeck job list` through the real CLI succeeds (exit 0, `ok`).
- **Any other signer pin.** The same CLI refuses the same daemon (non-zero exit, `ok: false`).
- **Shutdown.** The child drains and stops (exit 0).

The fake is not exercised yet: no Windows planner or runner reads the Host's HDC until M1's wiring
lands.

## Delegated minor decisions, pending the next rulings batch

- **The harness shape:**
  - the agentd `tests/spawning` binary serves as a signed copy of itself;
  - it goes through the production `windows_lifecycle` start and composition;
  - the fake reaches the Host only through the `cfg(all(windows, test))` seam, after the
    composition;
  - the real signed CLI talks to it with the production peer check.
- **`daemon_unit_tests!`**, so that a module the spawning binary compiles keeps its unit tests
  beside it without them running there.
- **The child's serve is a short copy of `src/main.rs`'s Windows serve.** It covers start, helper,
  compose, recovery, serve and drain. It is not shared code, because `serve()` lives in the
  binary's root. A later change that alters that sequence must change both.

## Left out

- **The GJ-2/3 replays and `fn hdc()` on Windows.** They come next, on top of M1's wiring.
- **The measured leaves.** `job.plan`, `job.submit` and `job.run` are not added to
  `WINDOWS_MEASURED_LEAVES`. They are added only once every operation they reach on Windows answers
  as Swift does, as the lead ruled.

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/ci2-gj23`,
`ARKDECK_DEV_SIGNER_THUMBPRINT` set.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-agentd --no-fail-fast` | exit 0: 108 passed, 0 failed, 0 ignored, no SKIPPED; the daemon's 21 unit tests include the `daemon_unit_tests!` modules |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: (`AD-SHO~4`) | exit 0: the same counts |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) check and clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check` | exit 0 |

## CI

To be recorded by the next slice.

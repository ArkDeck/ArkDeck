# TASK-XPA-016 — agentd's tests that spawn children leave its unit-test binary

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane A, test-only: no product behaviour
changes. Host measurement only; nothing here is device evidence.
Base: protected main `333023ae4` (#2154); measured first on `4b89780f3` (#2153).

## Why

macOS has no `SOCK_CLOEXEC`: Rust's std makes a socket with `socket()` and only then marks it
close-on-exec. `std::process::Command` spawns without `POSIX_SPAWN_CLOEXEC_DEFAULT`, so a child
spawned by another thread in between keeps that socket — bound and listening once its maker
binds it — for as long as the child lives; and any child shares every descriptor of the process
until its exec (the flock window of #1899/#1903). `arkdeck-platform`'s spawns close everything
on exec and leak only for that window.

`arkdeck-agentd`'s unit-test binary ran 102 tests in parallel. 20 of them started children
(table below) while the others listen and take kernel locks in the same process. Seen so far:

- #2152 (head `d86b24a1a`), macos-26 Rust workspace job, 2026-09-24T20:01Z:
  `production::tests::a_held_transport_or_a_live_listener_refuses_the_claim_and_lets_go_of_the_lock`
  — the claim after a refusal found the dropped listener's socket still live. #2152 made the case
  wait for a refused connection; a compiler child can still hold the socket for its whole compile.
- #2154 Swift CI run `36060676331` attempt 1, job `107838934786` (macos-26):
  `managed_hdc::tests::host_never_claims_zero_dispatch_after_lifecycle_audit_failure` at
  `managed_hdc.rs:791` — "a listener that is not the configured HDC executable holds it"
  (attempt 2 passed). The M4 lane saw the same message locally.

The second is a loopback port `free_port()` released for a managed HDC server while another
test's `cc` or fake `hdc` (both `Command` children) had taken the probe socket with it.

## What changed

- New integration test binary `rust/crates/arkdeck-agentd/tests/spawning` (`main.rs` and six
  modules), one test at a time (`turn()`, as `tests/production_composition.rs` already does):
  - `managed_hdc_server.rs` — the 7 tests of `src/managed_hdc.rs`;
  - `debug_read_control.rs`, `flash_host_facts_control.rs`, `target_observation_control.rs`,
    `trace_probe_control.rs` — moved from `src/` (`git mv`; 2 + 3 + 3 + 2 tests);
  - `app_ingress_fake_hdc.rs` — the 6 App ingress tests that run a production Host over a fake
    HDC script (5 from `job_tests.rs`, 1 from `import_tests.rs`), with the two helpers only they
    use;
  - a guard that the daemon modules compiled here keep no test beside them (negative control:
    a test module added to `bootstrap_readers.rs` fails it).

  The daemon is a binary, so the modules these tests drive (`app_ingress`, `bootstrap_readers`,
  `facade`, `facade_owners`, `host`, `managed_hdc`) are compiled into the new binary from their
  sources with `#[path]`; `app_ingress.rs` names its two submodules by path so that they resolve
  the same way there. Test bodies are moved verbatim: only imports, the `turn()` line, the
  depth of two `include!` paths and rustfmt's reflow differ (checked by a normalized comparison).
- Those modules keep no test module beside them; their unit tests are declared by `src/main.rs`
  and stay in the unit-test binary: `src/host_tests.rs` (host's 8), `src/facade_owners_tests.rs`
  (4) and the App ingress tree (`src/app_ingress/tests.rs`, now `app_ingress_tests`), whose
  shared fixtures moved to `src/app_ingress/fixtures.rs`, declared by both binaries. What those
  tests reach is `pub(crate)` instead of private — in a binary crate that exposes nothing
  outside it: `host`'s `ObservationState`, `RunSlot`, `RunClaim`, four `Host` fields,
  `authority`, `claim_run`, `timestamp`; `managed_hdc`'s `ForegroundLifecycle` and
  `foreground_exit`; `app_ingress`'s `AppIngress`, `Handler`, `Configuration::isolated` /
  `listen_with`, the `jobs` module and its `Kind`, `Action::parse`, `Gate::record_reply` /
  `owns`.
- Integration binaries that listen or take a lock in their own process while spawning now run
  one test at a time too: `managed_hdc_process.rs` (9 tests, `free_port`/`issued_listener`
  beside compilers, daemons and fake `hdc`s), `control_action_host_process.rs` (2, the same) and
  `cutover_preflight.rs` (9; one holds Swift's instance lock while the others spawn the daemon).
  `production_composition.rs` already did. The other eight binaries have one test, or open no
  listener and take no lock in their own process.
- `rust/README.md`: where such a test belongs.

No assertion was relaxed, no sleep added, no test removed: the base's 148 agentd tests all
run, plus the guard (unit-test binary 107 → 84, `tests/spawning` 0 → 23 + 1, the other twelve
binaries 41 → 41). M4-4a's two new in-process modules (`loader_binding_control.rs`,
`app_ingress/loader_binding_tests.rs`) stay in the unit-test binary.

## Evidence

A local `DYLD_INSERT_LIBRARIES` interposer (not committed) records every `posix_spawn`,
`posix_spawnp` and `fork`, every `listen` and every `flock` of the test process, with libtest's
thread name. Each test was run alone under it:

| Unit-test binary | tests | tests that spawn | spawn calls, whole run | listen / flock, whole run |
| --- | --- | --- | --- | --- |
| before (`4b89780f3`) | 102 | 20 | 512 | 22 / 1931 |
| after (`333023ae4`) | 84 | 0 | 0 | 12 / 712 |

The 20: `managed_hdc::tests` 6 (`cc`, `/bin/kill`, the fake `hdc`, `sysctl`, plus the
platform's), `app_ingress::tests` 6, `debug_read_control` 2, `flash_host_facts_control` 1,
`target_observation_control` 3, `trace_probe_control` 2 (fake HDC scripts through the verified
dispatch; `trace_probe` alone makes 222).

Plain parallel runs on a quiet host (load 1.3–2.5):

- before: 10/10 passed (25.6–26.2 s); with every socket held open 20 ms before it returns,
  3/3 passed. Chance alone does not reproduce it here.
- after: unit-test binary 10/10 passed (1.8–2.1 s); `tests/spawning` passed every run (49–59 s
  quiet; 73 s and 117 s while another session's tests ran).

A rendezvous probe makes the race happen whenever it can: `socket()` holds its descriptor
2 ms before returning (the std window, widened), and a spawn without
`POSIX_SPAWN_CLOEXEC_DEFAULT` first waits up to 0.3 s for another thread to be inside such a
window (`met`, else `alone`); AF_INET only.

| Binary | runs | failed runs | spawns met / alone |
| --- | --- | --- | --- |
| unit tests before | 5 | 4 (1, 4, 4, 4 tests) | 1–7 / 7–14 per run |
| unit tests after | 3 | 0 | no spawn |
| `tests/spawning` | 3 | 0 | 0 / 18 per run |
| `control_action_host_process` before / after | 3 / 3 | 1 / 0 | 1–2 / 0 |
| `managed_hdc_process` before / after | 3 / 3 | 0 / 0 | 24–26 / 0 |

Every failing test before was a managed HDC server start: "the managed HDC server did not
start: managed HDC endpoint was not absent before the foreground launch: a listener that is not
the configured HDC executable holds it" — #2154's CI failure; `control_action_host_process`'s
was its daemon's start (EOF on the first answer). With 2–100 ms windows and 3 s waits, the
`managed_hdc` tests alone failed in 2 of 13 runs the same way.

## Local targeted checks

With `CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, on `333023ae4`:

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-agentd --all-targets -- -D warnings`, host and
  `--target x86_64-unknown-linux-gnu` / `x86_64-pc-windows-msvc`: exit 0 (an earlier draft's
  imports failed the Linux check, which is how it was found).
- `cargo test -p arkdeck-agentd --no-fail-fast`: 14 targets, 149 passed, 0 failed (unit tests
  84 in 1.9 s, `tests/spawning` 24 in 50 s); no fake `hdc` left behind
  (`ps -axo ppid=,command= | awk '$1==1 && $2 ~ /arkdeck-managed-hdc-unit-/'`: 0).
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract input changed;
  the latter's views run the same workspace tests in CI), Swift, App, devices.

Logs: `/private/tmp/arkdeck-s24-*.log`; runs and probes: `/private/tmp/arkdeck-s24-runs/`.

## Left as they are

Integration binaries without an in-process listener or lock can still pass pipes between
concurrent `Command` children (`artifact_retention_process`, `crash_ledger_analyzer`); that
delays an EOF at most and is not this change's class. Other crates' test binaries were not
surveyed. `tests/spawning` runs its tests one after another (about 50 s here); if the macOS
lane's time matters, the tests that spawn only through `arkdeck-platform` could share a turn,
at the cost of a subtler rule.

## CI

Pending (this PR).

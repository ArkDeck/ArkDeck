# TASK-XPA-016 — SPK-6 run record: a vanished candidate is not a failed scan

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-6 (design §J.3), a
correction to phase 1 (`spk-6-run.md`, #1914) of lane B. Host measurement only — not hardware,
platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device was contacted and no
HDC executable was launched: every listener here is a process of the test binary or `/usr/bin/nc`.

Base: protected main `1b31a53f` (#1923). Branch `agent/xpa-016-lease-scan-vanished-20260914`.

## What was wrong

Lane A's gate for #1920 (run r2, 2026-09-14, load about 12 on 8 cores) failed in
`tests/loopback_server_lease.rs`: `an_existing_loopback_listener_of_the_verified_executable_is_proved_without_a_connect`
got `PermissionDenied: macOS socket scan failed for the selected HDC process`, and a rerun of the
binary alone failed `no_process_on_the_endpoint_is_unavailable_not_unknown` the same way. The
lease selects candidates by executable path; the five tests ran in parallel threads, each spawning
and killing its own `/usr/bin/nc -l`, so every scan walked the other tests' listeners too, and a
listener that exited between `proc_listallpids` and its `PROC_PIDLISTFDS` read made
`arkdeck_macos_listening_sockets` return -1, which `scan` reported as an unscannable process. Any
`nc` on the machine from another session was a candidate as well. A real HDC server restarting
under a scan would have parked the observation the same way.

## What changed

- `src/macos_procscan.c`: `errno` is cleared before each `proc_pidinfo(PROC_PIDLISTFDS)` and an
  `ESRCH` failure returns -3 (the process no longer exists) instead of -1.
- `src/macos_server.rs`: `listening_sockets` returns `Err(ScanFailure::Vanished)` for -3 and
  `Err(ScanFailure::Unscannable)` otherwise; `registered_listener_count` maps them to
  `ListenerScan::Vanished` / `::Failed`; `scan` skips a vanished candidate (it owns nothing now; a
  server changing under the scan is still caught by the two scans having to agree) and keeps
  `Failed` as `PermissionDenied` (Swift's `unknown`: a process the kernel will not describe, such
  as another user's, may own the endpoint). `revalidate` is unchanged: the observed process
  vanishing is still `identity changed`.
- `tests/loopback_server_lease.rs`: the listener is the test binary itself, re-executed with
  `listener_process` selected and the endpoint named in `ARKDECK_LEASE_LISTENER_HOST/PORT`, so the
  candidate population is this binary's own processes and never any `nc` on the machine. A private
  copy of `/usr/bin/nc` was tried first and is not an option: the kernel kills a copied Apple
  platform binary (exit 137). `/usr/bin/nc` stays, in place, only as the listener of another
  executable. New case `listeners_of_the_executable_that_come_and_go_on_other_ports_do_not_disturb_the_verdict`:
  three listeners of the verified executable are spawned and killed around each scan of an
  endpoint nothing owns for 3 s, and every verdict is `NotFound`.
- `src/macos_server.rs` unit test: a PID the kernel has no process for is `Vanished`; PID 1 is
  `Unscannable` for a non-root caller.
- `rust/README.md`: the server-identity paragraph names the rule.

## Tests

- `cargo test -p arkdeck-platform --lib macos_server`: 2/2.
- `cargo test -p arkdeck-platform --test loopback_server_lease` (7 tests, parallel threads):
  10 of 10 sequential runs passed; 6 of 6 runs passed with two instances of
  the binary running at once (each instance's listeners are the other's candidates, exactly the
  cross-session case). Load during the runs: 11–18 on 8 cores.
- `cargo fmt --check` and `cargo clippy --tests` for the crate: clean.

## Not run, and why

- No real HDC server: the rule is exercised with listeners of the test binary; an `hdc` restart
  under a scan is the same race (a process listed, then gone) and needs no device.
- The `Unscannable` path with a foreign user's listener at the endpoint is not exercised (it needs
  a second account); PID 1 stands in for the kernel's refusal.

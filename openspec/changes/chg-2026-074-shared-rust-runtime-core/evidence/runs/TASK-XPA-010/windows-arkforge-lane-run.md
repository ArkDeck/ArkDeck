# TASK-XPA-010 — WM4 part A: the ArkForge lane starts and pairs `arkforged.exe` on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM4, GJ-4 (D2, destructive): software
part only. This is the first of the ordered PRs of the slice: part A. Part A launches and pairs
the lane's daemon. The later parts are the Flash planner, the Flash run, and the daemon's
composition.

Branch `agent/xpa-010-windows-flash-lane-a-20260930`, one commit on `origin/main` `565f8b1d`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, and no HDC, board or USB host was used; no `hdc` was run.
- No real `arkforged.exe` ran. AF-W1 (ArkForge green on a real Windows host) is an external
  dependency, and nothing was pushed to the ArkForge repository.
- The daemon every case launches is a stand-in: the lane's own test binary, placed in a verified
  bundle.
- Host tests are not Windows acceptance, and nothing here is device evidence.

## What

| Crate | Item | Notes |
| --- | --- | --- |
| `arkdeck-platform` | `ManagedServer::launch_paired` (Windows) | Ports Swift's `IdentityBoundDaemonLauncher`. The verified `.exe` is created suspended in its own kill-on-close Job, with its image proved before it runs, as for every Windows child. It runs in a canonical working directory (the tool request's rule). Its stdin is the read end of an anonymous pipe. That pipe is the one extra handle the child inherits, and its write end is not inheritable. The secret is written whole and never kept. If the whole secret does not reach the child, the child is terminated and the launch refused. The write end stays in the server as its liveness. |
| `arkdeck-platform` | the paired stop and drop (Windows) | The order is end of input first, then half a second for the server to end on its own, then `TerminateJobObject`. Dropping without stopping ends the server the same way. The stop gives the same exit and capture as the macOS stop. An unpaired server is still ended by its Job alone, as before. |
| `arkdeck-platform` | `process::spawn_paired`, `input_pipe` | Before this, `spawn_with` always opened `NUL` as stdin. It now takes an optional inherited input handle instead. Every other caller passes none and is unchanged. |
| `arkdeck-contract` | `arkforge_bundle` on Windows | The same `arkforge.release-bundle/v1` reader. The two executables have Windows paths, `bin/arkforge.exe` and `bin/arkforged.exe` (see [the delegated minor decisions](#delegated-minor-decisions)). Member paths are joined one component at a time, because a canonical `\\?\` root takes no `/`. Relative paths found while enumerating are `/`-joined. On macOS the paths and results are unchanged. |
| `arkdeck-provider-arkforge` | `Lane` on Windows (`lane` is built on macOS and Windows) | `Lane::compose` is the same composition, with three Windows differences. (1) The runtime directory is canonicalized first. (2) Instead of removing stale socket files, it refuses before launching anything if any process already serves the lane's public or controller pipe for that directory. (3) Instead of waiting for `controller.sock` to appear, it connects to the controller pipe every 50 ms within the same 10 s. Only an absent pipe, or one that closed during its handshake, is waited for; any other refusal is the daemon's answer. A session answered after the launched generation has ended counts as never opened. Readiness, the refusals and their Swift words are unchanged. |
| `arkdeck-provider-arkforge` | `authority_support` test | `host_platform()` is asserted as `windows/x86_64` on this host. |

The lane still reaches ArkForge only through `arkforge-client`. The `arkdeck-provider-arkforge`
production edges are unchanged (the rule in `scripts/check-readonly.py`). `arkforge-platform` is added to the
workspace at the same pinned revision (`scripts/check-arkforge-pin.py`). It is a Windows-only
dev-dependency of the provider's stand-in daemon.

## Tests

`arkdeck-provider-arkforge/tests/lane.rs` (`harness = false`) now runs on Windows. The stand-in
is this test binary, placed as `bin/arkforged.exe` of a verified bundle.

- It reads the 32-byte secret from stdin.
- It binds ArkForge's own public and then controller named pipes for its runtime directory, with
  `arkforge-platform`'s listener, the transport `arkforged.exe` serves.
- It acknowledges each session with the readiness its profile names, bound to its own bytes'
  digest.
- It ends at its end of input with status 11.

| Case (Windows) | Proves |
| --- | --- |
| `a_bundle_composes_one_paired_ready_daemon_that_ends_with_its_owner` | Composition works end to end, and the profile reference is `org.openharmony.dayu200@1.0.0`. The secret arrived whole on stdin and never in argv. The argv is exactly `--runtime-dir <canonical> --profile <bundle profile> --pair-from-stdin <epoch>`. `DeviceAccessObserver` answers through the public pipe. The stop exits with 11 at end of input, and the controller pipe is no longer served. The generation stops only once. |
| `a_served_runtime_directory_is_never_taken_for_the_new_daemon` (replaces the macOS stale-socket case) | A live process that already serves the public pipe gets no new daemon launched: no `paired`, `pid` or `alive` file exists afterwards. |
| `a_daemon_that_is_not_ready_is_stopped_and_refused` | Both refusals are Swift's words: `NO_DISPATCHER`, and toolchain `replay`. The generation ended at its end of input before the refusal returned. |
| `a_daemon_that_never_opens_its_socket_is_stopped_and_refused` | A daemon that exits at once gets Swift's refusal in under 5 s, not after the 10 s deadline. |
| `nothing_is_launched_before_the_profile_and_the_authority_are_proved` | Nothing is launched for a wrong profile id, an absent agentd digest, an absent HDC digest, or daemon bytes changed after they were measured. |
| `a_dropped_lane_ends_a_daemon_at_its_end_of_input` | Dropping the lane: the stand-in records `eof` then `exit 11`. The drop took about 6 ms, well under the half second. |
| `a_dropped_lane_terminates_a_daemon_that_outlives_its_input_after_its_grace` | A stand-in that ignores its end of input records `eof`. Its Job is terminated 507 ms after the drop began, and nothing of it is left: its lifelong lock is free and neither pipe is served. |

`arkdeck-platform/tests/windows_tool_dispatch.rs` gains four paired cases. The fake role is
`paired`.

| Case | Proves |
| --- | --- |
| `a_paired_server_reads_its_secret_and_ends_when_its_owner_lets_go` | The secret arrives whole in the canonical working directory. The server runs while its owner holds on. The stop ends it with `Exited(11)` in under 500 ms. Nothing but the secret crossed the pipe. |
| `a_paired_server_that_outlives_its_input_is_terminated_after_its_grace` | It reached its end of input. The Job was terminated no earlier than 500 ms later (`Exited(1)`). |
| `a_dropped_paired_server_gets_its_end_of_input_before_its_job_ends` | A drop without a stop still closes the input first. |
| `a_paired_launch_needs_a_canonical_existing_working_directory` | A relative directory, a missing directory, or a non-`\\?\` spelling of the directory is refused with `InvalidInput`, and nothing runs. |

The macOS cases and their stand-ins are unchanged; their `cfg` is now `unix`. `serve` takes any
`Read + Write` stream.

## Local targeted checks

The environment for every check:
`ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149` and
`CARGO_TARGET_DIR=D:/cargo-target/f1-flash`.

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean (Windows) |
| `cargo test -p arkdeck-platform -p arkdeck-contract -p arkdeck-provider-arkforge` | all pass, 0 failed, 0 skipped: `lane` 7/7, `windows_tool_dispatch` 25/25 |
| The same with `TEMP`/`TMP` set to the 8.3 spelling `C:\Users\fuhan\AppData\Local\Temp\F1-FLA~1` | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | pass |
| `python rust/scripts/check-arkforge-pin.py` | pass (five ArkForge crates at `c1dc0553`) |
| `git diff --check` | clean |

Not run here:

- `rust/scripts/check-readonly.py`. This host's Python has no `jsonschema`. The edge rule it
  enforces reads only `[dependencies]` tables, and this change adds none: the one new edge is a
  dev-dependency.

- the macOS build and the macOS stand-in cases. There is no macOS host, and the macOS cross-check
  cannot build `arkdeck-platform`'s C sources on this host. The macOS lines are only moved behind
  `cfg(unix)` or cfg-selected constants with the same values.
- Linux. It does not build `lane` (as before).

## Delegated minor decisions

These are pending the next rulings batch.

1. **The Windows release-bundle layout.** A Windows child must be an `.exe` image, so on Windows
   the manifest's `cli` and `daemon` roles have the Windows paths `bin/arkforge.exe` and
   `bin/arkforged.exe`. Those are the paths ArkForge's own Windows package uses
   (`packaging/windows/package-arkforge.ps1` at the pinned revision). The manifest, its schema and
   the profile members are unchanged. ArkForge's Windows package itself is
   `arkforge.windows-runtime/v1` and carries no DeviceProfile. So a Windows `ArkForge.bundle` is
   still assembled for ArkDeck, as on macOS. AF-W1 may publish its own layout; the reader follows
   it then.
2. **The paired stop without TERM.** macOS closes the input, sends TERM (which `arkforged` starts
   ignoring), and KILLs half a second later. Windows has no TERM and cannot deliver a console
   break to a console-less child. So its stop is the end of input, then the same half second,
   then `TerminateJobObject`. The effective grace before the forced end matches macOS.
3. **A served pipe instead of a stale socket.** ArkForge's pipes are named from the canonical
   runtime directory. A live process keeps its pipe name, and `FILE_FLAG_FIRST_PIPE_INSTANCE`
   stops a second daemon from binding it. So the lane refuses before launching when either pipe
   answers, rather than pair with a daemon it did not start. A session answered after its own
   generation ended is treated as never opened.
4. **`arkforge-platform` as a Windows dev-dependency**, only for the stand-in's pipes. The
   production edge rule (the lane reaches ArkForge only through its client) is unchanged.

## Left out, and why

- **Planning, execution and composition in the daemon.** These are the later parts of this slice,
  in this order:
  - (B) the Flash planner, and the `flash-plan` oracle replayed on Windows;
  - (C) the Flash admission and run by StepPermit, with readback, rebind, postflight and fault
    injection, over the fake lane;
  - (D) the Windows daemon composing the lane from `ARKDECK_ARKFORGE_BUNDLE_PATH`.
- **The real `arkforged.exe`.** It needs AF-W1 and the maintainer's HardwareCampaign window
  (phase A).

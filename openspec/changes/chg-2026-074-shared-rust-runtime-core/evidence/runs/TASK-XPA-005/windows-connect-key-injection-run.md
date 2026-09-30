# TASK-XPA-005 — WM1: `-t <connectKey>` at the single injection point

Change: CHG-2026-074-shared-rust-runtime-core. WM1, TASK-XPA-005. The task's production reachability
reads: "`hdc.exe -t <connectKey> …` through the single `deviceArguments` injection point". Its
XPA-AC-2 verification: "fake process face asserts the real argv (with `-t`)".

Branch `agent/xpa-005-windows-connect-key-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## What

`arkdeck-provider-hdc`:

- `device_arguments(connect_key, command)` (Swift `deviceArguments`) is the one function that
  writes HDC's `-t <connectKey>` before a device command's own arguments. The flag's only literal
  is the private `TARGET_FLAG`.
- Eleven plan builders wrote `-t` themselves; each now calls it:
  - `Action::lower` (observation, properties, storage, HiLog, window list);
  - the capture file plans;
  - the Debug HAP plans and the Debug read templates;
  - the native library deployment;
  - port forwarding and pointer input;
  - the trace probe and live mode's build-property read;
  - the Rockchip HiLog and post-flash property reads, and the Loader entry.
- The argv they produce is unchanged, byte for byte: the same vectors, built in one place. The
  unit tests that pin each plan's argv pass as before.
- `operation::tests::every_target_flag_is_added_here` fails if any non-test source in the crate
  writes `-t` before a connect key, or names `TARGET_FLAG` outside `operation.rs`. A device-side
  `-t` (a trace tag, an image type) follows a command, never a connect key, and is not matched.
  The scan found five builders the first pass missed (live mode, pointer input, the two Rockchip
  modules and the trace probe) before they were converted.

`arkdeck-provider-hdc/tests/windows_managed_hdc.rs` (#2341's `harness = false` binary):

- The fake gains a device face: run as `<exe> -t <key> …`, it records its argv and answers the
  product-name read.
- New test `a_device_plan_reaches_the_child_with_its_connect_key_first`:
  - A lowered `QueryProperty(ProductName)` plan runs through the Windows `ProcessDispatch`
    (`CreateProcessW` argv array, no shell). The child receives exactly
    `-t <key> shell param get const.product.name`, and its answer reaches the receipt.
  - With no connect key, or an empty one, there is no plan, and nothing runs.

No other crate builds HDC argv: `arkdeck-hoststore`'s only `-t` literals are in its tests.

Found on the way and fixed in the same harness: every `FakeHdc` left its scratch directory, with a
copy of the test binary, in `TEMP` (92 on this host). Its `Drop` ran while its `VerifiedTool` field
still held the copy open. The directory is now removed by a guard dropped last. One directory
still remains per run: the unbound-launch case's, whose parked server child is still ending when
the guard runs.

## Not reached, and why

The daemon composes no HDC on Windows until the HDC tuple is registered, so no device plan
reaches a real `hdc.exe` there. That refusal is covered by `windows_kill_matrix_process.rs` and
the earlier Windows slices.

## Local checks

Run on Windows 11 x64 with `ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-agentd` | 0 | all pass; no `SKIPPED` line |
| the same with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and Ubuntu cannot be built here. The change is platform-neutral (the same argv from one
function), so CI decides.

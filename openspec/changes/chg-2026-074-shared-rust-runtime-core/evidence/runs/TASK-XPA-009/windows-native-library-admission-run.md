# TASK-XPA-009 — WM2: native-library plan and admission on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM2, GJ-3. This is delivered with
XPA-008's `debug.hap@1` slice (one commit, since both use the same newly portable oracle
support), and the full method is recorded in
`../TASK-XPA-008/windows-debug-hap-admission-run.md`. The code-sign helper's own slice is
`windows-code-sign-helper-run.md` (#2407).

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used,
nothing installed was read or written, and host tests are not Windows acceptance.

## ELF, ABI and Build-ID validation

`arkdeck-provider-hdc`'s `native_elf` (Swift `NativeLibraryArtifactValidator`, and the helper's
static-executable check) is plain Rust with no platform gate; its unit tests already ran on
Windows. What this slice adds is Swift's native-library oracle replayed on Windows through the
planner that calls it:

- **`hoststore/tests/native_library_plan.rs`** (2 tests):
  - All 9 plans match. Of the 5 materialized plans, each lowers every step to its exact process
    sequence and holds the rollback a failure past the publish applies.
  - The 4 refusals are Swift's, message included: a stale binding, an unknown lease, a library of
    another ABI (the ELF validation) and a logical name outside the catalog's pattern.
  - A composition without a verified helper cannot plan or admit a deployment.
- **`hoststore/tests/native_library_submit.rs`** (4 tests):
  - Every submission is Swift's, and the one capability Swift issued is installed. Its checkpoint
    is byte for byte, and each Job's members, admission Journal and index row match.
  - An imported library is admitted and keeps its Import from release.
  - `agent.run` admits the deployment it will run.
  - New: without an HDC composition, an admitted deployment is refused before its first step
    with zero dispatch and no use consumed. The staging, the publish and the rollback all stay
    behind the tuple gate.
- **T0 over Swift's paths.** `native_plan_digest`, the plan document split out of
  `materialize_native` with no change in behavior, reproduces all 5 Swift plan digests. It runs
  over the library and code-sign helper at the paths Swift named, as a unit test on every host.
  The Windows replays read the digest and the capability values derived from it through the
  same one-to-one relabelling as the HAP replays.

## Left out

`native_library_run.rs` (the deployment, publish and rollback executed against the shared fake
HDC) and provider-hdc's `tests/native_library.rs` stay macOS-only. The fake is a POSIX shell
script at a fixed macOS root, and the Windows daemon refuses every such run at the tuple gate
before any dispatch, which is what the tests above prove.

## Local targeted checks

The checks are the XPA-008 run record's, from the same commit.

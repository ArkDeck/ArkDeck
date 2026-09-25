# A retained Session the continuity proof let pass is not read again while it is unchanged (TASK-XPA-014, macOS, 2026-09-26)

TASK-XPA-014 / CHG-2026-074. A device mutation's admission and each consumption prove the Runtime's
mutation state continuous: `JobStore::require_mutation_state`. The proof reads and replays every
retained Session's Journal and decodes its Manifest, holding the Job store's `activity` guard
throughout. #2234 made one replay grow with its Journal rather than with its square. The proof
still read every retained Session each time, so it grew with all of them together. The hub ruled
on 2026-09-26 that a cache of each Session's verdict comes in its own slice, on these terms:
1. **The key.** Each file's device, inode, size, and modification and change times to the
   nanosecond. Any difference reads the Session again. A cache never answers for a file that
   changed.
2. **Memory only.** The cache is derived data. A restart starts without it. Nothing of it is
   written or becomes durable state.
3. **The tests:**
   - an answer from the cache equals a full scan's;
   - each part of the key reads the Session again on its own;
   - negative control: with the change time out of the key, a same-size rewrite whose modification
     time `utimes` set back is missed;
   - appends interleaved with admissions never get a stale answer.
4. **No contract input changes.**

Base: protected `main` `51a44975a` (#2238), which holds #2230's staged Session publication.
Developed on `c79b68683` (#2229); see Local targeted checks for what ran on which. Disposable host
data only; nothing here is device evidence. This slice also records #2230's CI.

## Swift

`RuntimeStateContinuity` looks only at the Session root's direct children. It never reads a
Session's files, so it keeps nothing. This slice changes how often Rust's deeper scan reads, and
nothing it answers.

## Change

- **`HostFileIdentity`** (`arkdeck-platform`, `host_store.rs`): a file's device, inode, size, and
  modification and change times (seconds and nanoseconds).
  - `HostDirectory::read_identified` is `read` with the identity of the bytes read. `read` already
    required the file unchanged from before the read to after it, in all of these, and still
    linked at its name. `read` is now `read_identified` without the identity.
  - `HostDirectory::file_identity` stats a name without following a link.
- **`SessionVerdicts`** (`mutation_state_continuity.rs`): the retained Sessions the last complete
  scan let pass, by path, each with the identity of its Manifest and of its Journal, `None` where
  it has none.
  - It lives in `JobStore`, in memory only, behind a mutex taken only under `activity`, as the
    scan is.
- **A Session unchanged since then is not read again.** Both of its files must have the identity
  the last scan read: `Verdicts::unchanged`, from a `file_identity` of each name.
  - The scan still checks its path, as every Session's.
  - A Session holding neither file is a container, as before. Containers are not kept.
- **Only settled files are kept.** Any other Session is read as before. Its verdict is kept only
  when each file it read changed more than `SETTLE` (2 s) before the scan began, both
  modification and change time.
  - A file written within the clock tick of the read could otherwise keep the identity of the
    bytes read.
  - A clock that reads before 1970 keeps nothing.
- **A refusal is never kept.** Only a scan that let every Session pass replaces what is kept,
  with the Sessions it met and no other. A refused scan leaves it as it was.
- **`Reuse`**: `Never` reads everything and leaves what is kept alone. `SettledBefore(instant)` is
  what the daemon uses (`Reuse::now()`: 2 s before its clock). Tests set the instant.

## Tests

In `job_owner::mutation_state_continuity::tests`:
- **`an_unchanged_session_is_not_read_again_and_answers_as_a_full_scan`.** Two retained Sessions.
  - The first reusing scan reads both, and the second reads neither. Each answers as a scan that
    reads everything.
  - Then each change reads the Session again, and each answer is still the full scan's:
    - **its size:** a torn tail, refused. The refusal keeps what was kept.
    - **its change time alone:** the same number of bytes, one of them changed, and the
      modification time set back with `File::set_modified`, as `utimes` would. The test checks
      that device, inode, size and modification time are unchanged and the change time is not.
    - **its inode:** a Journal renamed over it.
    - **a file that appears:** a Manifest that does not decode.
- **`every_part_of_a_file_identity_tells_it_apart`.** A kept identity against one differing in
  each of its seven parts, the device included.
- **`a_file_not_yet_settled_is_read_every_time_and_never_kept`.** With nothing settled, every scan
  reads the Session and keeps nothing. The daemon's instant is 2 s before its clock.
- **`appends_between_scans_are_never_answered_from_a_kept_verdict`.**
  - A retained Journal grows record by record, in turn with scans. After each record, the
    reusing scan answers as the full one. The Journal both refuses and allows the state on the
    way.
  - A second writer then appends a whole Journal while scans run freely. Once it is done, the
    reusing scan answers as the full one.
- **Negative controls, each failing its test:**
  - With the change time left out of the comparison, the reusing scan let the same-size
    rewrite pass: `Ok(())` where the full scan answered `recordUnreadable`.
  - With a kept verdict reused whatever its files, the first and the fourth test failed.
  - With files kept whether or not they had settled, the third test failed.

The existing continuity tests still pass unchanged. They use the daemon's instant, so their
freshly written files are read every time.

While controls ran, the interleaved test first held its scope open after a failed assertion: the
writer waited for a record that never came. Its sender now belongs to the scope, so a failure ends
the test.

## Cost

`a_proof_over_a_thousand_retained_sessions_takes` (`#[ignore]`d). A thousand retained Sessions,
each holding the same 9-record Swift pointer oracle Journal, a gesture the device refused. Five
proofs each way, debug build, 1-minute load 3.3 (`c-measure.log`).

| Proof | Median | Max |
| --- | --- | --- |
| Reading every Session | 356 ms | 442 ms |
| Reusing every Session | 36 ms | 37 ms |

What remains is listing the tree and two metadata reads per Session. A quiet-host run is left to
the window the hub arranges, with the staged publication's P99 and the 20b baseline.

## Contract

No contract input changes, and no answer changes.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`. The host's 1-minute load was about 3 to 8.

**On `c79b68683`:**

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`c-fmt.log`).
- `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`: exit 0
  (`c-clippy.log`).
  - The changed crates: `arkdeck-platform` and `arkdeck-hoststore`.
  - The crates that depend on them: `arkdeck-agentd`, `arkdeck-soak`, `arkdeck-cli`,
    `arkdeck-client`, `arkdeck-bootstrap`, `arkdeck-provider-hdc`, `arkdeck-provider-workspace`
    and `arkdeck-provider-arkforge`.
- The same clippy for the changed crates with `--target x86_64-pc-windows-msvc` and
  `--target x86_64-unknown-linux-gnu`: exit 0 each (`c-cross-*.log`). The changed code is built on
  macOS only.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform -p arkdeck-hoststore
  -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: exit 0 (`c-test.log`).
  - 132 suites: 1,019 passed, 0 failed, 18 ignored.
  - One of the ignored is this slice's measurement. The others already existed.
- After renaming the tests' Journal constant: the `arkdeck-hoststore` clippy again, and the
  module's tests (12 passed), exit 0 each (`c-clippy2.log`, `c-test2.log`).
- The three negative controls above.
- `sh scripts/check-sdd.sh` (validation venv): exit 0.

**On `a30b1ba62`,** the first base with #2230's staged publication, where the scan's `.staging`
skip and this slice's verdicts first met in one function:
- fmt, and the clippy of `arkdeck-platform`, `arkdeck-hoststore`, `arkdeck-agentd` and
  `arkdeck-soak`: exit 0 each (`c2-fmt.log`, `c2-clippy.log`).
- The tests of the same four crates: exit 0 (`c2-test.log`): 133 suites, 1,026 passed, 0 failed,
  21 ignored.

**On `51a44975a`,** after #2233 changed `arkdeck-platform` elsewhere:
- fmt, and the clippy of `arkdeck-platform`, `arkdeck-hoststore` and `arkdeck-agentd`: exit 0 each
  (`c3-fmt.log`, `c3-clippy.log`).
- The `arkdeck-platform` and `arkdeck-hoststore` library tests: exit 0 (`c3-test.log`), 327 and 102 passed, 0 failed.
- `sh scripts/check-sdd.sh`: exit 0.

**Not run:**
- `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
- A quiet-host measurement (see Cost).
- The App and a device.

## CI

Pending.

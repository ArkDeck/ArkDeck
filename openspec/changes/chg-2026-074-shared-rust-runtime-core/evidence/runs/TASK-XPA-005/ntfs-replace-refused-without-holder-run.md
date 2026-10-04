# TASK-XPA-005: the NTFS document replace, refused with no holder, publishes by keeping the replaced file

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2.
Base: protected `main` `4f5d238c` (#2466).
Host: the Windows 11 x64 reference host, NTFS on C: and D:, non-elevated. Microsoft Defender
real-time protection is on, with tamper protection (`Get-MpComputerStatus`, read-only). Other
worktrees were building on the host throughout. No device was contacted, and no system setting or
exclusion was changed. Host tests are not Windows acceptance.

## The failure

`arkdeck-hoststore/tests/job_store_corpus.rs`
`recorded_job_indexes_are_rebuilt_by_the_owner_and_read_back_after_a_restart` failed on `main`.
A1 and CI2 both hit it, under a long and an 8.3 `TEMP`. `JobStore::persist` answered
`Refused(Os { code: 5 })`: the replace of `jobs/<id>/job-record.json` stayed refused for the whole
10 s patience that #2432 added (`ntfs-replace-held-target-run.md`). Run alone, alternating bare
`main` and the held-target branch, it failed 3 times in 8.

## Finding what refuses it

This used temporary instrumentation in `rename_replacing`, never committed. It logged the raw
NTSTATUS and probed the target at the first refusal, at 3 s, and when the patience ran out. A
temporary stress test, also never committed, published `job-record.json` six times into each of
thousands of fresh directories for 120 s.

**The status.** Every refusal was `STATUS_ACCESS_DENIED` (`0xC0000022`), never a sharing
violation.

**No handle is open on the target.** At every probe the target behaved as an unheld file:

- it opened with share mode 0 (exclusive);
- it opened with `DELETE`, and for reading without delete sharing;
- Restart Manager (`RmGetList`) named no process;
- it truncated and restored, so no user-mapped section exists;
- it has no extended attributes and no stream but `::$DATA`;
- its attributes were `ARCHIVE` only.

Our own handles are ruled out by the exclusive open succeeding. The test binary also runs nothing
else concurrently on that directory.

**The source is not the problem.** At the refusal, three things were tried:

- the staged `.part` renamed to a fresh name: succeeded;
- that file then replacing the target: refused;
- a brand-new file replacing the target: also refused.

So the refusal belongs to the target.

**What the target allows.** It renames aside and back, and it gains a hard link. Once it has a
second name, the same replace succeeds at once. In one stress run the replace was attempted after
linking the target 61 times. The replace succeeded every time, within 0 to 10 ms, and removing
the second name afterwards succeeded every time. A replace without POSIX semantics was refused just
the same (48 of 48).

**How long the refusal lasts.** Under this host's load the refusals ran from milliseconds to past
the 10 s patience. One directory's record stayed unreplaceable across three successive publications
of 10 s each. On D: they were rarer: one refusal, of 664 ms, in 31,110 publications.

**A mapped view does not reproduce it.** A document mapped by `MapViewOfFile`, with its handles
closed, was replaced at once even on `main`.

**C: against D:.** The refusal depends on the volume. H3 and others saw the corpus test fail
with `TEMP` on C: and pass on D:. Measured with the same stress, 120 s on each:

| volume | publications | refusals | longest |
| --- | ---: | ---: | --- |
| C: (`main`, two runs) | 7,650 | 20 outlasted the 10 s patience (shorter ones not counted) | over 10 s; the slowest publication took 12.7 s |
| D: | 31,110 | 1 | 664 ms |

**What the volumes differ in.** Both are NTFS. Three checks were made:

- **Defender exclusions.** They cannot be read without elevation (`Get-MpPreference`: "Must be an
  administrator"). Controlled folder access is off.
- **Whether D: is a Dev Drive.** `fsutil devdrv query` also needs elevation.
- **The ACL of the temp roots** (`icacls`). The C: `TEMP` root carries sandbox entries (unresolved
  SIDs with Modify or Modify+DeleteChild, `CodexSandboxUsers`, an AppContainer SID); D:	mp
  carries the stock entries.

The ACL is not the cause. The host store creates its roots with a protected, owner-only DACL, so
none of the inherited entries applies inside them. And at the refusal the target opened with
`DELETE`: the access check grants the delete, and something else refuses it.

**Conclusion.** The refusal comes from outside this process and from no handle. It is a kernel-side
refusal to remove the target file in a replace, and it lifts by itself. It is consistent with the
real-time anti-malware filter acting on a document published a moment before. Naming the filter
needs `fltmc` or a kernel trace, and both need elevation (`fltmc filters` answers access denied).

The earlier account, an anti-malware handle waited out within about 1.2 s, held only for the short
refusals. Waiting longer is not a fix: a refusal that lasts over 20 s would need a patience no
caller can afford.

## The fix

`host_store.rs` `rename_replacing`, used by every host-store document publication and by the
Import checkpoint replace:

- **First, the plain POSIX replace**, unchanged.
- **On `ERROR_ACCESS_DENIED` it calls `replacing_kept`.** That function:
  1. opens the target with `DELETE` access. A handle holding the target without delete sharing
     refuses that open, so a real holder is not linked past.
  2. gives the target the second name `.<name>.replaced` (new `host_fs::link`:
     `FileLinkInformationEx`, POSIX semantics, never replacing). If that name is taken,
     `replacing_kept` is not taken and the replace waits as before;
  3. replaces once;
  4. removes the second name, waiting out a holder of it within the same patience. After a replace,
     this removes the old file's last name. After a refusal, it leaves the document single-linked
     again.
- **Otherwise unchanged.** A sharing violation, or a target that cannot be linked, is waited out as
  before. If the patience runs out, the answer is still `BeforePublication`.

What a reader can see:

- **During the fallback.** Between the link and the replace, the document has two names, for the
  time of one rename: 0 to 10 ms in every measured case. A read that opens it then is refused,
  because readers require a single-linked document. The caller sees what any read of a document
  being changed sees: `HostDirectory::read` answers the host's snapshot refusal
  (`InvalidData`, "host snapshot refused"). The next read, once the replace is done, reads normally. The refusal cannot
  outlast that window: the second name goes as soon as the replace returns.
- **A reader can close the window itself.** A read that opens the document while it has two names
  removes the second name. Only the exact case below qualifies (see recovery). If that happens in
  the middle of a live fallback, the replace is simply refused again and retried within the same
  patience. Nothing is lost.

**Recovery from a crash.** A crash between the link and the unlink leaves one of two states:

- **The replace was not done.** Both names link the old document. Every host-store read and
  inspection goes through `HostDirectory::open_at` / `inspect_entry`. These now call
  `drop_kept_link` first, for private stores only. It removes the sibling
  `.<name>.replaced` only when all of these hold:
  - the document is a regular file with exactly two links;
  - that sibling exists, opened with `DELETE` and through no link;
  - the sibling is the same file (same volume and file id).

  It removes it by handle, with a POSIX delete. The document then reads back single-linked with
  its old bytes. In any other case nothing is removed, and the checks that follow refuse as
  before. There is no startup sweep: the first read or inspection recovers, so no reader ever sees
  the crash state as a lasting refusal.
- **The replace was done.** The document is the new file, single-linked, and reads normally.
  `.<name>.replaced` is left alone on the replaced file, as a crash leaves an orphan `.part` file.
  It is not the document's second link, so the rule above does not touch it. While it stays, the
  fallback is not taken for that document: the link finds the name taken, and the replace waits
  as before.

Nothing changes when the plain replace succeeds, so the common path, macOS and Linux are untouched.
`state.rs`'s instance document, which is written once per start by path and not through
`rename_replacing`, keeps the patience alone.

These are delegated minor decisions, pending the next rulings batch:

- the fallback itself;
- the fixed name `.<name>.replaced`, so that recovery is one lookup rather than a listing;
- recovery on read and inspection, removing only a second link to the same file;
- the reader refusal bounded to the link-to-replace window.

The readers' single-link rule is kept. The alternative, renaming the old file
aside, would leave the name absent in that moment and after a crash.

**Test.** `a_replace_with_the_replaced_file_kept_leaves_one_single_linked_document`, a unit test in
`host_store.rs`, covers both outcomes of `replacing_kept`:

- **The replace goes through.** The document is replaced, a reader that held it open keeps the old
  bytes, and only the document's own name is left, readable as single-linked.
- **A handle holds the document without delete sharing.** `replacing_kept` is not attempted (it
  returns `None`), and the document and its names are unchanged.

`a_crash_inside_the_kept_replace_leaves_a_readable_document` builds both crash states:

| replace | the next `read` returns | names left | then |
| --- | --- | --- | --- |
| not done | the old bytes, single-linked | the document only | a publication replaces it |
| done | the new bytes | the document and the orphan `.document.json.replaced` | a publication replaces it |

With `drop_kept_link` disabled, the test fails on the not-done state ("host snapshot refused").

The refusal itself cannot be reproduced on demand (see the mapped-view check above). The measurements
below test the fix against the real refusal.

## Measured

| run | result |
| --- | --- |
| stress, 120 s, C:, `main` (two runs) | 1,275 jobs, 7,650 publications: **20 refused** after the full patience; the slowest publication took 12.7 s |
| stress, 120 s, C:, this change (two runs, alternating with `main`) | 6,166 jobs, 36,996 publications: **0 refused**; the slowest took 2.4 s; every directory was left holding only its readable `job-record.json` |
| `job_store_corpus` restart test alone, with `main`'s replace (bare `3efba88c` and the held-target branch, alternating) | failed 3 of 8 |
| the same, this change, alternating long and 8.3 `TEMP` | **0 of 10 failed** |
| stress, 120 s, C:, with crash recovery, on `9f26fc0a` | 25,758 publications: **0 refused**; the slowest took 448 ms; 0 directories left with an extra name or unreadable |
| the same, rebased on `4f5d238c` | 16,068 publications: **0 refused**; the slowest took 1.46 s; 0 such directories |

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/ci2-hold`.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-platform -p arkdeck-hoststore --no-fail-fast` | exit 0: 708 passed, 0 failed, 10 ignored, 2 SKIPPED |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: (`AD-SHO~4`) | exit 0: the same counts |
| six rounds with four CPU-spinning processes: both new unit tests; the two brief-holder tests in `windows_host_store`; the whole `job_store_corpus` (on `9f26fc0a`) | 6/6, 6/6, 6/6 passed |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) check and clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check` | exit 0 |

The two SKIPPED lines are the known wildcard-listener skips.

## CI

To be recorded by the follow-up.

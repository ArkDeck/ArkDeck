# TASK-XPA-005 — the NTFS document replace refused while its target was held: finding the holder

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2-R. Base: protected `main`
`d492cfd3` (#2429). Host: the Windows 11 x64 reference host, non-elevated, NTFS on C:, with
Microsoft Defender real-time protection on (`Get-MpComputerStatus`, read-only). No device was
contacted, and no system setting or exclusion was changed. Host tests are not Windows
acceptance.

## The flake

S1 saw `arkdeck-hoststore/tests/job_store_corpus.rs` (#2361) fail 1 run in 5 under an 8.3
`TEMP`, with `JobStore::persist` answering `OutcomeUnknown(PermissionDenied)`.

## Which replace, and whether the retry covered it

`JobStore::persist` → `HostDirectory::publish_document("job-record.json")` →
`publish_with_checkpoint`. It writes and flushes a fresh `.job-record.json.<nonce>.part`, then
calls `rename_replacing`: `NtSetInformationFile(FileRenameInformationEx, POSIX_SEMANTICS |
REPLACE_IF_EXISTS)` on the `.part` handle, relative to the held directory. This is the path H2's
retry covers: 12 attempts plus one, with a pause doubling from 1 ms to 200 ms, about 1.06 s in
all. When the retries ran out, the refusal was answered as `OutcomeUnknown`, which `persist`
passes on.

## The holder

I added temporary instrumentation to `rename_replacing`, not committed. On each refusal it logged
the error and asked Restart Manager (`RmStartSession` / `RmRegisterResources` / `RmGetList`)
which processes hold the target; on recovery it logged how many refusals and how long. I ran the
corpus test binary 25 times, each under a fresh 8.3 `TEMP` (`…\Temp\AD-SHO~1`):

- **Refusals.** 17 refusals in 11 of the 25 runs, every one `ERROR_ACCESS_DENIED` (5) on a
  `jobs\<id>\job-record.json` that the previous `persist` of the same Job had published a moment
  before.
- **Restart Manager.** It named no process for any of them (`RmGetList` status 0, 0 needed). No
  user-mode handle of any process, this one included, held the target: the holder is a
  kernel-mode handle.
- **Duration.** Every refusal ended by itself while the store only waited. Most retries
  succeeded within 15–40 ms, which includes the Restart Manager query. **Three took 1.1–1.2 s**,
  succeeding only on the final attempt past the 1.06 s budget, so they were a hair from the
  reported failure.
- **Own handles.** None of this process's handles was open on the target:
  - a publication writes and flushes only its own `.part` file;
  - the host store's readers open with every share mode;
  - the corpus test reads records with `std::fs::read`, which shares delete, and not
    concurrently with `persist`.

That rules out our own handle. It leaves the anti-malware scan of the just-published record
(Defender's filter, which opens the file from kernel mode after the handle that wrote it closes)
as the transient holder. The indexer does not index `TEMP`. Nothing here could be closed earlier
to avoid it: the next replace of the same record simply comes too soon after the last.

**Not the 8.3 path.** The same instrumented binary, 25 runs under a fresh long-name `TEMP` on C:,
met 13 refusals in 11 runs, again all `ERROR_ACCESS_DENIED` with no holder named. One run failed
exactly as reported, with the retry exhausted after 1108 ms, and the longest refusal that ended
in time took 903 ms. The short path only made S1's run the one that showed it.

## The fix

- **Longer bounded retry.** `rename_replacing` now waits out a held target until
  `REPLACE_PATIENCE` (10 s), with a pause doubling from 1 ms to 250 ms. That is about eight times
  the longest refusal measured. Any other failure is answered at once, as before. The common
  case is unchanged: a refusal that ends within milliseconds costs milliseconds.
- **Classification.** A refusal because the target is held (`held`: `ERROR_ACCESS_DENIED` or
  `ERROR_SHARING_VIOLATION`) replaced nothing: a POSIX rename is atomic. If the patience runs
  out, it is now answered as `DocumentPublishError::BeforePublication`, which callers read as a
  refusal (`JobWriteError::Refused` for `persist`), no longer `OutcomeUnknown`. Every other
  rename or directory-flush failure stays `OutcomeUnknown`.

Other replacing renames with the same exposure that were not changed here, to keep this small:
- the import upload's checkpoint replace (`host_import_upload.rs`);
- the instance document (`state.rs`), whose target the next start alone reads.

H2's test of a holder that stays (`a_replacement_waits_out_a_brief_holder_of_the_replaced_document`
in `arkdeck-platform/tests/windows_host_store.rs`) now expects `BeforePublication`. It waits the
full 10 s patience. This classification is a delegated minor decision, pending the next rulings
batch.

## Measured after the fix

| run | result |
| --- | --- |
| instrumented, before the fix, 25 runs under a fresh 8.3 `TEMP` | 0 failed; 17 refusals in 11 runs, three of 1.1–1.2 s |
| instrumented, before the fix, 25 runs under a fresh long-name `TEMP` on C: | 1 failed (exhausted after 1108 ms); 13 refusals in 11 runs |
| `job_store_corpus` × 55, each under a fresh 8.3 `TEMP` on C:, with the fix (not instrumented) | **0 of 55 failed** |

## Local targeted checks

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-platform -p arkdeck-hoststore --no-fail-fast` (531 passed; 9 ignored, all as on `main`: measurements, external inputs and crash-child helpers) | 0 |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: (`…\Temp\AD-SHO~3`) | 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 |
| `git diff --check` | 0 |

The two `SKIPPED` lines in these runs are the wildcard-listener cases that are deliberately not
bound outside GitHub Actions; their loopback cases ran. No `cfg` gate changed: the fix is inside
the Windows-only `windows/host_store.rs`, so macOS and Linux build the same code as before.

## CI

To be recorded by the follow-up.

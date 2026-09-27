# TASK-XPA-025 — final v3 single 1 GiB validation

One actual 1 GiB InputArtifact owner publication and complete 256-page read passed
on macOS ARM64. This is a single current-source completeness/quiet-host result,
not a three-run stable baseline, adopted reference, performance-budget pass or G5
completion. The 200 MB/s and client RSS goals remain unmet. Copy count is unmeasured.
Earlier v2 matrix, failed admissions, cold-start/RSS instability and recovery
observations are unchanged.

## Source, build and boundaries

Source is exactly `8616a8220a82cdc4200804b31d5408eea7953ee3`, reader
`bounded-incremental-json-v3`, compatible lock SHA-256
`4e06dad7b626eaa4f1039cb1409e5d5c1c78628a5b30838cb994ad7e9915c59f`.
The coordinator merged reviewed #2285 at
`3c9bec11b9ae48fc484c59c1b50b89eb0cf1df3a` while this follow-up was underway;
that merge is not substituted for the measured source identity.

Build command (exit 0, 1m31s):

```sh
CARGO_INCREMENTAL=0 CARGO_TARGET_DIR=/private/tmp/arkdeck-xpa025-journal-target CARGO_BUILD_JOBS=2 cargo build --locked --release --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-soak
```

Rust/Cargo 1.98.1, release default features with the macOS/aarch64 SHA asm backend,
no RUSTFLAGS/encoded flags. Private target ownership remained exclusive. Binaries
were copied before capture and hashes checked before/after each attempt:

| Binary | SHA-256 |
| --- | --- |
| daemon | `2e38510f22e64eded53f26bb59c7df3be25854f8add8043d1fc419d25da0bcb6` |
| soak | `0ecb78783597f10e70bc192bdb13aacce135e91010c5418e880a4fd17cee592f` |

Fixed binaries remain under `/private/tmp/arkdeck-xpa025-artifact-v3-20260927/bin`.
`provenance.json`, complete Python instrument archive/per-file manifest, runner,
build logs and every raw attempt are adjacent. Binary executables are not committed.

Each capture invokes the unchanged production-owner fixture and real Rust daemon
in a temporary Runtime root. Full archive validation/publication, per-page full-file
server hash, closed envelope/canonical base64/range checks and final client digest
remain active. Pages are 4 MiB; the reader renews its connection every 64 pages.
Timing starts at the first read through the complete client digest, excluding
fixture publication/startup; read deadline is 600 s. Publication deadline remains
600 s and generation deadline 120 s. No device, Keychain or installed Runtime is used.

## All admissions and attempts

1. At 07:04:19Z the first formal pre-build disk admission **REFUSED**: required
   7,583,301,632 bytes, available 5,160,960,000. No build, smoke, fixture or quiet
   admission started. Its raw record remains `prebuild-admission.json`; it is not
   relabeled as an informal check or removed after success.
2. The coordinator explicitly authorized one new admission after a real resource
   change. Runtime's owner reported deleting only its inactive incremental cache:
   logical 6,113,977,336 bytes, du 5,284,416 KiB; binaries/deps/evidence retained.
   At 07:06:00Z admission **PASSED**, available 9,584,640,000 bytes. The second
   record references the refusal and exact owner cleanup facts. No repeated
   unchanged-condition retries or lowered reserve were used.
3. The fixed release build completed, then one 1 MiB smoke passed owner publication
   and full read: 10.218667 ms, one page, exact digest. All four guards recorded
   load 2.90673828125 and zero conflicting build processes. This is correctness
   smoke, not an eligible performance baseline.
4. Exactly one 1 GiB attempt began at 07:09:33Z. Available disk was 9,431,506,944
   bytes; the same 7,583,301,632-byte threshold retained the 4 GiB reserve, three
   payload copies and 64 MiB allowance. Four guards passed with loads
   2.2373046875, 1.89501953125, 1.89501953125 and 1.91943359375; each recorded zero
   cargo/rustc/xcodebuild/plan.py conflicts. Final guard was at 07:14:03Z.

There was no requireQuiet=false capture, outlier removal, cache eviction, timing
subtraction, synthetic delay or static-count completion claim. OS cache state is
uncontrolled; the fresh-owner first read and the small preceding smoke are explicit.

## Result

The 1 GiB archive SHA-256 is
`ba5eb9d725c43a044fd910e491dceccda54c9a84cfbc711138d89e059dfe62a0`, template
`1e3ab5867689c4059b6c11a080f6496ad5217e1ca3b529ea7388cb3b1657911d`.
All 256 contiguous pages, exact 1,073,741,824 bytes, final EOF and complete client
SHA matched. Read time was **252,677.029666 ms**, **4.249463536 decimal MB/s**.

| Sampled RSS | Baseline bytes | Peak bytes | Growth bytes |
| --- | ---: | ---: | ---: |
| daemon | 20,054,016 | 42,811,392 | 22,757,376 |
| client | 27,787,264 | 280,969,216 | 253,181,952 |

Sampling is every 0.2 s, a lower bound on true peak; it does not prove copy count
or publication RSS. The client RSS remains high. This size has 256 full-file hash
checks versus 32 for the old 128 MiB matrix; the figures are different workloads,
not a controlled regression ratio. No target or baseline is relaxed.

Both capture commands exited 0, including IsolatedRuntime stop and the fixture's
finally-rmtree path. No separate cleanup-path observation was emitted by this
instrument; cleanup success is supported by the normal return through that path.
Free disk after completion was 9,420,800,000 bytes. The exclusive host window was
released immediately to coordinator and Runtime; source/raw/fixed binaries remain.

## Local targeted checks

The release build, 1 MiB and 1 GiB actual captures returned 0; complete logs and
samples are adjacent. A read-only evidence check verified all four guards,
contiguous ranges/page count/exact bytes/EOF/digests and the 600 s bound for each
successful capture. The evidence-only follow-up SDD check returned 0 (zero errors/warnings;
`sdd.log.gz`), and git diff --check returned 0. It does
not repeat Rust/Python suites or the local unified gate because no code changed.
The implementation's Python 216 (3 skips), 11-crate Rust/Clippy, final compatible
KAT/integrity, deny/vet results remain in the preceding record and #2285.

## CI

Implementation #2285 head 8616a822 passed Swift CI 36301437501, including native
macOS/Linux/Windows and swift aggregate, plus SDD Guard and performance harness.
Coordinator independently reviewed and merged it at 07:08:29Z. This separate
evidence-only PR CI is pending at commit time; its PR body carries the final result
without amending a green head. No baseline adoption follows from CI success.

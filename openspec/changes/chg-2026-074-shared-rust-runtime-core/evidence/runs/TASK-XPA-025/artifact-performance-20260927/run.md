# TASK-XPA-025 — bounded Artifact reader and macOS ARM64 SHA diagnostic

This slice reduces repeated client receive-buffer copies and enables the existing
SHA-256 crate's macOS ARM64 hardware backend. It does not change Artifact bytes,
range/digest checks, publication, descriptor/path revalidation, permissions,
owner admission or failure semantics. No verification cache, mtime shortcut,
new protocol, device operation or installed Runtime was used.

## Implementation and input identity

Only the opt-in Artifact client uses bounded incremental `bytearray` accumulation,
checks capacity before growth, scans new fragments for LF/CR, and decodes one JSON
document. Duplicate keys, closed envelopes, strict canonical base64, exact ranges,
full final digest, total continuous deadline and bounded raw failure evidence
remain enforced. Default `_exchange` retains its original implementation. Decoded
page bytes are released after hashing. Reader version is part of comparison
identity alongside deterministic archive/template SHA-256 and the existing scale.

The measured optimized reader is `bounded-incremental-json-v2`. A subsequent
small lifetime fix removes its instance-bound method self-cycle on context exit,
including exceptional exit, after closing the connection. Pagination's close /
reconnect still retains the deadline and diagnostics. This final instrument is
`bounded-incremental-json-v3`. The measurements below remain v2 diagnostics, never
relabeled as v3 samples. The lifetime cleanup is after the measured endpoint and
RSS sampling; no new large-payload run was made for it.

The SHA feature is target-limited to macOS/aarch64 on arkdeck-platform's existing
sha2 dependency. Locked sha2 0.10.9 selects its ARM backend only with `asm`, then
uses CPU capability detection with a software fallback. macOS Intel, Linux ARM64
and Windows x64 feature graphs do not enable asm. There is no reduction in bytes
hashed. Each page still verifies the complete immutable file before returning.

## Frozen source, builds and matrix

Base for all actual captures: `56c321bec2c6e0e82a1e4453fc50fc393e370ddf`.
Software A: `78c6ad7d8ff4f6e34f00d0cc76d8df48f4b97ea2`.
Hardware B: `67854ee232c8e1cee62d343abb6b08a6f7cccf17`.
The source patches reconstruct A then B on the public base; instrument source
archives and per-file manifests pin both Python inputs. Later main alignment is
not presented as a measurement of a different source revision.

Both release builds used locked dependencies, Rust 1.98.1/Cargo 1.98.1, default
features plus the target-specific asm selection for B, release thin LTO,
CARGO_BUILD_JOBS=2, CARGO_INCREMENTAL=0 and no RUSTFLAGS. A completed in 1m27s;
B in 1m35s. The three 128 MiB legs all use the identical release-A soak binary.

| Binary | SHA-256 |
| --- | --- |
| A daemon | `302ea6950e83b5614e10775657c788f7b05a501a9af0edd8a7f860a647fb225f` |
| A soak (all release seeds) | `29eff21e18bb62cf4b6aeef8b3cb90f4bbf4d3f7259f0ae51715bad023c6b373` |
| B daemon | `51f2a78dad9dcb66d069b015265bf3bcc1d1d2fe4752ab9d3369d90f3cc35cf0` |
| B soak (built, not used for the release matrix seeds) | `1b93e0e575fbe5f4981b6cb738f7c6618bedce15bfeb3ff5bf54332cd453eddd` |

Debug daemon/soak hashes and source are in `debug-hardware-provenance.json`.
All binaries remain fixed under
`/private/tmp/arkdeck-xpa025-artifact-matrix-20260927/{debug-hardware,release-A,release-B}`;
none are committed to the repository. `capture.py`, `files.json`, the source
archives and all raw/result documents are adjacent to this record.

These were ordered **single functional diagnostics with requireQuiet=false**,
not AGENTS quiet-host performance acceptance, not a three-run stability result,
and not an adopted baseline. No actual process/load proof is claimed. The local
build window was coordinated and builds finished before the matrix, but that is
not a substitute for the formal quiet guard. Formal capture keeps four phase
admission checks. No warm-up read, cache eviction, outlier removal, elapsed-cost
subtraction or relaxed threshold was used. OS cache state is uncontrolled; order
and single samples limit causal/performance conclusions.

All three 128 MiB legs generated the same archive:
`3a6db799b50f87ebe4cd21dc5c691a6f1433e684fdd992bb6388e761bc3b2e7e`, from template
`1e3ab5867689c4059b6c11a080f6496ad5217e1ca3b529ea7388cb3b1657911d`.
Every leg completed 32 pages and the exact 134,217,728-byte client digest.

| Order | Reader / daemon | Read ms | Decimal MB/s | Client RSS growth bytes | Daemon RSS growth bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | old reader / software A | 21734.990125 | 6.175192 | 334610432 | 21774336 |
| 2 | incremental v2 / software A | 19418.764500 | 6.911754 | 151044096 | 21774336 |
| 3 | incremental v2 / hardware B | 4964.065292 | 27.037865 | 181420032 | 21856256 |

The observations improve on the original path but **do not meet 200 MB/s or the
client RSS growth goal**. Sampled RSS is not an exact peak or copy-count proof.
The higher client RSS in leg 3 versus leg 2 is retained. No 1 GiB fixture was
published/read. Its final validity/performance and all formal stability/baseline
adoption remain unmeasured. No G5 completion is claimed.

Before these three legs, a debug hardware-SHA 1 MiB real owner/read and a release-B
1 MiB real owner/read both completed with exact digest. Every attempt is archived;
there were no rejected attempts in this matrix. Earlier rejected/unstable captures
in TASK-XPA-025 remain unchanged.

## Memory diagnosis and its limits

The staircase in real RSS prompted bounded in-memory diagnostics, not another
daemon or large-file capture. They exercise the actual reader against fake bytes:
64 x 8 KiB, 16 x 256 KiB, and four 4 MiB pages. The scripts and complete outputs
are retained, including the first short runs whose 0.2 s RSS sampler saw only the
baseline; a separate endpoint `ps` read was added rather than calling that zero
observed growth an exact peak.

For four full-size pages, post-read tracemalloc live bytes were 72,680, traced peak
26,644,628 and retained control/artifact frames zero; endpoint RSS was 101,552 KiB
against a 45,613,056-byte initial observation. This bounded reproduction does not
retain one large Python response/JSON/frame per page. It is consistent with native
allocation retention/high-water behavior, but is not proof of the complete native
allocator cause of the original 128 MiB staircase. No gc.collect, allocator trim,
RSS reset or hidden counter adjustment was used.

A separate small self-cycle was proven: each configured client held its own bound
exchange method, retaining up to 64 KiB of prefix until cyclic collection. Removing
that binding on context exit reduced two-round 256 KiB-page live traced allocations
from roughly 78/152 KiB to 12/19 KiB. This does not explain or solve the large RSS
staircase. Behavior tests cover normal and exceptional release without forced GC,
65-page connection renewal and exact final digest, and expired renewed connections
sending zero bytes while retaining diagnostic budget evidence.

## Local targeted checks

- `python3 -m unittest discover -s scripts/bench -t scripts -p 'test_*.py'`:
  v2 212 tests, final v3 216 tests, exit 0 (3 opt-in integration skips). Real small
  integrations are recorded separately above, not counted as mocked acceptance.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- With `CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0` and private target,
  `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-platform -p arkdeck-provider-workspace -p arkdeck-hoststore -p arkdeck-bootstrap -p arkdeck-provider-arkforge -p arkdeck-agentd -p arkdeck-provider-hdc -p arkdeck-client -p arkdeck-soak -p arkdeck-rockchip-binding -p arkdeck-cli --all-targets -- -D warnings`:
  exit 0, 25.35 s.
- Same environment and 11 package selection with `cargo test --locked --manifest-path rust/Cargo.toml`:
  exit 0, 240 result groups, 1,985 passed, 23 ignored, zero failures. Includes
  standard SHA-256 known answers and the mutation/replacement read-checkpoint
  refusal. Full original output is `rust-test.log.gz`.
- No full local unified gate, installed Runtime, Keychain operation or device
  acceptance was performed. This was a host-only fixture.

Target ownership was exclusive, despite historical directory names: after prior
work ended, performance used journal-target; software-control used recovery-target.
Neither was shared by active worktrees. After tests returned exit 0 and no debug
process remained, current debug daemon/soak were fixed with hashes, then only that
owned rebuildable debug directory was removed. Logs/raw/source/old binaries were
retained. Fresh free space was checked before each phase; each fixture enforced
4 GiB reserve plus three payload copies and metadata. Free space after the matrix
was 10,731,520,000 bytes. The heavy window was explicitly released to Runtime.

## Dependency policy and final-source boundary

The captures above used the initial sha2-asm 0.6.4 / cc 1.4.5 /
find-msvc-tools 0.1.12 / shlex 2.0.1 graph. Initial cargo-deny failed four exact
allowlist entries; initial cargo-vet failed four coverage entries. After explicit
exact allow entries, deny passed. Refreshing only the existing five sources added
a real shlex audit chain; vet then failed the other three. All failure output is
retained, not reclassified as noisy CI.

A compatible metadata-only lock update selects cc 1.2.5 / shlex 1.3.0 and removes
find-msvc-tools. Existing Bytecode Alliance/Mozilla full+delta audits cover those
two; no new audit source, self-certified audit, trust window or exemption was
added. Deny passes; vet still reports only sha2-asm 0.6.4 missing safe-to-deploy.
After independent coordinating-task review within the user's authorized macOS
implementation and PR scope, one exact publisher rule was applied for sha2-asm
0.6.4: user 5059, publication day [2024-05-07, 2024-05-08), bounded further by
its exact deny version and lock checksum. This is not separate per-package user
approval or a complete source audit. Final cargo-vet and cargo-deny both pass;
the tool's success label means the configured policy is met. All prior rules,
imports sources and exemptions remain unchanged. See `dependency-review.md` for
the facts, rationale, risks and original failure sequence. The changed build-tool
pins passed the final macOS ARM64 checks below; the earlier full run is not
falsely attributed to the changed lock.

On final compatible-lock source 156c93e16, with the same private target/jobs=2/
incremental=0 settings, both commands returned exit 0 (one test each):

- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-platform --test sha256_backend`
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-platform --lib artifact_range_tests`

Logs are `compatible-kat.log.gz` and `compatible-integrity.log.gz`. The planned
additional hoststore owner repeat was not started: the coordinator requested the
window back for a Runtime defect, and it was released immediately after the active
integrity test completed. Existing owner tests passed in the earlier full targeted
run; final combined owner coverage is left to PR CI. No process remained running.

The optimization commits aligned onto main fe75fe28 after the matrix; range-diff
was identical. Intervening Native Flash/HDC changes left the measured Artifact /
Import and host_store range-verification chain unchanged; platform differences
were stop_signal/internal_stop. The full final combined source is for PR CI.

## CI

The measurement prerequisite #2281 passed CI 36297497435 and was merged at 56c321.
This new optimization slice has not yet been pushed: policy checks now pass after
the coordinating review; post-pin KAT/integrity checks pass and final CI is pending. CI green, if obtained, does
not adopt a baseline or close the remaining performance gaps.

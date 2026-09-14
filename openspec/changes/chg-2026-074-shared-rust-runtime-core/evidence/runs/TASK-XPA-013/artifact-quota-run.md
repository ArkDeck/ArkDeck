# Rust Artifact quota — macOS, 2026-09-14

TASK-XPA-013 remains in progress. Base: protected main `aa4cc8d8`, which carries the capability
reads (#1909) whose Swift decoding helpers this slice moves into a shared module, and the r11
proposal (#1910). The slice was built on #1909's branch and rebased onto main after #1909 merged. This slice lets the isolated
Rust development composition answer `artifact.quota` over its Artifact root as the Swift daemon
answers it. It reads and writes nothing; nothing installed changes. Every Artifact in the oracle and
the harness is synthetic host data written by Swift's own store API into temporary directories;
nothing here is device evidence.

The slice was cut before the r11 proposal (#1910, open). Under r11's tiers the answers, the walk
and the refusal conditions are T0/T1, while the refusal texts it pins would be T2, and its own
harness would fold into one corpus-replay harness.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-013 |
| --- | --- | --- |
| The Rust Job Artifact read library and its inspect/read projections (#1856), their Runtime routing (#1863), verified export (#1874) and resumable Import upload (#1885 era, `import-upload-run.md`); the isolated owner publishes the analyzer's Artifacts (TASK-XPA-014, #1894) | `artifact.quota`: Swift's walk of the Artifact root (root classification, index reads, synthesized decoding, identity and payload checks) with Swift's refusals, the host hook and route, the Rust CLI's `artifact quota`, a Swift-recorded oracle of 27 roots, a real-process harness | `artifact.list` (a Swift-exact `RuntimeSnapshotPager` port and the Job-directory side effect), Import commit, release, inspection and `artifact.import.list`, the private `artifact.publish`, leases, retention and GC, the canonical-alias HDC route, the owner switch, the crash-window matrix, GJ-1/2/3 |

## Behaviour

Swift answers `artifact.quota` in `AgentDaemon.swift` (1204–1226): parameters are never read, the
answer is `{"totalBytes", "usedBytes", "remainingBytes"}` with the store's quota (8 GiB, the same
`ArtifactQuota()` default the Rust composition's `ARTIFACT_QUOTA` names), and any store error is
`internalError` with Swift's interpolation of the `RuntimeArtifactError`. `totalBytesUsed()`
(`RuntimeArtifactStore.swift` 1721) walks the root once per store and then answers from memory.

`artifact_quota.rs` (`arkdeck-hoststore`) is that walk without the memory:

1. Every root entry is classified before any Job is read, in directory order (`jobDirectories()`,
   2506): the Import owner's `.imports-v1` directory and a regular `cleanup-debt.json` are skipped,
   any other directory is a Job, anything else is `indexCorrupted("artifact root contains an
   unexpected or linked entry <name>")`.
2. Each Job's index is read as `loadIndex(jobID:)` (2116) reads it: the Job name must be 1–128
   ASCII letters, digits, `-` or `_` (`ioFailure("malformed job identifier")`); an absent index, or
   a dangling link, has no rows; a linked index or a directory is `artifact index must be a real
   regular file`; `boundedIndexData` refuses an empty or oversized index, a failed read or an index
   that changed while it was read, in its four messages.
3. The index is decoded as Swift's synthesized `Codable` decodes `ArtifactIndexDocument` and
   `RuntimeArtifactMetadata`, member by member in their declaration order: a member the model lacks
   is ignored, a mistyped or absent one is Swift's `DecodingError` description after
   `undecodable artifact index: `, and `ArtifactStatus` needs exactly one of its case keys
   ("Invalid number of keys found, expected one."). A schema other than `1.0.0` is refused.
4. Rows are checked in order: the Job's own identity, a safe identity
   (`^ART-(?:MISSING-)?[0-9a-f]{32}$`), a unique identity and a unique name by canonical
   equivalence; and each published payload at once, as `validateStoredPayload` (2448) checks it:
   opened without following a link (`artifact payload is missing, linked or unreadable (errno N)`),
   a regular file of the published size (`artifact payload type or size drifted`), and the SHA-256
   of the bytes read with the file's identity unchanged (`artifact payload digest or identity
   drifted`).

`ArtifactUsage::quota` answers the totals; `arkdeck-agentd` serves `artifact.quota` from the
isolated owner's Artifact root, and a host without one still answers as the read-only foundation
does. The Rust CLI gains `artifact quota`, which sends no parameters as Swift's CLI sends none.
`swift_decoding.rs` now holds the keyed-container decoder the capability reader introduced, with
Bool, `Int64` and self-described type mismatches added.

Found on the way, recorded by the oracle:

- Swift's quota read is not read-only: for every Job it gets through it hashes each published
  payload, reseals a payload that is not `0400` to `0400`, and writes the Job's
  `.payload-verification-v1.json`; only these writes appear in any root's entries after the read.
- An identity with a line terminator after its 32 digits is unsafe: the regular expression's `$`
  takes no trailing newline here.
- A dangling index link reads as an absent index, so that Job contributes nothing.
- Swift reads Jobs in directory order after classifying the whole root, so a dot-directory is
  refused only after the Jobs listed before it were hashed (and their caches written).

Deliberate differences from Swift:

- The Rust read writes nothing: no reseal, no verification cache (Swift's cache only spares a hash
  on a later read), and no total kept between reads. A Swift daemon answers every read after its
  first from memory, so after a change it did not make itself it answers a stale total where the
  Rust owner answers the current one or refuses.
- Texts Swift takes from Foundation where the Rust walk has no equivalent call stay Rust's: a root
  that cannot be listed, a malformed JSON index (Swift quotes its JSON parser's error), and an
  `Int` overflow of the sum, which traps Swift's daemon.

## Shared oracle

`rust/tests/fixtures/artifact-quota/` was recorded by Swift
`ArtifactQuotaOracleContractTests.testSwiftAnswersTheSharedArtifactQuotaOracle`
(`ARKDECK_RUST_ARTIFACT_QUOTA_RECORD`, at `/private/tmp/xpa013-artifact-quota-oracle-r2`). Each
root is read by a store opened afresh over it, so its used-bytes cache is empty, through the
daemon's control plane.

| File | Content |
| --- | --- |
| `cases.json` | 27 scenarios and Swift's answer to each, the root spelled `<root>` where an answer names it |
| `tree.json` | every entry under each root before and after the read: kind, mode, size (a verification cache by kind and mode only, a link by its target) |
| `stores/<scenario>/` | every file as the read found it, without the payload-verification caches, whose fingerprints are this machine's inodes and times |
| `provenance.json` | the recording test, the clock, the redaction home, the label and the quota |

`empty` is a root the store created; `published` holds two Jobs the Swift store wrote through its
public API (two published Artifacts and a missing one, and a sensitive Artifact with an observation
window) beside `.imports-v1/records` and `cleanup-debt.json`, and answers 111 used bytes. The other
25 are `published` with one change: a stray file, a linked Job, a dot-directory, a Job without an
index; an index that is empty, linked, a dangling link (13 bytes: the Job counts nothing), a
directory, of schema 2.0.0, with a member the model lacks (accepted), a negative count on a missing
row (accepted); a duplicate, foreign, unsafe or newline-terminated identity; a mistyped or absent
member; a status with two case keys or none; and a first payload that is absent (errno 2), linked
(errno 62), unreadable (errno 13), one byte longer, rewritten at its length, or `0644` (accepted,
and resealed by Swift).

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust quota | `cargo test -p arkdeck-hoststore --test artifact_quota` | 2 passed: every root rebuilt as Swift found it, all 27 answers reproduced, every root left exactly as it was; and Swift's own writes during its reads are payload reseals to `0400` and verification caches only (in 8 of the 27 roots) |
| Unit tests | `cargo test -p arkdeck-hoststore --lib` | passed, `artifact_quota::tests::safe_identities_are_the_ones_swift_matches` among them |
| CLI | `cargo test -p arkdeck-cli --test artifact_quota --test capability_resources` | passed: the current Swift argv fixture of `artifact quota` (sent without parameters) and the capability leaves |
| Earlier replay | `cargo test -p arkdeck-hoststore --test capability_read` | passed after the decoder moved into `swift_decoding.rs` |
| Lint | `cargo fmt --all`; warnings-denied Clippy of `arkdeck-hoststore`, `-control`, `-agentd`, `-cli` | passed |
| Swift oracle | `run-swiftpm.sh test --filter ArtifactQuotaOracleContractTests` | r1 recorded; r2 re-recorded after the Windows-path fix below, 1 executed, 0 failures; compare runs in new processes, r1's together with `CapabilityReadOracleContractTests` (2 executed, 0 failures) and r2's alone (1 executed, 0 failures), so every published identity and byte is deterministic |
| Real processes | `python3 rust/scripts/check-artifact-quota.py --swift-bin-dir <run-swiftpm debug products>` | r1 PASS, 108 checks: for each of the 27 roots a fresh standalone Swift daemon (`<state>/artifacts`) answers as the oracle recorded, a fresh Rust owner (`<root>/artifacts`) answers as the Swift daemon did, both CLIs end `artifact quota` the same way, and the Rust owner's read leaves its root as its startup left it. Summary: `/private/tmp/xpa013-artifact-quota-harness-r1.json`, SHA-256 `9f1ea97e0941c79075019fefba2e905f75c499203d0f3d234ac3249c2ac425b9`. r2, after the fix and the rebase onto `aa4cc8d8`: PASS, 108 checks, `/private/tmp/xpa013-artifact-quota-harness-r2.json`, SHA-256 `a6f275a66f66e7096049b10825eb90ef5831055094c72e71e80441cfe39392b3` |
| Contract | the 27 recorded `artifact.quota` frames pruned against the committed corpus | only `internalError` refusals without details are new, and `artifact.quota.json` already publishes that code, so no schema or corpus changes |

The first Rust replay reproduced 26 of the 27 answers; the one it missed pinned that Swift's
identity pattern takes no trailing newline, where the port had assumed ICU's `$` would.

The first push (`a6dc90eb`) recorded that case with its first payload renamed to the
newline-terminated identity. Git cannot check such a path out on Windows, so the Windows Rust job
of PR #1911 failed at checkout. The case now changes only the index row: Swift refuses the identity
before it opens any payload of the row, so the recorded answer is the same, and no recorded path
holds a control character, a character Windows reserves, or a trailing dot or space (every tracked
path was scanned).

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Base / head | Result | Log |
| --- | --- | --- | --- |
| r1 | `6b7a79e3` / `c393b99f` (the slice on #1909's branch) | `gate exit=0` | `/private/tmp/xpa013-artifact-quota-gate-20260914-r1.log`, SHA-256 `0d4800b470887456b46d48a0343b3eeba7c21f24e5f684694fc1a0c9ac38ecc4` |
| r2 | `5e63eb19` / `e06b8d5f` (rebased onto main after #1909 merged; main had also gained #1907 and #1908) | `gate exit=0`: the full Swift lane (2,663 tests), the Rust lane (format, warnings-denied Clippy, workspace tests, published and candidate contract checks, `cargo deny`, `cargo vet`) and the common checks | `/private/tmp/xpa013-artifact-quota-gate-20260914-r2.log`, SHA-256 `c4cc13058ddf2760a71001caf1a7588337fbfd33c1483ae46eba9320f7b2306f` |

After r2 the slice was rebased onto `aa4cc8d8` (#1910, #1912, #1913 and #1914, each green on
main) and the trailing-newline case was re-recorded; the lanes that change touches were rerun
instead of the whole gate: the Swift oracle (record and compare), the Rust replay
(`cargo test -p arkdeck-hoststore --test artifact_quota`, 2 passed), the real-process harness r2,
and a scan of every tracked path for a name Windows cannot check out (none).

## Not run, and why

- No `artifact.list`: it needs a Swift-exact port of `RuntimeSnapshotPager` (Foundation-canonical
  sizes and bytes, Swift's texts, no lock file) and the Job-directory side effect of `list(jobID:)`;
  it is the next slice.
- No installed composition: the method is not served locally by a facade.
- `check-artifact-quota.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather
  than inside `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.

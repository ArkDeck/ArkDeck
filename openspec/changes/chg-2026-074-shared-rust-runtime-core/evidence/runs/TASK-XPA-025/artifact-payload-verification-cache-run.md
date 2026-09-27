# Instance-local Artifact payload verification cache

Initial base: protected main `e75afcde2877093990ef240524cbd4e9111a8ac4`.
Rebased without conflicts onto `0f3c2dc05e9561596c69605012f66127635b5b72`
before push; the intervening changes add a provider opt-in test and
measurement tooling/evidence, with no overlap in this slice's production code.

A committed Import range request verified every published inventory row and
then verified the requested payload again for its range. For a sealed 1 GiB
payload read in 256 pages, those two paths implied about 512 GiB of logical
hash input; this is a source analysis, not measured physical disk I/O.

Both paths now share a bounded, thread-safe cache owned by one
`ArtifactReadStore` instance. The cache contains payload integrity metadata,
**never RuntimeCapability, owner authorization, receipt, privacy or retention
authority**. The existing checks for those facts still execute for each request.
No wire format, durable format, Catalog operation or dependency changes.

## Verification and invalidation

- A first access hashes the complete payload with the server's expected digest
  and length. Only a private regular file owned by the effective user, mode
  `0400`, with one link can produce an opaque cache proof. Reads never chmod a
  legacy payload and never read or write Swift's durable verification cache.
- The proof binds the held parent directory's device/inode, payload name,
  expected digest and full payload stat: device, inode, size, uid, complete mode,
  link count, and mtime/ctime/birthtime including nanoseconds. The store's key
  also separates validated owner kind/id and artifact id.
- Every access opens through the held directory without following links, checks
  ownership/type/link count and compares the open descriptor with its named
  path. A matching proof reads only the bounded requested range through `pread`
  on that descriptor. Descriptor and named-path fingerprints are checked again
  before any bytes return; the existing index/root/directory checks also remain.
- A fingerprint or expected-metadata mismatch requires a fresh complete hash.
  Changed bytes fail their expected digest; an unchanged-byte replacement
  between requests can establish a fresh proof. Changes during an access fail.
  Unsealed private files always take the complete-hash path and are not cached.
- The cache holds at most 256 entries, evicts oldest entries, forgets a failed
  payload access and starts empty in each new store. Its mutex protects only
  metadata; no file access or hashing occurs under that mutex. Poisoning refuses
  the access. A concurrent stale insertion is checked against current file facts
  on the next access and cannot authorize a hit by itself.
- This platform implementation is macOS-only. Other platforms' existing paths,
  lease validation, export verification and analyzer pre-dispatch checks remain
  unchanged. The existing `fstat` helper is shared with Import upload; no new FFI
  binding is introduced.

The bound is on retained metadata, not a promise that every workload hashes
once: eviction, unsealed files, changed fingerprints and new store instances
all require hashing again. Client digest validation is not a server proof.

## Regression coverage

- Platform: one cold verification followed by 65 proven hits and EOF; wrong
  digest/length; proof reuse across parent/name boundaries; same-byte inode
  replacement; writable fallback without chmod; retained writer modifying bytes
  outside the requested range and restoring mtime; six changes between data
  access and the final checks, for both cold and hot access (write/reseal,
  replacement, symlink, hardlink, chmod and truncation).
- Store cache: capacity/eviction, owner separation, failure invalidation, a fresh
  instance with no persisted cache, concurrent file access outside the mutex and
  poisoned-lock refusal.
- Artifact owner: warm proofs still enforce changed privacy/digest metadata and
  integrity of unselected published rows; unchanged-byte replacement is
  reverified; retained-writer corruption and root replacement are refused.
- Import owner: warm inventory and range paths before each receipt identity,
  digest, generation, validation and binding corruption; warm inspect before
  release still observes the new lease and retention state afterward.

These are host fixtures and deterministic race seams, not device acceptance or
performance measurements. No installed Runtime, device, Keychain or capability
administration is used. The previous 1 GiB result remains unchanged. This slice
does not claim the 200 MB/s goal, a new RSS result, stable baseline, SPK-11 or G5.

## Local targeted checks

All Rust commands use `CARGO_BUILD_JOBS=2` and the exclusively owned
`CARGO_TARGET_DIR=/private/tmp/arkdeck-tool-selection-target`, reusing this
task's completed target with the coordinator's permission. No local unified
gate or benchmark is run.

Completed initial checks: platform proof tests 5 passed, cache tests 3 passed,
Artifact owner integration 29 passed, and warm Import receipt regression
1 passed. Logs: `/private/tmp/arkdeck-artifact-cache-platform-targeted.log`,
`arkdeck-artifact-cache-owner-unit.log`, `arkdeck-artifact-cache-owner-integration.log`
and `arkdeck-artifact-cache-import-receipt.log` under the same directory.

For each crate below, both commands returned 0:

```sh
cargo clippy --offline --locked --manifest-path rust/Cargo.toml -p <crate> --all-targets -- -D warnings
cargo test --offline --locked --manifest-path rust/Cargo.toml -p <crate>
```

| Crate | Passed | Ignored entries |
| --- | ---: | ---: |
| arkdeck-platform | 230 | 4 |
| arkdeck-hoststore | 737 | 18 |
| arkdeck-bootstrap | 34 | 1 |
| arkdeck-client | 10 | 0 |
| arkdeck-provider-arkforge | 91 | 0 |
| arkdeck-provider-hdc | 183 | 0 |
| arkdeck-provider-workspace | 54 | 0 |
| arkdeck-rockchip-binding | 1 | 0 |
| arkdeck-soak | 9 | 0 |
| arkdeck-cli | 480 | 0 |
| arkdeck-agentd | 203 | 1 |
| Total | 2,032 | 24 |

Zero failed. Existing opt-in/child-fixture ignored entries are not reported as
new test passes. The 22 sequential commands took 710.480 seconds, exceeding the
ten-minute local target while covering the required changed crates and direct
consumers. Per-command logs are
`/private/tmp/arkdeck-artifact-cache-<crate>-{clippy,test}.log`; exits and elapsed
times are in `/private/tmp/arkdeck-artifact-cache-checks.json`.

`cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check` and
`sh scripts/check-sdd.sh` returned 0; SDD reported zero errors/warnings. Logs:
`/private/tmp/arkdeck-artifact-cache-fmt.log` and
`/private/tmp/arkdeck-artifact-cache-sdd.log`. Contract generation and Swift/App
checks were not run because their inputs and implementations are unchanged.

After the main rebase, provider-arkforge all-target Clippy and its complete
tests returned 0: 91 passed, one newly inherited live-daemon opt-in test ignored.
Logs: `/private/tmp/arkdeck-artifact-cache-main-provider-{clippy,test}.log`.
The unchanged 11-crate suites were not repeated. After all builds/tests exited,
only this task's inactive `debug/incremental` directory was removed (4,881,272
KiB by du); binaries, dependencies and logs were retained. Free disk rose from
1,150,976,000 to 4,751,360,000 bytes. The local Rust window is released; no further
local build or performance run is planned in this slice.

## CI

Pending this slice's exact-head PR checks. The PR body will carry the final run
IDs without amending an already green head. Coordinator review and merge remain
separate from local checks and CI success.

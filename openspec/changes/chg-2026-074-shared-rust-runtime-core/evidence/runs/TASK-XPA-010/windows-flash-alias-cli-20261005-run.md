# Windows flash alias reconciliation CLI measurement — 2026-10-05

This slice measures `flash.reconcile-alias` through the real Rust CLI and the
signed Windows test daemon over its named pipe. It closes the remaining
software measurement for this leaf; it does not execute Flash or claim hardware
acceptance. The starting revision is protected-main `7133461b6`.

## Behavior and evidence

- `flash_alias_cli::the_signed_cli_reconciles_aliases_as_the_swift_host_reads_oracle`
  drives all 21 alias exchanges from `rust/tests/fixtures/flash-host-reads`.
  The three missing/invalid CLI argument cases are refused by the published CLI
  parser before a request. The other 18 answers match the recorded Swift
  Runtime responses exactly, including successful revision-4 archival and
  republication at live revision 2.
- The refusal cases cover a missing Target, stale revision, empty Target,
  absent/Loader/ambiguous/unavailable USB census, absent or non-ahead alias,
  wrong topology or Loader identity, archive collision, repeat, shared file,
  undecodable document, unsupported schema and empty document. Every case
  compares alias file names, lengths, exact bytes and the corresponding private
  or shared Windows DACL state. The repeat case restarts the daemon first and
  proves the successful archive and alias remain durable and cannot be repaired
  again.
- `flash_alias_cli::the_signed_cli_republishes_the_post_flash_alias_oracles_lineage_bytes`
  independently drives the reissued lineage from `post-flash-alias` step 7.
  Its receipt, published alias and superseded archive match the oracle, and both
  documents remain owner-only.
- Every exchange proves zero fake-HDC dispatch. The reconciler reads a synthetic
  host USB census and uses the existing production Target-revision and lineage
  decisions. The test census parses the existing typed `UsbRelation` fields and
  preserves unrelated and Loader observations for production filtering.

The census input and composition adapter exist only in the Windows spawning
test binary. Without that test input its composition is unchanged. No
production identity check, HDC tuple, capability/trusted-fact owner, provider
declaration or hardware record changes.

Delegated minor decision, pending the next rulings batch: give the existing
signed test daemon's alias reconciler its own synthetic census in the test
binary, because the Target observation census seam does not replace the alias
reconciler's separately composed census.

The lead includes the accompanying shared integration: register `flash_alias_cli`
in the spawning binary, call its test composition adapter before recovery, add
`flash.reconcile-alias` to `WINDOWS_MEASURED_LEAVES`, regenerate coverage with
`maintainer contracts export`, and update the Windows census. This commit owns
only the test module and this run record; it does not re-pin the historical
maintainer oracle.

## Local targeted checks

Checks use isolated `CARGO_TARGET_DIR=D:/cargo-target/flash-alias`,
`CARGO_BUILD_JOBS=2`, and the configured host-trusted development signer.
`run_check.py` records command, exit and elapsed time in the named log. Cargo
build/test/clippy run through `tools/gate_slot.py`.

- `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0;
  `tools/logs/flash-alias-build.log`. The CLI is built before spawning tests.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `tools/logs/flash-alias-fmt.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings`:
  exit 0; `tools/logs/flash-alias-clippy.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test spawning flash_alias_cli -- --nocapture`:
  exit 0; 2 passed, 0 failed, 0 ignored, 0 SKIPPED;
  `tools/logs/flash-alias-tests.log`.
- The same two alias tests with `run_check.py --short-temp`: exit 0; 2 passed,
  0 failed, 0 ignored, 0 SKIPPED, with TEMP/TMP set to a verified 8.3 alias
  on C:; `tools/logs/flash-alias-short-tests.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd -- --nocapture`:
  exit 0; 175 reported passed, 0 failed, 3 ignored child-fixture entry points;
  `tools/logs/flash-alias-agentd-tests.log` (769 seconds). The broader suite
  reports four existing live-only SKIPPED messages: three registered-HDC checks
  and one DevEco signing check. Three optional live DevEco subpaths (registry
  CLI, Hvigor build and preset registration) also report that they were not
  run. Their live inputs are outside this fake-host alias measurement; no
  global zero-SKIPPED result is claimed.
- `sh scripts/check-sdd.sh` using the Git shell: exit 0; 0 errors, 0 warnings,
  121 acceptance IDs; `tools/logs/flash-alias-sdd.log`.
- `git diff --check`: exit 0.

The first development test run found an incorrect expected CLI parser message
in the new test. It was corrected to the published registry parser's message;
the final run above passes. The initial sandbox build could not write the
required target directory and was repeated with controlled filesystem
escalation. No source or safety rule was changed for either issue.

After integration directly above #2580 (health/continuation), the CLI was
rebuilt and coverage exported. Final checks all exit 0: both signed alias
tests with verified 8.3 `TEMP`/`TMP` (2 passed, no skipped paths),
`cargo test -p arkdeck-cli` (264 reported passes), CLI/Agentd all-target clippy
with warnings denied, full fmt check, SDD, diff check and contracts check
(242 clean). Cargo commands use `--manifest-path rust/Cargo.toml`; local logs
are `D:/src/ArkDeck-wt/tools/logs/flash-layer-{build,export,short-tests,cli-tests,clippy,fmt,sdd}.log`.

## CI

No PR or CI run is created by this subagent. The lead will integrate this owned
commit and its shared additions as one layer in the linear Windows PR stack.
Unified CI, macOS/Linux cross-checks and hardware acceptance are not claimed
by this local Windows fake-host measurement.
The preceding #2579 and #2580 heads have no failed checks at preparation time;
their native macOS/Windows workspace lanes are still running. Results will be
recorded after CI completes.

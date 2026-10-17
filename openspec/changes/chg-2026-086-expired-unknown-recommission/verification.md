# Verification

> Change:CHG-2026-086-expired-unknown-recommission@r1

All cases use synthetic identities, isolated stores and scripted Providers.
They establish software behavior, not hardware evidence, approval or publication.

The new owner/runner cases cover immutable historical records and capabilities,
one allocation per original CID, exact idempotency, concurrent reservation,
expiry and latched clock rollback, malformed ledgers, unclosed Providers,
tampered published archives, identity drift, another unknown and restart during
supersession publication. Managed-control cases require the complete CPU/CID/SN/
connector chain and consumed allocation before transition; postflight cannot
publish an early alias. Provider cases reject unrelated or live historical jobs
and clip new and cached step permits to the independent deadline.

The additive Catalog is pinned as
`d96478867d6250530095b3e1d873617cd5a9e78bba29af38c30748858b10dd07`.
All 32 previous descriptors and historical request/authority fixtures remain
unchanged. Exact test routing retains their original Catalog views and executes
the six new runner cases only in the Catalog that declares recommissioning.

## Local targeted checks

Windows, 2026-10-17. Logs are under
`D:/src/ArkDeck-wt/tools/recommission-validation-20261017/`.
Cargo uses this chat's existing fixed external cache with two build jobs.
No local unified gate or device operation is run.

- `python rust/scripts/run-cargo.py clippy -p arkdeck-contract
  -p arkdeck-rockchip-binding -p arkdeck-provider-hdc -p arkdeck-provider-arkforge
  -p arkdeck-bootstrap -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli
  --all-targets -- -D warnings`: exit 0; `clippy.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --lib
  --test flash_run recommission -- --nocapture`: exit 0, 7 unit and 6 runner
  cases passed; `recommission-test.log`.
- `python -m unittest scripts.catalog_gen.test_generate`: exit 0, 49 passed;
  `catalog-generator-tests.log`.
- `python -m unittest discover -s rust/scripts -p test_catalog_test_views.py`:
  exit 0, 33 passed; `catalog-test-views.log`.
- `python -m unittest discover -s rust/scripts -p test_historical_catalog_views.py`:
  exit 0, 11 passed; `historical-catalog-tests.log`.
- `python -m unittest discover -s rust/scripts -p test_catalog_execution.py`:
  exit 0, 19 passed; `catalog-execution-tests.log`.
- `python -m unittest discover -s rust/scripts -p test_contract_checks.py`:
  exit 1, 73 cases, 3 failures and 1 existing skip; `contract-view-tests.log`.
  Two failures exposed the missing new Catalog machine-output projection and
  were fixed while preserving all frozen fixture bytes. The remaining existing
  `RunDirectoryTests` POSIX-mode assertion reports `0777` instead of `0700` on
  Windows; it remains unchanged and is verified on Unix CI.
- Focused rerun with `-k ReadOnlyMachineOutputTests`: exit 0, 9 passed;
  `machine-output-tests.log`. The new census case also proves that all original
  operation entries survive unchanged and precisely one unavailable entry is
  added, with no fixture rewrite or repeated projection.
  All three doctor report forms also retain agreement between the Catalog
  summary and its unavailable-operation finding.
- Downloaded `rust-readonly-recordings-ubuntu-latest` from CI `39004994088`,
  verified every recording SHA-256, then called `check-readonly.machine_output`
  with `write=False` against the candidate recordings: exit 0, all five actual
  CLI outputs matched; `ci-machine-output-recheck.log`. This checks saved host
  execution output and is not a fresh CI run or hardware evidence.
- `python -m unittest gj_record.test_catalog_aliases` from `scripts/`: exit 0,
  3 passed after the CI census correction; `gj-catalog-tests.log`.
- `python -m unittest discover -s rust/scripts -p test_contract_checks.py
  -k test_catalog_change_replays_original_fixtures_with_current_implementation`:
  exit 0, 1 passed after CI reported a temporary-directory cleanup error;
  `catalog-replay-cleanup-tests.log`. No assertion or cleanup code was relaxed.
- `python scripts/catalog_gen/generate.py --check` and
  `python rust/scripts/generate-contract.py --check`: each exit 0;
  `catalog-generate-check.log` and `contract-generate-check.log`.
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1 because Windows
  rejected rustfmt's workspace argument list with OS error 206; `fmt.log`.
  `rustfmt --check --edition 2024 --config skip_children=true` on all 58 changed
  Rust files: exit 0; `rustfmt-per-file.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-rockchip-binding
  -p arkdeck-provider-hdc -p arkdeck-provider-arkforge -p arkdeck-hoststore
  -p arkdeck-soak --lib`: exit 0, 655 passed and 4 existing ignored;
  `rust-owner-provider-tests.log`.
- Earlier library batches passed agentd's 3, bootstrap's 8, CLI's 85 and
  contract's 30 cases. Those batches exited 101 on two Catalog-specific test
  expectations; the CLI addition now has its own row and the original 195-row
  digest remains checked, while Native plan hashing accepts only the exact new
  Catalog alongside its existing views. `rust-lib-tests.log` and
  `rust-lib-tests-final.log` preserve those attempts; the failing cases passed
  in their subsequent batches.
- Final `clippy -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd
  -p arkdeck-cli -p arkdeck-soak --all-targets -- -D warnings`: exit 0;
  `clippy-final.log`.
- `test -p arkdeck-control --lib`: exit 0, 2 passed; `control-tests.log`.
  The new descriptor first exposed missing example-input declarations; the
  schema and generated Rust/Windows validators were updated together.
- `test -p arkdeck-cli --test machine_contracts --test maintainer_contracts`:
  exit 0, 14 passed; `cli-contract-consumer-tests.log`. The CLI's own export
  regenerated only its command-registry Catalog digest and feature-coverage
  entry/counts; all other 240 generated bundle products were byte-identical.
- `test -p arkdeck-control --test read_only`: exit 0, 30 passed;
  `control-readonly-tests.log`. The additional destructive operation is checked
  explicitly while all recorded descriptors keep their exact comparisons.
- `clippy -p arkdeck-control --all-targets -- -D warnings`: exit 0 after the
  consumer-test correction; `clippy-control-consumers.log`.
- `test -p arkdeck-agentd --bin arkdeck-agentd`: exit 0, 42 passed;
  `agentd-tests.log`.
- `test -p arkdeck-hoststore --test flash_run recommission -- --nocapture`:
  exit 0, 6 passed after final Rust changes; `recommission-final.log`.
- `test -p arkdeck-hoststore --test loader_binding_jobs --test post_flash_alias`:
  exit 0, 9 passed; `binding-integrations.log`.
- `test -p arkdeck-provider-arkforge --test consumer_contract --test lane`:
  exit 0, 8 passed; `arkforge-integrations.log`.
- The `--test catalog_lineage --test debug_hap_run` batch passed all 9 lineage
  cases and 12 fresh-owner HAP cases, then exited 101 on 2 e4-only HAP oracles
  invoked against the new Catalog; `host-integrations.log`. Their unchanged
  assertions and frozen authority remain mandatory in CI's exact e4 view,
  which is now retained even after the new Catalog reaches main. No fixture
  authority or historical packet is relabeled to make those cases run here.
- `python windows/scripts/generate-clientkit.py --check`: exit 0;
  `clientkit-check.log`. The full routing census validates 939 source files,
  6,499 frozen fixture files and 334 targets; `catalog-inventory.log`.
- `ARKDECK_PYTHON=python sh scripts/check-sdd.sh`: exit 0, no errors or
  warnings; `sdd.log`. Git Bash supplies `sh` on this Windows host.
- `git diff --check`: exit 0; `diff-check.log`.
- Swift `RuntimeOperationCatalogTests` and native App verification require
  macOS CI; Swift/Xcode are unavailable on this Windows host.

## CI

PR [#2660](https://github.com/ArkDeck/ArkDeck/pull/2660), base `main`.
Initial SDD Guard run `39004620388` failed on the Golden Journey generator's
stale 31-canonical-operation assertion. The additive Catalog has 32 canonical
operations and one alias; the assertion now checks the new reference explicitly
and retains exact cardinality. Selected checks on the corrected head are pending.
Initial Swift CI run `39004620503` also reported `Directory not empty` during
temporary-directory cleanup in the contract replay test. Its behavior assertions
did not fail, and the isolated local rerun passed; fresh CI must still pass.
The same run found three new XCTest assertions in a Swift Testing suite. They
now use the suite's existing `#expect` syntax with identical conditions; native
compilation and execution remain assigned to macOS CI.
Run `39004994088` passed the App build, Windows client checks and host-independent
Rust checks. Linux workspace/parity exposed missing current CLI generated
products, the Control operation-list delta, and the doctor finding's count;
these now have targeted passing checks. Swift execution exposed exact census
expectations for the thirtieth input default and the additional bounded HiLog
action reference; their closed expected sets now include the new operation.
The protected-main required contexts were read back as `guard` and `swift`.
CI success cannot replace maintainer review.
The change remains proposed; same-board acceptance starts only after approval
and protected-main publication. macOS production recommissioning stays unavailable
until the historical process-lifetime guarantee is provable.

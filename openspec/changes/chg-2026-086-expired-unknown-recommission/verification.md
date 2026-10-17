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
`9c1d24df224723fc5fa46734a97800194361757320367092c826ae9c205c9080`.
After integrating main's maintenance operations from PR #2659, all 34 published
descriptors and historical request/authority fixtures remain
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
- `test -p arkdeck-hoststore --lib --test flash_run recommission -- --nocapture`
  after the startup/archive-root corrections: exit 0, 10 unit and 6 runner
  cases passed; `recommission-platform-tests.log`. New cases prove that absent
  ledgers leave a pristine Job repository, unsafe/malformed ledgers fail closed,
  and substituted roots or changed receipt/proposal hashes cannot verify an
  archive. The macOS-only alias and symlink cases require native CI.
- `clippy -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd
  -p arkdeck-cli -p arkdeck-soak --all-targets -- -D warnings` after those
  corrections: exit 0; `clippy-platform.log`. Source inventory validation
  still covers 939 sources, 6,499 unchanged frozen fixtures and 334 targets;
  `catalog-inventory-platform.log`. Targeted rustfmt and `git diff --check`
  exit 0; SDD exits 0 with no errors or warnings (`sdd-platform.log`).
- `test -p arkdeck-hoststore --test flash_run ordinary_policy_refusal
  -- --nocapture`: exit 0, 1 passed; `ordinary-admission-tests.log`. The
  current-Catalog case requires the original recovery census before policy
  refusal, the exact refusal response, and zero dispatch, capability issuance
  or independent allocation. It runs in every declared Catalog view.
- `test -p arkdeck-hoststore --lib --test flash_run recommission -- --nocapture`
  after restoring that ordinary admission order: exit 0, 10 unit and 6 runner
  cases passed; `recommission-admission-tests.log`. The five-crate Clippy
  command above also exits 0 (`clippy-admission.log`), and the 33 routing tests
  pass (`catalog-views-admission.log`). Source/fixture/target census remains
  939/6,499/334 (`catalog-inventory-admission.log`); frozen fixtures are unchanged.
- `python -X utf8 -m unittest discover -s scripts/ci -p test_event_checkout.py`:
  exit 0, 2 tests passed (`ci-workflow-checks-utf8.log`), using Git Bash on PATH
  and the writable task temp directory. Earlier invocations hit this Windows
  host's restricted default temp directory, missing `sh`, then default GBK
  decoding (`ci-workflow-checks.log`, `ci-workflow-checks-retry.log`,
  `ci-workflow-checks-final.log`); no workflow-checkout code or test was changed.
- `python -X utf8 scripts/test_agent_pr_workflow.py`: exit 0, 18 passed;
  `workflow-contract-tests.log`. The exact contract-parity time-limit token and
  its independent drift/removal/swap rejection tests match 100/65/30 minutes.
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

### Integration with the published maintenance operations

- After merging main `1a32a7c8f`, 81 targeted Rust cases pass (each command
  exits 0): `test -p arkdeck-hoststore --lib recommission` (10), `--lib
  maintenance` (11), `--test flash_run recommission` (6), the exact ordinary
  policy-refusal regression (1), CLI `--lib feature_coverage` (13), CLI
  `--test flash_maintenance --test machine_contracts --test maintainer_contracts`
  (17), Control's exact operation-list/doctor case (1), and hoststore
  `--test catalog_lineage --test terminal_publication_retry` (22). Logs:
  `merge-recommission-unit.log`, `merge-maintenance-unit.log`,
  `merge-recommission-runner.log`, `merge-ordinary-admission.log`,
  `merge-cli-coverage.log`, `merge-cli-contracts.log`, `merge-control-list.log`,
  and `merge-history-compatibility.log`.
- Historical input compatibility verifies all 34 published descriptors before
  the single addition. Old Catalogs cannot declare recommission; malformed or
  counterfeit source records preserve Jobs, capabilities and Imports unchanged.
  All terminal-publication tests now run in every Catalog view.
- `python -m unittest discover -s rust/scripts -p test_catalog_test_views.py`
  and the corresponding `test_historical_catalog_views.py` command each exit 0
  (35 and 14 cases); `merge-catalog-view-tests.log` and
  `merge-historical-view-tests.log`. Catalog generation and Golden Journey
  alias tests exit 0 (52 cases); `merge-generator-tests.log`.
- The full `test_contract_checks.py` suite ran 75 cases: 73 passed, one
  pre-existing platform skip, and the existing Windows POSIX-mode assertion
  failed (`0777` versus `0700`); exit 1, `merge-contract-check-tests.log`.
  No behavior assertion failed. Linux CI must execute the complete suite.
- Official Catalog, CLI bundle, Swift review, and Windows review generation
  retains the maintenance inputs. CLI export changes only the registry digest
  and feature-coverage report; every other exported product is unchanged.
  Catalog, Rust contract and Windows ClientKit generation checks each exit 0.
  The closed census passes with 945 source files, 6,499 unchanged main fixture
  files and 335 targets; `merge-catalog-inventory.log`.
- The affected ten-crate `clippy --all-targets -- -D warnings` check exits 0;
  `merge-clippy.log`. After the final read-side compatibility change, Clippy
  on hoststore and its four direct consumers also exits 0;
  `merge-clippy-final.log`. The workspace fmt command again exits 1 on Windows
  OS error 206 (`merge-fmt-workspace.log`); all 63 changed Rust files pass
  individual checks, exit 0 (`merge-fmt-files.log`). SDD exits 0 with no errors
  or warnings and 121 acceptance IDs; `merge-sdd.log`.
- Post-merge CI reproductions exit 0 in `merge-ci-reproductions.log`: the
  actual Windows/macOS CI listings each retain all 20 Flash tests, selecting
  14/3/3/9 cases for c6/e4/maintenance/recommission. Missing cases still fail
  closed. The current dependency graph passes; extra transport and missing
  adapter edges still refuse. The source and fixture census is unchanged.
  Catalog routing tests pass again (35 cases), `merge-ci-view-tests.log`.
  SDD exits 0 with 121 acceptance IDs, `merge-ci-sdd.log`; diff checks pass.

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
Run `39005826577` passed Swift tests, App build, Windows client checks,
host-independent Rust checks, Windows workspace and Linux workspace/contract parity. Its macOS
workspace job `117318309300` exposed two implementation defects: startup
reconciliation created a ledger lock before a fresh dedicated Job index, and
the immutable archive reader did not invert SessionPublisher's Foundation
`/private` alias. The fixes preserve the Job repository's strict initial-file
census and all archive device/inode/volume/hash pins. An absent ledger now has
no write; unsafe existing ledgers still fail closed. Only the publisher's
same-directory `/private` alias is accepted, with a canonical no-link root;
arbitrary symlinks remain rejected. Fresh CI on these fixes is pending.
Run `39007378286` passed all three workspace jobs, Swift tests, App build,
Windows client checks, host-independent checks and Linux parity. The macOS
parity job reached its 50-minute job limit in the additional exact e4 view's
unit tests. Its saved provenance confirms the published and candidate views
passed. The completed c6 replay also exposed one real ordinary-admission
regression: moving recovery classification behind policy refusal omitted the
historical recovery-ledger read. The ordinary path now keeps its original order;
the independent path still validates policy and Provider quiescence before its
irreversible reservation. The frozen c6 assertion and fixture remain unchanged.
All four views remain required. Only contract-parity job ceilings increase to
65 minutes on macOS and 100 on Windows to cover the extra full view; Linux,
workspace limits, individual test deadlines and Runtime/device budgets stay
unchanged. Full parity on the corrected head is still required.
The saved Windows parity log from that run confirms the same single c6
admission-tree mismatch before the superseding push cancelled it. Run
`39011187504` then stopped in the planner because the workflow-contract checker
still pinned the previous job ceilings. Its exact token and negative mutations
are now synchronized; all 18 workflow-contract tests pass locally.
Full Swift CI [39011349133](https://github.com/ArkDeck/ArkDeck/actions/runs/39011349133)
and SDD Guard [39011349209](https://github.com/ArkDeck/ArkDeck/actions/runs/39011349209)
passed for `4025d5b20bd255b6d0b4c644f87a0d57eba765dd`, including all four
contract execution views on all three hosts. Before delivery, main advanced to
`1a32a7c8f06830dd8e4b4441c002784dd70dc177` (PR #2659), producing shared
Catalog/Runtime conflicts. The merge retains maintenance behavior, adds explicit
ordinary-mode arguments and empty recommission state to its new consumers, and
regenerates the combined Catalog. The candidate preserves the published
maintenance Catalog and both immutable c6/e4 replay views. Fresh CI on the
integrated head is required; the earlier green run does not cover this merge.
Run `39018616264` passed Swift, App, Windows client, Linux workspace and
host-independent checks, including the full 75-case Python contract suite.
Windows/macOS workspace execution exposed seven added Flash cases missing from
the platform census; the exact observed 20-case lists now include them. Linux
parity exposed the existing main maintenance adapter missing from the explicit
dependency boundary. Its pure contract-only edge is now registered; arbitrary
ArkForge transport edges remain forbidden. Fresh CI on these corrections is
required.

The final integrated Swift CI run
[39019397279](https://github.com/ArkDeck/ArkDeck/actions/runs/39019397279) and
SDD Guard run
[39024094616](https://github.com/ArkDeck/ArkDeck/actions/runs/39024094616) passed.
The maintainer merged PR #2660 into protected `main` at `2026-10-17T10:16:21Z`,
publishing `0afda1acf643886bbdf9302772f61468626f20cd`. The approval basis is the
maintainer's merge under the enforcement policy; the PR has no separate
`APPROVED` review event. CI success alone does not replace maintainer approval.
macOS production recommissioning stays unavailable until the historical
process-lifetime guarantee is provable.

## Published Windows preflight: Job-state composition

The same-board headless preflight on the published Runtime refused before
authorization with `recommission.stateUnavailable`; no new device dispatch,
recommission allocation or Job was created. The account composition passed its
ArkForge lane root to the recommission reader, while the allocation ledger and
source Jobs belong to its private `jobs-state` child. The account root also
grants SYSTEM access and therefore cannot satisfy the private host-store reader.
The isolated development layout happened to use the same path for both owners.

The Windows composition now obtains the same canonical private child as the
Job owner. Lane storage, capability admission and immutable history rules are
unchanged. The regression exercises both layouts with synthetic observations:
an invalid decoy ledger at the lane root is ignored, an absent actual ledger
does not allocate anything, and a malformed actual ledger still fails closed.
This is a product fix within the published scope, not hardware acceptance.
The full write, readback, reboot and identity sequence remains
`BLOCKED_BY_PRODUCT_DEFECT` until the fix is reviewed and published.

### Local targeted checks

- The new Windows layout regression fails with the original root wiring
  (exit 101, `recommission.allocationLedgerMalformed`) and passes with the fix
  (exit 0, one case). Logs: `recommission-job-state-expected-red-20261017.log`
  and `recommission-job-state-fixed-green-20261017.log`.
- `python rust/scripts/run-cargo.py clippy -p arkdeck-agentd --all-targets --
  -D warnings` exits 0; `recommission-job-state-clippy-20261017.log`.
- `python rust/scripts/run-cargo.py fmt --all --check` encounters the existing
  Windows OS error 206, exit 1; `recommission-job-state-fmt-20261017.log`.
  `rustfmt --edition 2024 --check
  rust/crates/arkdeck-agentd/src/windows_lifecycle.rs` exits 0;
  `recommission-job-state-fmt-file-20261017.log`.
- The closed Catalog census passes with 945 source files, 6,499 unchanged
  fixtures and 335 targets, exit 0;
  `recommission-job-state-catalog-inventory-20261017.log`. Only the changed
  source digest is refreshed; historical routes and fixtures are unchanged.
- `python rust/scripts/run-cargo.py test -p arkdeck-agentd` exits 101;
  `recommission-job-state-tests-20261017.log`. The 43 binary unit tests pass.
  The spawning target reports 47 passes, three child-fixture ignores and seven
  failures: two account tests conflict with this session's live acceptance
  Runtime, and five existing replay cases require the retained Catalog views
  specified by the unchanged routing manifest. The latter are not claimed as
  passing under a raw current-Catalog invocation; CI must replay their assigned
  views without changing their assertions.
- After draining only this session's Runtime through the published service
  command, `python rust/scripts/run-cargo.py test -p arkdeck-agentd --test
  spawning account_tool_selection::` passes all three cases, exit 0;
  `recommission-job-state-account-tests-20261017.log`. The existing
  `--test windows_flash_lane_process` suite also passes all three cases,
  exit 0; `recommission-job-state-flash-tests-20261017.log`.
  The same published Runtime and acceptance configuration were then restored;
  all 106 protected files and 60 original Job records remain byte-identical.
- `sh scripts/check-sdd.sh` through the installed Git Bash exits 0 with zero
  errors, zero warnings and 121 acceptance IDs;
  `recommission-job-state-sdd-20261017.log`. Swift and App code are unchanged;
  their native checks are not run on this Windows host.

### CI

PR [#2661](https://github.com/ArkDeck/ArkDeck/pull/2661) passed Swift CI
[39026495445](https://github.com/ArkDeck/ArkDeck/actions/runs/39026495445) and
SDD Guard [39029978330](https://github.com/ArkDeck/ArkDeck/actions/runs/39029978330).
The maintainer merged it at `2026-10-17T14:00:59Z`, publishing
`da26b650685376c889f310488926c6daa81d41f6`. No `REAL_DEVICE_PASS` is claimed.

## Published Windows preflight: current attachment

The signed Runtime built from that published commit passed the Job-state check,
then refused the same-board plan with `recommission.identityChainIncomplete`.
The exact Normal CID matched, but the currently observed USB topology differed
from the original binding snapshot. Preflight created no new Job, independent
allocation or destructive dispatch. All 106 protected files and 60 original Job
records remain byte-identical.

`operation_facts` incorrectly required the freshly proved attachment to equal
the historical port, and inherited that port for execution. Within the already
published fresh-chain requirement, it now pins the current observation into both
the identity chain and the execution route. Chain validation rejects missing or
different route pins. The original binding digest still includes its historical
topology; ordinary Flash facts and durable history remain unchanged. The Provider
still requires stable repeated CPU/CID/SN/USB reads, exact Loader readback before
writing, and matching postflight. This clarification is recorded in the design.

Synthetic regressions exercise the real host-facts owner with both unchanged and
different attachment locations, malformed or missing proofs, Provider refusal,
and inconsistent execution facts. The successful recovery integration now moves
from historical port 42 to fresh port 84 and checks the allocation and Provider
route while retaining all original history, budget, one-use and restart checks.

### Local targeted checks

Windows, 2026-10-17. Logs use the prefix
`D:/src/ArkDeck-wt/tools/recommission-fresh-connector-` and suffix
`-20261017.log`; names below are the middle part. The existing per-chat Cargo
cache is reused with two build jobs. These isolated checks do not operate the
connected board or create hardware evidence.

- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --lib
  flash_facts::recommission_tests -- --nocapture` against the original
  implementation exits 101: the moved-attachment case refuses and inconsistent
  execution facts are accepted (`regression-red`). The invalid-proof case
  already passes. With the fix, `test -p arkdeck-hoststore --lib --test flash_run
  recommission -- --nocapture` exits 0: 13 unit and 6 recovery cases (`fixed`).
- `python rust/scripts/run-cargo.py clippy -p arkdeck-hoststore
  -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`: exit 0
  (`clippy`).
- Through the same Cargo runner, each command exits 0:
  `test -p arkdeck-hoststore --lib` (414 passed, 4 existing ignored;
  `hoststore-lib`), `test -p arkdeck-hoststore --test flash_run
  ordinary_policy_refusal` (1; `ordinary`), `test -p arkdeck-hoststore --test
  loader_binding_jobs --test post_flash_alias` (9; `binding`),
  `test -p arkdeck-agentd --lib --bin arkdeck-agentd` (46; `agentd`),
  `test -p arkdeck-soak --lib` (3; `soak`), and `test -p arkdeck-provider-hdc
  --lib rockchip_vendor_identity` (7; `provider-identity`). The Provider cases
  retain repeated-read, CID/profile, CPU/SN/USB drift and vendor-slot refusals.
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1 on the existing
  Windows OS error 206 (`fmt`). `rustfmt --edition 2024 --config
  skip_children=true --check` on all five changed Rust sources exits 0
  (`fmt-files`).
- The closed Catalog census, using `catalog_test_views.load` with fresh Cargo
  metadata, exits 0: 946 sources, 6,499 unchanged fixtures and 335 targets
  (`metadata`, `inventory`). Only the five source entries change; historical
  routes and fixtures remain byte-identical.
- `ARKDECK_PYTHON=python sh scripts/check-sdd.sh` through the installed Git Bash
  and `git diff --check` each exit 0 (`sdd-final`, `diff-final`).
- No contract inputs, Swift or App code changed. The native and historical
  replay checks remain assigned to PR CI; no local unified gate was run.

The real write/readback/reboot/identity sequence remains
`BLOCKED_BY_PRODUCT_DEFECT` until this fix passes its own PR checks and
maintainer publication.

### CI

PR [#2662](https://github.com/ArkDeck/ArkDeck/pull/2662) passed Swift CI
[39041666892](https://github.com/ArkDeck/ArkDeck/actions/runs/39041666892) and
SDD Guard [39045927141](https://github.com/ArkDeck/ArkDeck/actions/runs/39045927141).
It merged at `2026-10-17T16:37:13Z`, publishing
`998eae1e1b9a4ae5f68c58035be4210813f4197d`.

## Published Windows execution: postflight parser

The signed Runtime built from that published commit passed the fresh identity
chain and plan checks, then admitted exactly one recommission execution. Its
Catalog digest was
`9c1d24df224723fc5fa46734a97800194361757320367092c826ae9c205c9080`.
The Provider recorded successful writes for all nine partitions and a successful
device reset. Only `uboot` and `resource` received full-hash readback receipts;
the other seven ranges received `typedSkip` with `skipped-lba-read-window`.
Those skips do not prove full verification.

The postflight `read-build-facts` control request expired after 120 seconds.
The host continued its existing 600-second bound reconnect wait, then its late
receipt was rejected with `NO_CONTROL_PENDING`. Runtime retained the correlated
execution as `waitingForRecovery`, with `outcomeUnknown: true`. No successful
supersession or new binding revision was published. A separate read-only HDC
diagnostic observed the exact original target online with the expected model
and build; that diagnostic is not Runtime hardware acceptance evidence.

The `ResolvedHdc` wrapper omitted `registered_windows_tuple`, so a dispatch
pinned to the registered Windows executable lost its target-list grammar.
Its six-column USB row and UART host-port rows were parsed as the macOS
five-column family and repeatedly classified as malformed. The wrapper now
delegates that metadata to the same retained dispatcher. It grants no identity
or authority when resolution fails and leaves the existing parsers unchanged.

The regression exercises recommission postflight through the real executor and
wrapper using registered Windows output, independent synthetic CID/CPU/vendor
SN proofs, and a UART row. It requires one target-list read, the complete
postflight identity observation and no early alias publication. The existing
macOS-format case and identity-drift refusals remain covered.

All 60 pre-existing Job records and protected source history remain unchanged.
The capability store folded its two old ledger events into its checkpoint when
installing the new capability. Reconstructing that prior checkpoint and the
1,427 original event bytes reproduces the exact pre-execution hashes; the old
consumption, unknown outcome and budget are unchanged. This checkpoint fold is
not a new historical use. The new independent allocation is consumed and is not
refunded or extended by this fix. A read-only `flash.verify@1` plan also refused
this source before admission, with zero new dispatch.

This is a partial hardware result, not `REAL_DEVICE_PASS`. Full verification and
postflight remain incomplete; the original and new unknown intents are never
replayed.

### Local targeted checks

Windows, 2026-10-18 local date. Logs use the prefix
`D:/src/ArkDeck-wt/tools/recommission-windows-hdc-` and suffix `-20261018.log`.
The existing per-chat Cargo cache is reused with two build jobs.

- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --lib
  rockchip_executor::tests::recommission_postflight -- --nocapture` against the
  original implementation exits 101 (`regression-red`): the Windows case reports
  the same malformed five-column-family timeout as the real execution, while
  the existing format passes.
- With the fix, `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --lib
  rockchip_executor::tests -- --nocapture` exits 0: 18 cases pass
  (`regression-green`). These fixtures do not operate the connected board.
- `clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets
  -- -D warnings` through the same runner exits 0 (`clippy`).
- `test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --lib` exits 0
  (`libraries`): 415 hoststore cases pass with four existing ignored cases;
  agentd and soak each pass three cases.
- `test -p arkdeck-agentd --bin arkdeck-agentd --test windows_flash_lane_process`
  exits 0 (`native-flash`): 43 binary cases and three isolated Windows lane
  cases pass.
- Required `fmt --all --check` reaches Windows command-line limit OS error 206
  and exits 1 (`fmt`). Direct `rustfmt --edition 2024 --config skip_children=true
  --check` over both changed Rust files exits 0 (`fmt-files`).
- Fresh Cargo metadata and `catalog_test_views.load` validate the closed source,
  fixture and target inventory, exit 0 (`catalog-inventory`). Only the two
  changed source hashes were refreshed; fixture bytes and routes are unchanged.
- `ARKDECK_PYTHON=python sh scripts/check-sdd.sh` exits 0 (`sdd-native`). The
  sandboxed Git Bash attempt failed at Windows DLL initialization before running
  the check (`sdd`); native execution completed normally.
- `git diff --check` exits 0. No contract inputs, Swift or App code changed;
  contract generation and platform builds are left to selected PR CI.

### CI

PR [#2663](https://github.com/ArkDeck/ArkDeck/pull/2663), head
`75152cfb0e63f5daa34daa21b42e0480da7dcbb0`, passed Swift CI
[39052972261](https://github.com/ArkDeck/ArkDeck/actions/runs/39052972261) and
SDD Guard [39053054852](https://github.com/ArkDeck/ArkDeck/actions/runs/39053054852).
All selected Linux, macOS and Windows Rust workspace and contract checks
passed, including the complete formatting check. Unchanged Swift/App lanes
were skipped by the planner. Both required `guard` and aggregate `swift`
reported success on this exact head.

## Complete readback proof before recovery publication

The partial hardware readback exposed a separate completion defect: a canonical
postflight receipt alone was projected onto all write, readback and reboot
outcomes. An isolated runner regression reproduces the real two-full-hash,
seven-typed-skip pattern; the previous implementation incorrectly published
`recovered` and a superseding epoch.

Runtime now checks the Provider's retained sealed plan and durable Job receipts
before accepting complete-overwrite completion. The exact correlated Job must be
terminal and contain one successful receipt for every step. All nine published
partition effects must have a unique matching write and full-hash verification,
including exact offsets, lengths and expected content hashes, followed by reboot
and canonical postflight. Skips, sampled or short reads, missing or duplicate
receipts, other-Job receipts, failed writes and unavailable proof retain the
blocker. This enforces the existing full-verification requirement; it changes
neither the Provider coverage declaration nor the allocation budget.

The check covers live completion, later step projection, postflight publication,
finalization and passive reconciliation. Reconciliation revalidates even an old
cached postflight receipt, so restarting cannot promote that cache into full
proof. All reads use the owned Provider's sealed-plan/Job store; no verification
read, new permit or device action is dispatched by this check.

The regression retains original unknown history and the consumed allocation,
publishes no epoch or binding revision, and refuses another allocation after
restart. Complete synthetic recovery and publication-crash recovery still pass.
Synthetic receipts remain test data and do not complete hardware acceptance.
A separate read-only HDC mount diagnostic confirmed that the booted `userdata`
filesystem is mounted writable. It is diagnostic data, not Runtime evidence;
the existing verification port must refuse full-hash claims on a writable mount.

### Local targeted checks

Windows, 2026-10-18 local date. Logs use
`D:/src/ArkDeck-wt/tools/recommission-windows-hdc-full-readback-` and suffix
`-20261018.log`, in the same two-job per-chat Cargo cache.

- `test -p arkdeck-hoststore --test flash_run incomplete_recommission_readback
  -- --nocapture` exits 101 on the previous implementation (`red`): actual
  result `recovered`, expected `waitingForRecovery`.
- `test -p arkdeck-hoststore --test flash_run recommission -- --nocapture`
  exits 0 (`boundaries`): eight cases pass, including eleven incomplete-proof
  variants and passive reconciliation with and without a cached postflight.
- `clippy -p arkdeck-provider-arkforge -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings` exits 0 (`clippy`).
- Closed inventory validation exits 0 (`inventory`): 948 source files, with
  both new cases assigned only to Catalogs declaring recommission; all original
  fixture bytes remain unchanged.
- The final focused recommission run exits 0 with all eight cases passing
  after the final proof classification changes (`final`).
- `test -p arkdeck-provider-arkforge -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --lib` exits 0 (`libraries`): 91 Provider, 415 hoststore,
  three daemon and three soak cases pass; four existing hoststore cases remain
  ignored.
- `test -p arkdeck-agentd --bin arkdeck-agentd --test windows_flash_lane_process`
  exits 0 (`native`): 43 binary and three isolated native lane cases pass.
- Required `fmt --all --check` exits 1 at Windows OS error 206 (`fmt`); direct
  rustfmt checks over all eleven changed Rust files exit 0 (`fmt-files`).
- `ARKDECK_PYTHON=python sh scripts/check-sdd.sh` exits 0 (`sdd`), as does
  `git diff --check`. No contract inputs, Swift or App code changed; the full
  cross-platform and frozen-oracle checks remain selected PR CI work.

### CI

PR [#2664](https://github.com/ArkDeck/ArkDeck/pull/2664), based on
[#2663](https://github.com/ArkDeck/ArkDeck/pull/2663), passed Swift CI
[39054333985](https://github.com/ArkDeck/ArkDeck/actions/runs/39054333985) and
SDD Guard [39054333735](https://github.com/ArkDeck/ArkDeck/actions/runs/39054333735)
on head `ecdf8fdad26d6c4cff5c3ab599628226cd0efef7`. All selected Linux, macOS
and Windows workspace and contract checks passed, including complete formatting;
both required `guard` and aggregate `swift` reported success. Unchanged Swift/App
lanes were skipped. These results do not constitute hardware acceptance or renew
the exhausted independent allocation.

PR [#2664](https://github.com/ArkDeck/ArkDeck/pull/2664) initially failed the
host-independent formatting step in run
[39054024691](https://github.com/ArkDeck/ArkDeck/actions/runs/39054024691): the
non-Windows daemon test imports `flash_lane.rs` through `#[path]`, so its new
child module needed an explicit path relative to that shared file. A direct
rustfmt check of that consumer reproduced the failure (`format-red`, exit 1).
The explicit child path makes both consumers pass (`format-green`, exit 0),
with no change to the test data or assertions. The refreshed source inventory
retains all original fixture bytes and both new Catalog routes.

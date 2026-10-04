# Durable recovery archive — host verification

Date: 2026-10-04. Task: TASK-XPA-019. Synthetic fixtures and isolated host owners only;
no device operation, physical cleanup, installed-Runtime cutover or hardware acceptance.
This slice builds on the existing recovery controls in PR #2467.

`job.archive.preview` pins the complete durable Job record and journal with a review
SHA-256. `job.archive` rechecks the preview before and after taking the journal writer,
then durably appends the existing abandon intent, state transitions and abandon outcome.
A crashed write resumes that original user decision; it never dispatches a Provider or
creates another confirmation. Session publication failure leaves a retryable publication
with that same decision. Original artifacts remain unchanged.

The eligible operations are the existing synchronous observe/diagnostics and deterministic
analyzers, with confirmed host-only/read-only effects, no resident runner, no capability
lineage, no outstanding/unknown effect, no hazard/residue, and a closed executed-step
process proof. Missing proof, torn journal, device mutation and delegated/managed work are
refused before archive writes and retain their hold. This does not claim archive support
for unknown device outcomes or TCP/UART recovery. The writer has no transport or
capability-store reference. The existing recovery proof and admission policy are unchanged.

App ingress retains the original App submission gate and an exclusive continuation claim.
ClientKit validates the exact Job, target, operation, Session, state, unknown flag, review
hash, original confirmation and publication receipt. Lost replies never auto-replay.
The scrollable bilingual native review shows the last confirmed step and refusal reasons;
confirmation is an explicit button and is disabled without Runtime proof. Prototype actions
remain unavailable without a Runtime review. CLI accepts only the three closed decision
parameters; caller-supplied authority or process facts are rejected.

## Local targeted checks

Logs are under `/private/tmp/arkdeck-macos-closeout-20261004/`.

- Six hoststore archive tests pass (`recovery-archive-core-atomic.log`): real journal/store
  and Session publication, stale/unknown/mutation/residue refusals with zero archive writes,
  every audit append cut point followed by restart, unchanged torn-tail bytes, publication
  failure/retry with the same confirmation, resident runner and capability-lineage refusal.
  These are synthetic host fixtures, not a device proof.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  'RuntimeJobArchiveApplicationFacadeTests|JobsLocalizationContractTests'`: exit 0;
  four Swift Testing cases plus six XCTest cases (`recovery-archive-swift-second.log`).
  Earlier compilation required an explicit `Any` in the test's mixed String/NSNull fixture.
- `CARGO_BUILD_JOBS=2 cargo clippy --manifest-path rust/Cargo.toml` for arkdeck-contract,
  arkdeck-client, arkdeck-soak, arkdeck-rockchip-binding, arkdeck-hoststore,
  arkdeck-provider-hdc, arkdeck-cli, arkdeck-provider-arkforge, arkdeck-agentd,
  arkdeck-control and arkdeck-bootstrap, with `--all-targets -- -D warnings`: exit 0,
  `recovery-archive-clippy-final.log`. This worktree owns its Cargo target directory.
- Initial broad Rust runs exposed the old App method roster and historical consumer pins
  (`recovery-archive-rust-tests.log`, `recovery-archive-rust-tests-final.log`,
  `recovery-archive-rust-remaining.log`). The gate test now names exactly the two new methods.
  Historical resume/continuation peers negotiate the current wire identity while retaining
  all business facts and refusal mutations; the CLI version test expects the current compiled
  identity. The bundle oracle retains its recorded bytes and exact cleanup/refusal behavior,
  rebasing only the two declared new products and four regenerated contract/index products;
  product counts advance from 235 to 237. No production negotiation check was relaxed.
- All required changed-crate/direct-consumer test targets have now passed. The complete
  agentd/bootstrap targets passed in `recovery-archive-rust-tests-final.log` before Cargo
  stopped at the old CLI resume fixture. The remaining nine crates ran with
  `cargo test --no-fail-fast`; only the three historical CLI targets noted above failed
  (`recovery-archive-rust-remaining.log`, exit 101). After their exact pin/count updates,
  `cargo test -p arkdeck-cli --test maintainer_contracts --test version
  --test workspace_continuation` exits 0 with 23 passing cases
  (`recovery-archive-cli-fixed.log`). The repaired resume target and all other remaining
  targets passed in the nine-crate run. The final CLI and App-ingress Clippy reruns exit 0
  (`recovery-archive-cli-clippy-final.log`, `recovery-archive-ingress-clippy.log`).
- `scripts/ci/run-xcodebuild.sh` App build-for-testing: exit 0,
  `** TEST BUILD SUCCEEDED **` (`recovery-archive-app-build.log`).
- Shared UI string generation check: exit 0, 1107 strings including 820 shared macOS keys
  (`recovery-archive-strings.log`).
- CLI/daemon prerequisite build: exit 0, `recovery-archive-binaries-final.log`.
  `check-readonly.py --write-machine-output` recorded actual isolated owners and passed:
  138 control responses, 13 CLI envelopes and 129 valid requests
  (`recovery-archive-readonly.log`). Existing historical ControlFrames remain byte-identical.
- The two new method schemas were derived from ten actual test-produced frames, with eight
  distinct retained shapes. Atomic recording fixed an initial interleaved temporary capture;
  malformed temporary lines were not used. The other 105 method schemas retain their prior
  shapes with only contract identity metadata refreshed. The resulting registry has 107
  methods and 1051 shapes, identity
  `a385fef3a995b3b67404eef9d081d14f42fdedc6eaee6a809593fee27768116b`.
  CLI contracts and 211 argv fixture files were exported by the actual rebuilt CLI; the owned
  product table pins their measured bytes. No Catalog operation was changed.
- `node --test docs/design/arkdeck-ds/scripts/*interactions.test.mjs`: exit 0,
  85 passing tests (`recovery-archive-ds.log`).
- Both contract generators' `--check`, Rust formatting and diff checks pass
  (`recovery-archive-generated.log`). `sh scripts/check-sdd.sh`: exit 0, zero errors and
  warnings (`recovery-archive-sdd-final.log`).

Native UI automation is not claimed: both earlier bootstrap attempts failed before any
assertion while enabling automation mode. No further identical retry was made. Windows
ClientKit tests require CI because this host has no .NET SDK. No full local unified gate
was run.

## CI

Parent recovery-controls PR #2467 is green at head
`9557a653dbebc333e44cf30c36280a6fffb9330e`: Swift aggregate run `37181656779`
and SDD run `37181656627`. Its optional UI job remains pending at this recording.
Archive changes will be submitted to the selected GitHub lanes and maintainer review.
A green CI result does not approve or publish device execution.

Diagnostics PR #2465 also completed its selected checks at head
`600da7c8231e8400668753a1f33860c9f21a9156`: Swift aggregate run `37182721655`
and SDD run `37182721439` are green, including Rust parity on all three platforms.

### Windows publication failure investigation

Local targeted checks: the seven archive tests, including a real private-root
storage capacity probe, pass on macOS (exit 0;
`/tmp/arkdeck-macos-closeout-20261004/recovery-archive-storage-diagnostics.log`).
Hoststore Clippy with all targets and denied warnings passes (exit 0;
`recovery-archive-storage-clippy.log`). Failure assertions now include the actual
durable publication marker, without changing their required success result.

CI: PR #2468 run `37184325231` failed the Windows workspace and contract parity
lanes at the three archive Session-publication success assertions. The result
was `storageUnavailable`, not a failed abandonment decision. macOS workspace,
Linux, App, Swift, design and Windows ClientKit lanes passed. This diagnostic
head adds the missing failure detail and a real capacity probe so the Windows
cause can be fixed from evidence; it does not claim the failure is repaired.


### Canonical Windows fixture root correction

Local targeted checks: all seven archive tests pass after the path correction
(exit 0; `recovery-archive-canonical-path-tests.log`); hoststore Clippy with all
targets and denied warnings passes (exit 0;
`recovery-archive-canonical-path-clippy.log`). The fixture now uses the existing
Session-owner canonical path helper. Windows `std::fs::canonicalize` returns a
verbatim drive path, while the Session configuration deliberately compares its
plain local-drive spelling; production path/identity checks are unchanged.

CI: PR #2468 diagnostic run `37185577438`, Windows workspace job `111386888923`,
passed the real capacity probe but repeated the three publication failures. The
durable marker identified `recordUnreadable: Session storage is unavailable or
unsafe` before capacity admission, with an empty selected root. This matches the
fixture's noncanonical stored path and the existing `locked_storage` comparison.
The corrected Windows execution is pending in the next PR run; macOS success
alone is not reported as Windows verification.


## Main compatibility follow-up

PR #2468 head `024511e9` passed all selected lanes in Swift CI run `37186647925`
and SDD Guard run `37186647718`, including Windows/macOS workspace and contract
parity. This confirms the canonical local-drive fixture path correction on Windows.

The branch now inherits recovery-controls compatibility head `545d4fdee` and main
`2d85d513d`. Conflicts were limited to the shared string registry and its three
Windows outputs. All 19 archive-only keys were applied against the common
baseline and outputs regenerated; the archive proof/dispatch behavior is unchanged.

### Local targeted checks

- Swift archive/recovery facades and Jobs localization: 17 tests passed, exit 0 (`archive-merge-swift.log`).
- App build-for-testing: exit 0, TEST BUILD SUCCEEDED (`archive-merge-app.log`).
- Design-system tests: 85 passed, exit 0 (`archive-merge-ds.log`).
- Windows strings and ClientKit, 107-method contract generation, Rust formatting, diff checks and SDD: exit 0 (`archive-merge-sdd.log`, zero errors/warnings). The generator verifies 1,186 strings, including 898 unchanged shared macOS values.

### CI

Fresh CI on the compatibility head is pending. The prior all-green result is not
represented as validation of a different head, and no maintainer or hardware
approval is inferred. No full local unified gate or device operation was run.

## Shared-resource compatibility with October 4 main updates

The previous archive head `d1f01bd61` passed all selected Swift CI lanes in run
`37189187886`; current-merge SDD Guard run `37191326873` also passed. The obsolete
base-change run `37189334908` failed before validation because its event contained
the previous merge SHA; no test assertion or SHA guard was weakened.

This merge inherits recovery-controls head `b748ab46b` and main `1f05dce05`.
The shared registry keeps all incoming Windows resource keys and all 19 archive
keys, and the three Windows resource outputs were regenerated. The archive proof,
dispatch behavior, Swift/App sources, and design-system prototype are unchanged
from the previously verified archive head.

### Local targeted checks

- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --lib job_archive::tests`: 7 passed, exit 0 (`/tmp/arkdeck-macos-closeout-20261004/archive-main2-rust.log`).
- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --bin arkdeck-agentd app_ingress_tests::recovery_tests::`: 4 passed, exit 0 (same log).
- Windows string generation and consumer-reference checks: exit 0; 1,280 entries, 46 snapshots and 286 resource references resolve (`archive-main2-strings.log`).
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `sh scripts/check-sdd.sh`, and staged/unstaged `git diff --check`: exit 0; SDD reports zero errors and warnings (`archive-main2-sdd.log`).
- Swift, App and design-system checks were not repeated locally because their inputs did not change; the previous head passed those CI lanes. The full unified gate runs only in PR CI.

### CI

Fresh PR #2468 CI is pending for this merge. Previous-head results above do not
validate the new commit. No device execution, runtime-authority write, maintainer
approval or real-device acceptance is claimed.


## Stack synchronization after diagnostic publication

The archive layer now inherits recovery-controls head `53886bcfc` and published
main `535f0de85`. The three diagnostic control leaves and two archive leaves are
preserved together in the registry, CLI projection, bundle and wire consumers.
Conflicts in historical fixtures are limited to generated contract identities;
existing refusal, health mismatch and continuation assertions remain intact.
All 19 archive string keys survive alongside the newly published diagnostics and
Windows history resources. No archive admission or dispatch policy is changed.

### Local targeted checks

All log paths below are under `/tmp/arkdeck-macos-closeout-20261004/`.

- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-contract -p arkdeck-control`: exit 0, 100 tests passed (`archive-main3-contract-tests.log`).
- Focused CLI coverage and archive/registry/bundle integration tests: exit 0, 38 tests passed (`archive-main3-cli-tests-final.log`). Archive owner and daemon App-ingress tests: exit 0, 48 tests passed (`archive-main3-owner-tests.log`).
- `CARGO_BUILD_JOBS=2 cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-contract -p arkdeck-control -p arkdeck-bootstrap -p arkdeck-client -p arkdeck-provider-arkforge -p arkdeck-provider-hdc -p arkdeck-rockchip-binding -p arkdeck-hoststore -p arkdeck-cli -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`archive-main3-clippy.log`).
- `run-swiftpm.sh test --filter 'RuntimeJobArchiveApplicationFacadeTests|RuntimeJobRecoveryApplicationFacadeTests'`: exit 0, 11 tests passed (`archive-main3-facades.log`). Jobs localization: 6 tests passed (`archive-main3-swift.log`); the initially misspelled facade selectors matched zero and are not counted.
- `ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED (`archive-main3-app.log`). `npm test --prefix docs/design/arkdeck-ds`: exit 0, 85 tests passed (`archive-main3-ds.log`).
- Actual isolated read-only CLI/daemon recordings: exit 0, 141 control and 13 CLI responses across 132 requests (`archive-main3-readonly-final.log`). The first interpreter lacked `jsonschema`; the successful recording uses the pinned contract-check environment and does not access a device or production state.
- Contract/ClientKit/string generator checks, owned bundle digests, Rust formatting and diff checks: exit 0. Vocabulary is 110 methods and 1,073 recorded shapes; all 1,294 string entries, 46 snapshots and 286 resource references validate. SDD: exit 0, zero errors and warnings (`archive-main3-sdd.log`).

### CI

PR #2468 retains #2467 as its direct base. New-head CI is pending after this push;
prior-head results above are not presented as validation of this merge. The
existing Agent PR workflow still assumes base `main`; its metadata failure on
this stacked branch does not change the base or count as a passing check.
Native Windows validation remains in PR CI. No full local unified gate or
real-device acceptance is claimed.


## Archive stack refresh for overview resource additions (2026-10-04)

Merged direct parent `e253848b6`, which includes main `587c938b4`. The only
conflicts were appended shared strings and the three generated Windows consumers.
The key-based source merge retains every value from both heads: all 19 archive
additions coexist with the five new overview device keys. Regenerated consumers
match 1,299 entries. No archive owner, App ingress, ClientKit facade, App source,
or contract input was manually changed by this resolution.

### Local targeted checks

All logs below are under `/tmp/arkdeck-macos-conflicts-20261004/`.

- `python3 windows/scripts/generate-ui-strings.py --check`: 1,299 strings pass, exit 0 (`archive-strings.log`). The existing resource-reference checker validates 46 snapshots, 291 references and literal UI-test lookups (`archive-resource-references.log`).
- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --bin arkdeck-agentd app_ingress_tests::`: 41 pass, exit 0 (`archive-ingress.log`).
- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --lib job_archive::`: 7 pass, exit 0 (`archive-owner-targeted.log`). The initial command omitted `--lib`, built unrelated integration targets and was interrupted; that incomplete run (`archive-owner.log`) is not claimed as a pass.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter RuntimeJobArchiveApplicationFacadeTests`: 4 pass, exit 0 (`archive-swift.log`).
- `CARGO_BUILD_JOBS=2 cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-hoststore --all-targets -- -D warnings`: exit 0 (`archive-clippy.log`). Rust formatting, SDD and diff checks pass (`archive-fmt.log`, `archive-sdd.log`).
- App build-for-testing, CLI and unrelated crate suites were not repeated for this resource-only conflict resolution. The full selected validation remains in PR CI; no device execution occurred.

### CI

PR #2468 keeps #2467 as its direct base. This push creates fresh head checks;
previous-head results are not reused as evidence for the new merge. The existing
Agent PR workflow's fixed-main metadata assertion remains a separately reported
compatibility issue; it does not justify retargeting this dependent PR.

## CI repair after the recovery parent was published, 2026-10-04

The three contract-parity jobs in run `37198785153` failed because their
isolated views omitted `openspec/integrations`; the registration tests could
not read the exact Windows/macOS registries and lock. Published fix #2498
copies those inputs into each view without skipping tests. The branch now
merges main `b73ae1a16`, including that fix, stack-aware PR automation #2490,
and the shared oracle compilation fix #2511.

The recovery parent #2467 was squash-merged. Source conflicts were reconciled
against its original reviewed head `e253848b6` so only archive changes are
added to the published implementation. All existing bilingual values are
preserved, with 19 archive keys added; consumers are regenerated from source.
Recovery, archive eligibility, identity and capability checks are unchanged.

### Local targeted checks

Logs are under `/tmp/arkdeck-macos-ci-20261004/`; completed checks exit 0.

- `check-isolated-registration.py` uses the repository's actual `materialize`
  function and verifies every copied integration file byte-for-byte. The exact
  failed `windows_hdc_registration` target passes 8 tests in the published view
  and 8 in the candidate view (`isolated-registration.log`).
- `rust/scripts/test_contract_checks.py`: 54 pass (`contract-view-tests.log`),
  using the existing dependency-equipped Python environment. Initial runs with
  the host Python lacked `jsonschema`/`yaml` and are not counted as passes.
- Daemon `app_ingress_tests`: 41 pass; hoststore `job_archive::` unit tests:
  7 pass (`archive-ingress.log`, `archive-owner.log`).
- All-target Clippy for agentd, hoststore, control and CLI passes
  (`archive-clippy.log`). Its initial compilation failure was the undefined
  `owned` argument on main, resolved by inheriting published #2511.
- Swift `RuntimeJobArchiveApplicationFacadeTests`: 4 pass (`archive-swift.log`).
- The focused archive/recovery prototype tests pass (`archive-interactions.log`).
  Contract and Windows ClientKit generation agree on 110 methods and 1,073
  recorded shapes; 1,349 UI resources preserve the macOS values. Owned bundle
  digests, Rust formatting, SDD and diff checks pass.
- `ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`: exit 0,
  `TEST BUILD SUCCEEDED` (`archive-app.log`). No full local unified gate or
  device execution is claimed.

### CI

PR #2468 now targets main after #2467's publication. Run `37198785153` and
Agent PR run `37198784985` remain historical failures; the new merge must pass
fresh required checks. Its run IDs and current results are recorded in the PR
description after push. Maintainer review remains required.

## macOS final-reply timeout race, 2026-10-04

Fresh head `a40c784b82aa38c9907a7c0a57271660420ebeca` fails Swift CI run
`37209275788`, macOS contract job `111457146829`, at
`real_cli_daemon_three_kinds_restart_and_lost_commit_reply` in the candidate
view. Its final `artifact.import.inspect` reports `EINVAL`. A deterministic
local socket reproduction proves Darwin rejects a read-timeout refresh after
peer close even while the complete final reply remains buffered. The isolated
published and candidate tests passed standalone before the correction, but
that alone does not meet the four invalid-run criteria: this is a code failure,
not a load-related retry.

The shared transport tolerates the failed timeout update only on macOS, only
for `EINVAL`, and only after zero-wait kernel `poll` proves `POLLHUP`. Such a
receive stream can only drain existing bytes and reach EOF; it cannot wait for
new bytes. Zero budgets and other errors still fail. Bounded client deadline
checks, framing, health validation and no-replay semantics remain in force.
The new regression joins the peer before reading and verifies complete,
truncated and empty frames without a timing delay or weakened assertion. The
same fix is included in #2473, whose consumers share this transport.

### Local targeted checks

Logs are under `/tmp/arkdeck-macos-ci-20261004/`. The deterministic regression
fails before the correction with the exact `EINVAL`
(`socket-regression-before.log`, exit 101). After the fix these commands exit 0
(`CARGO_BUILD_JOBS=2`):

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform --test unix_transport`:
  7 pass, including complete-frame drain, incomplete EOF, zero-budget refusal
  and a live peer's read timeout (`archive-socket-regression.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-client --test bounded`:
  4 pass, retaining one total budget and refusal to replay
  (`archive-socket-regression.log`).
- `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli --bin arkdeck`, then
  `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test import_publication_process`:
  the real CLI/daemon restart and lost-commit-reply journey passes
  (`archive-import-regression.log`).
- All-target Clippy with `-D warnings` passes for platform and its direct
  dependents: agentd, bootstrap, CLI, client, hoststore, provider-arkforge,
  provider-hdc, provider-workspace and rockchip-binding (`archive-socket-clippy.log`).
  The target-specific direct dependent soak also passes all-target Clippy
  (`archive-socket-soak-clippy.log`).
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `sh scripts/check-sdd.sh`
  and `git diff --check` pass (`archive-socket-fmt.log`, `archive-socket-sdd.log`).

The full local unified gate and unrelated App/Swift tests are not repeated for
this Rust-only correction; PR CI checks the complete diff. No device execution
or native UI acceptance is claimed.

### CI

PR #2468 run `37209275788` remains a failure on the preceding head. This
correction requires fresh `guard` and `swift` results on its pushed head; the
run IDs and conclusion are recorded in the PR description after push. No test
assertion is relaxed, no sleep is added, and no failed run is counted as passed.

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

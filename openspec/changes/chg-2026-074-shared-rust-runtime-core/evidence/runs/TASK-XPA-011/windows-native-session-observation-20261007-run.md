# Native deployment Session observation and cleanup semantics

`deploy.native-library.app-owned@1` could complete its native deployment while
Session publication refused the absent job-local target/tool observation. The
resulting unfinalized terminal Job correctly blocked the complete Import-owner
census. CHG-2026-081 adds the existing target/model/firmware read-only prefix
after local ELF/hash validation and before capability consumption or send.
The existing Runtime accumulator retains the actual verified observation.

A confirmed failed final cleanup also previously left the Job succeeded,
which the unchanged Manifest validator refused because its executed Step had
failed. Native now closes that case known failed, retains its verified
replacement and original failed outcome/products, and persists exact cleanup
debt without an extra rollback. Deployment or loader verification failures
still follow the original rollback policy. The housekeeping failure remains
formal forward acceptance FAIL. This interpretation is proposed for explicit
maintainer review in CHG-2026-081; no accepted Core predicate is weakened.

Final and compensation Native cleanup debt now require a readable ledger,
idempotent exact outstanding residue/action, positive residue count and durable
Job record. An already-settled same-step row cannot certify a newly failed cleanup.
Storage uncertainty parks without publication or replay. The existing
reconcile/cleanup-continuation prerequisites do not provide a storage-only
repair when the exact ledger record is absent; no new recovery route is added.
Older Jobs cannot acquire missing historical observations from this prefix.

The global Catalog changes from
`c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036` to
`e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7`.
All 31 other operation descriptors compare fully equal. Native's complete
descriptor equals its prior value after removing exactly the three new steps.
Historical native fixture bytes remain unchanged. Current synthetic proof
requires genuine prefix readbacks, whole published Manifest bytes, one
finalized event and clear complete Import inspection. No hardware result,
private account state, DevEco/Harmony SDK material or real transport was used.

The separate observed-v1 oracle retains all 40 original exchanges and all 225
original transport calls, with exactly 15 new evidence-prefix reads. Its five
complete Session and unrelated Import-census proofs include the truthfully
failed housekeeping case. All current answers and durable outputs are checked;
the original fixture is neither rewritten nor treated as a current publication
oracle. The new ten-row HAP plan capsule separately reproduces every original
whole plan hash before deriving the new Catalog-bound digest. Its policy test
also hashes the complete original scope material before checking the old ID;
no Runtime Catalog override or historical capability migration is introduced.

## Local targeted checks

Checks use the stable `signing-readiness` Cargo owner and fixed external cache,
with two jobs. Commands and immutable results are retained under
`D:/src/ArkDeck-wt/tools/logs/native-session-observation-20261007`.

- `python scripts/catalog_gen/generate.py --check`,
  `python rust/scripts/generate-contract.py --check` and
  `python -m unittest discover -s scripts/catalog_gen -p test_generate.py`:
  final exit 0; 49 generator cases passed (`light-27.json`, corresponding
  `*-27.log`; original `light-3.json` remains).
- `python rust/scripts/run-cargo.py fmt -p arkdeck-hoststore`:
  exit 0 (`fmt-hoststore-7.log`).
- `python rust/scripts/run-cargo.py test --locked --offline -p arkdeck-hoststore --test native_library_run`:
  exit 0; nine cases passed (`native-run-6.log`, `run-6.json`).
- `python rust/scripts/run-cargo.py test --locked --offline -p arkdeck-hoststore --lib native_library_plan::tests`:
  exit 0; one unit case passed (`native-plan-unit-6.log`).
- `python rust/scripts/run-cargo.py clippy --locked --offline -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0 (`clippy-6.log`).

- `python rust/scripts/run-cargo.py test --locked --offline -p arkdeck-hoststore --test native_library_current_oracle`:
  exit 0; three cases passed and its explicit CREATE_NEW recorder remained
  ignored (`native-current-replay-16.log`, `replay-16.json`). The recorder ran
  separately once with its exact task-owned destination (`native-current-record-10.log`).
- Native plan/run targets: exit 0; two plan and nine run cases passed,
  including strict corrupt, denied-directory and settled-row cleanup debt
  refusals with no replay (`native-plan-run-16.log`).
- Native submission target: exit 0; four cases passed with the admitted
  checkpoint, whole authority/index checks and zero-dispatch predicates
  preserved (`native-submit-17.log`, `admission-agentd-17.json`).
- Both exact signed-daemon Native CLI targets: exit 0; one full replay and one
  domain-leaf case passed (`agentd-native-replay-17.log`,
  `agentd-native-leaf-17.log`). These use compiled stand-ins and temporary
  fixture roots, rather than the installed Runtime or HDC.
- Portable Catalog-lineage target: exit 0; five cases passed
  (`catalog-lineage-18.log`). The analyzer integration target contains no
  Windows cases and is not counted as executed.
- Exact ten-row whole HAP plan/capsule unit: exit 0
  (`hap-plan-capsule-19.log`, `capsule-19.json`). Each original full digest
  was reproduced before the fresh capsule was created.

- Whole affected-crate checks ran serially after Root's normal Runtime/HDC
  shutdown: `python rust/scripts/run-cargo.py test --locked --offline -p <crate> -- --test-threads=2`,
  for Hoststore, Agentd and Soak (`crates-20.json`). Hoststore exited 101 after its library suite:
  367 passed, one stale Flash generated-literal failure and four ignored;
  later integration targets were not reached. Agentd exited 101: 95 passed,
  two failed and three ignored across its reached suites. Its two exact
  failures are the historical GJ-1 observation Artifact byte expectations
  (`gj1_device_leaves.rs:450`) and historical full HAP replay
  (`hdc_oracle.rs:793`), after the global Catalog changed. The current full
  Native replay and domain leaf both passed in that same run. Soak exited
  0: five passed, one explicit signed-soak fixture ignored. Full logs are
  `hoststore-crate-20.log`, `agentd-crate-20.log` and `soak-crate-20.log`.
- Official static Flash generator on Windows: exit 0
  (`flash-generator-22.json`, separate stdout/stderr logs). A comparison of
  its entire emitted Swift source proves every byte apart from the exact
  single Catalog SHA is unchanged. The existing pure library export and
  example are enabled on Windows; this performs no Runtime/device work.
- Only the failed Flash projection unit was rerun: exit 0; one case passed
  (`flash-projection-23.log`, `projection-23.json`). This does not turn the
  retained Hoststore crate result into a full passing run.
- Exact observation payload tamper/full-byte proof and prior signed resume
  failure were rerun separately: each exit 0, one case passed
  (`observe-byte-proof-26.log`, `observe-resume-leaf-26.log`,
  `observation-26.json`). The expectation independently reproduces all three
  frozen content-derived Artifact IDs before deriving current SHA/reference;
  every receipt field remains compared.
- Final affected all-target clippy: exit 0 (`clippy-24.log`); Agentd was checked
  again after the observation test-source correction, exit 0
  (`agentd-clippy-26.log`).
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1 because Windows
  refused the overlong rustfmt argv with OS error 206 (`fmt-all-25.log`).
  Bounded `fmt -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --check`:
  exit 0 (`fmt-affected-26.log`). Its earlier current-Native test-hunk
  formatting failure is retained at `fmt-affected-24.log`.
- `sh scripts/check-sdd.sh` and `git diff --check`: final exit 0
  (`sdd-28.log`, `diff-28.log`, `docs-28.json`).
- The first selected CI planner failure was reproduced and corrected at its
  actual prototype consumer. `npm test` in `docs/design/arkdeck-ds`: exit 0;
  86 cases passed, zero skipped (`ds-interactions-33.log`,
  `ds-interactions-33.json`). The original parity assertion is unchanged;
  `DEBUG_PLAN_STEPS` gains only the three exact required read-only rows, with
  every unrelated prototype byte preserved. No App feature or test gallery
  is introduced by this derived-plan update.
- The current HAP software oracle was generated once through production
  owners in a temporary test namespace: exit 0 (`hap-record-38.json`). It
  preserves all 63 original requests and 108 fake-HDC calls, every historical
  file's hash, and the original states, unknown outcomes, residue and complete
  capability use/count predicates. The separate 199-file fixture is
  `debug-hap-catalog-e4-v1`; no old authority seed or golden byte was changed.
  Its eight lineage guards passed (`hap-lineage-38.log`), including the exact
  mandatory step-set digest and complete raw plan answer before host labels.
- The new whole HAP replay passed two cases (the CREATE_NEW recorder is
  explicitly ignored in normal runs); the old terminal-authority refusal,
  existing full HAP recipe, exact signed CLI replay and domain leaf each
  passed one case (`hap-replay-39.json`). The first differing historical
  answer was `installed.plan.result.catalogDigest`: the full ten-plan capsule
  independently proves old and current digests; fresh authority and its
  publication hashes are recorded under the current Catalog instead of
  translated from historical outputs.
- The selected Windows CI Flash consumer was reproduced exactly: six cases
  passed, zero skipped, exit 0 (`root-flash-targeted-35.json`). Its JSON is
  byte-for-byte identical except one Catalog SHA and equals the entire
  official Swift literal. The Swift step-kind expectation gains exactly the
  two new Native read-kind references; all 32 earlier entries and the complete
  dictionary equality remain (`root-consumer-complete-proof-36.json`). Swift
  is unavailable locally, so that source test awaits selected CI.
- After the shared fixture routing changed, current Native's three normal
  cases passed with its recorder explicitly ignored (`native-shared-regression-40.log`).
  Final all-target clippy for Hoststore, Agentd and Soak and bounded affected
  formatting both exited 0 (`compile-41.json`). The initial duplicate
  test-module load failure is retained in `clippy-hap-40.log`; one shared
  import replaces the duplicate, with no behavior or assertion change.
  Sandbox-only run 37 stopped at repository ownership before any check;
  the normal-owner run used the unchanged stable cache and Git trust.

Live opt-ins were cleared; account fixtures use private temporary profiles
and their own stand-ins. The original HAP whole-answer failure is retained;
the new current-Catalog whole oracle closes its targeted replay without
rewriting old authority or accepting a learned Catalog/issuer mapping.
The affected Swift case and macOS analyzer comparisons are not locally
executable on Windows and remain for selected CI.

Initial source/test failures remain in their original logs: generator fixture
count/action assumptions; generated newline handling; current publication
phase and missing-firmware expectations; the demonstrated succeeded/failed
cleanup contradiction; and an incorrect test assumption about the public
`session.show` hash field. `run-3.json` records the runner lock refusal while
the prior formatter was still active. These outcomes are not counted as passes.
The exact current Native replay also retained its initial random Import ID
and derived Session ID comparison failures, and the initial old Agent plan
issuer expectation. The old HAP policy-ID unit failure is retained separately
from its corrected full-material proof. Full Hoststore run 20 retained its
367 passed, one stale generated Flash projection failure and four ignored
cases in `hoststore-crate-20.log`; a later targeted result does not erase that
original crate outcome.
The first Windows static-generator attempt also retained its missing
macOS-only re-export compilation error (`flash-generator-21.stderr.log`).

Independent source review by the Native consumer owner found no production
authority, chronology or debt/replay defect. A separate reviewer confirmed
the complete old/current Catalog and HAP plan proof; neither review involved
private state, signing or hardware execution.

## CI

PR #2628, first head `c8d6b09f7b01eb33ebcf5640be6fa50e3843ca0a`:
Swift CI run `37580807219`, planner job `112659776407`, failed the existing
Native prototype/Catalog parity assertion at `workspace-interactions.test.mjs:992`.
Its actual prototype list lacked the three new read-only rows. Compile lanes
were skipped and the `swift` aggregate failed; this was not a passing CI run.
The full public job log is retained as
`ci-plan-37580807219-112659776407.log`. The bounded consumer correction and
86-case local result above accompany a normal follow-up commit. Selected CI
for that updated head remains pending. No maintainer approval, protected
publication, real-device result or historical census repair is claimed.

At head `826be6fd1d0cb28efe0c906328a24a5e2de445e4`, Swift CI run
`37581515286` reached the compile lanes. Windows ClientKit job `112662109804`
failed the existing `FlashTests` whole JSON equality: the Windows Flash copy
still carried the old Catalog SHA. Swift tests job `112662109835` failed the
existing whole step-kind dictionary equality: two new Native read kinds were
missing from its expectation. The complete original logs are retained as
`root-ci-windows-clientkit-37581515286-2.stdout.log` and
`root-ci-swift-tests-37581515286-2.stdout.log`. Both are concrete derived
consumer defects; neither assertion was weakened. The follow-up includes
their exact source corrections and the current HAP software oracle. CI for
that follow-up has not run at the time of this record.

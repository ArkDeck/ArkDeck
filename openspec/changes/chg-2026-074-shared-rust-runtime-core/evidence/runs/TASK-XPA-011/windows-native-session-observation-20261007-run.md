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

The bounded cross-view follow-up keeps the original c6 positive oracles in a
mandatory, independently pinned input view over current Rust. Exact mixed
function routes keep current source-drift refusals and current Native/HAP/GJ-1
owners under e4. All 32 descriptors, complete original/versioned fixture bytes,
and source inventories are closed. Same-name Cargo targets retain `--workspace`
feature selection; compile JSON and each Cargo `Running` source/executable
bind every list and execution receipt to its actual package target. The 15
custom harnesses use their real listed/default protocol. Known child entries
and absent external-material opt-ins retain their actual reported status but
cannot count as substantive coverage or live signing/distribution evidence.

- Current Native's separate c6 oracle was generated once through real software
  owners (`published-native-59.json`). It retains all 40 original requests and
  the full 43-file/225-call historical provenance. The current missing-preflight
  guard truthfully refuses before device mutation: actual calls are zero, all
  five Jobs are known failed, no observation or capability consumption is
  invented, and each whole diagnostic Session has one finalized event plus
  clear unrelated Import inspection. The e4 oracle still requires all 40
  exchanges and 240 exact calls; the c6 result is not hardware acceptance.
- Normal c6 HAP and Native replays actually passed five cases, with two
  recorders explicitly ignored (`published-replay-target-61.log`,
  `published-replay-61.json`). The outer wrapper then failed while reserving an
  already-used receipt filename. Its original failure is retained; the separate
  CREATE_NEW `published-replay-61-wrapper-supplement.json` records that the test
  process exited 0. No successful test was rerun to replace that wrapper failure.
- Closed view guards passed 28 pure cases; execution guards passed eight pure
  cases. Post-merge historical reconstruction passed nine pure cases, including
  the full official c6 matrix and exact non-Catalog bytes. The earlier 26-case,
  8-case and 9-case source snapshots remain in Root's `55`, `65` and `64`
  receipts; newly added child/optional-material assertions are separate.
- The dependency-free Cargo feature-union fixture passed one case, exit 0
  (`native-router-1/checks.json`). Package-only selection genuinely fails its
  feature-union assertion; the workspace command executes three exact filters
  across two same-name targets with complete build/Running/case receipts. No
  product Runtime, account store, SDK, HDC or device is used by this fixture.
- Only affected source checks ran in `dual-view-close-69.json`: Native and HAP
  full-plan units each passed one case; current cleanup continuation passed all
  eight cases; Hoststore/Agentd all-target clippy and affected formatting exited
  0. The existing macOS-only reviewed-plan negatives remain for actual CI;
  their Windows cfg exclusion is not reported as a passing execution.
- The original generated CLI consumer checks remain passing in
  `cli-consumer-52.json`: exact operation projection, whole machine bundle and
  maintainer contract consumers. The original c6/e4 source-view mismatch and
  rejected or malformed recorder attempts remain in their logs; no frozen
  source, seed, authority or expectation was edited to erase them.

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

At head `87fcfeae77e5360933b17f54264dc46be8f7fca9`, run `37584367552`
passed the planner, App build, Swift tests, Windows ClientKit and
host-independent lane. Ubuntu parity failed the published c6 view's
unconditional current-Catalog source assertion; Ubuntu workspace failed stale
generated CLI/Native projections. macOS and Windows parity exposed current-only
selectors used under c6. Their workspace lanes exposed historical c6 whole
plan/authority/artifact expectations being run as e4, including 35 failed
Windows functions in job `112671304507`. All full original logs are retained.
The follow-up fixes derived consumers and introduces the exact mandatory
two-view execution above; its new-head CI result is pending. Existing accepted
assertions, original requests and authority are preserved rather than broadly
translating digests or ignoring the failing cases.

At head `e15c85cb595b6823a77fccf210d39394c3d6aeb8`, run `37598243309`
passed the planner, Swift tests, App build, Windows ClientKit and
host-independent lane. Workspace/parity execution reached concrete additional
consumer defects. Linux/Windows CLI targets whose only test module is macOS
were mistaken for an unclassified empty target. The historical materialization
embedded the merge-base byte baseline instead of the reconstructed selected
input baseline. Three original HAP plan/admission functions and three macOS
service-verification functions still compared their complete c6 recordings in
the current view. The full failed job logs are retained as
`ci-job-112716400898-79.stdout.log`, `ci-job-112716400887-79.stdout.log`,
`ci-job-112716400836-79.stdout.log`, `ci-job-112716400858-79.stdout.log` and
`ci-job-112716400811-79.stdout.log`.

The bounded follow-up keeps these original complete assertions mandatory in
the historical view. The original nine Native plan requests likewise keep
their whole c6 frames; the current five full-plan hashes and the 40-exchange,
240-call Native owner replay remain mandatory. The HAP persisted-consumption
negative now uses the source-bound current evidence record, preserving its
three read-only calls, zero consumption and zero send assertions. It no longer
transplants a terminal legacy step digest into a fresh current admission.

The Native public Session aggregate mismatch was a recording representation:
the normalized retained Manifest says `PLATFORM-MACOS@0.2.0`, while the original
Windows public receipt includes the longer Windows platform value. The consumer
reconstructs only that unique typed field and first proves every original
Manifest SHA/count and complete original Session aggregate. It then verifies
the actual raw Manifest receipt and whole tree size, and derives the host
aggregate from the same complete entry census. The existing whole-file and
tree equality remains unchanged; no arbitrary size mapping is learned.

### Local targeted checks for the e15 follow-up

`router-close-80.json` records 28 closed-view guards, 12 execution guards and
10 historical materialization guards, all exit 0. Root independently passed
seven readonly derivative guards (`root-readonly-view-80.json`) and four exact
nested-module host guards (`root-module-cfg-82.json`). No empty list alone
permits an exclusion: the nine source-pinned inactive targets execute their
normal workspace command and require one exact zero-case receipt; they report
no coverage. Unknown targets, active-host emptiness and incomplete receipts
still fail.

`consumer-checks-84.json` records affected formatting exit 0, the HAP
persisted-consumption negative 1/1 and the current Native target 4/4 with one
ignored recorder, all exit 0. The first local filter attempts in `82` and `83`
truthfully failed the compiled-view/source guard: a preceding standalone c6
build in the stable shared target was newer than unchanged e4 mirror inputs.
Refreshing only the two unchanged generated mirror file timestamps forced the
correct dependency rebuild; their whole SHA values did not change. No cache
replacement, global clean, source-proof waiver or device execution was used.
CI for the normal follow-up head remains pending.

The final `consumer-checks-86.json` records the original c6 Native nine-plan,
five-success whole-frame replay (1/1), affected Hoststore/Agentd all-target
clippy, the signed isolated Native CLI owner replay (1/1), and formatting,
all exit 0. `router-close-85.json` records the 28 closed-view, 12 execution and
10 historical baseline guards, all exit 0. `light-checks-89.json` records SDD
and diff checks, both exit 0. The unavailable `sh` launch in `87` and the
missing `dirname` child PATH failure in `88` are retained separately; explicit
Git shell paths and their normal child PATH produced the successful `89`.
No dependency installation, installed Runtime, account store, Harmony SDK,
transport or device was used by these checks.

The last macOS parity job `112716400837` completed with failure at
2026-10-07T09:25:58Z. Its whole original log is retained as
`ci-job-112716400837-79.stdout.log`, SHA256
`8545ef662b90b05da05ba5a62138d2a72b554a3a43ef840a536eeb8e0ebfeb27`.
`parity-all-three-census-90.json` binds the complete Linux, Windows and macOS
logs and their exact failure locations. The candidate parity path directly
ran CLI tests and bypassed the reviewed three-function service routes; it now
uses the fixed `--parity-consumers` router scope for Contract/CLI integrations.
All same-name workspace siblings, feature unification and normal workspace
library, binary, documentation and example defaults remain. Each actual
consumer receipt must prove its complete selected-case census, and a malformed,
missing, duplicate or failed receipt leaves provenance incomplete.
`parity-scope-91.json` records the two new scope guards, exit 0; Root's
`root-candidate-routing-91` and `root-candidate-consumers-92` record three
receipt guards and two affected actual-Git-input consumers, all exit 0.

That macOS log additionally exposed the original Native reconcile fixture's
parked-state expectation. Its 22 literal requests, seven snapshot boundaries
and 88 original provenance files remain immutable. Current c6 owners refuse
before mutation when the required job-local observation is missing, rather
than creating the old unknown publish. A separately recorded diagnostic
consumer must preserve all original requests and full outputs; it must not
invent missing observation, replay an unknown intent, or force the third
fresh request to become terminal. The current e4 full Native positive and
verified rollback software proofs remain mandatory. This last bounded
consumer uses `device-mutation-reconcile-native-published-c6-v4`, recorded
CREATE_NEW by genuine current owners in the pinned c6 input view. Its two
exercised Jobs fail known and finalize diagnostic Sessions without transport
or consumption; the third accepted submission keeps its actual `preflight`
state. The original fixed capability lookup remains a complete `notFound`
answer in the recorded Windows host, with its exact original request intact.
Cross-host comparison proves the matching-policy success branch independently
from the full production-encoder plan and policy material; it never converts
a refused Runtime response into success.

`native-reconcile-record-106.json` records the successful explicit software
recorder, exit 0, 38.082 seconds, with the source snapshot unchanged. Its
32-file output contains all 22 answers, seven snapshots, raw and canonical
whole owner documents and a provenance record pinning all 31 data files.
The original 88 source files remain unchanged. The new snapshot separately
verifies the exact 588-byte sealed input and its whole SHA; it retains the
Windows read/write-probe refusal as raw evidence and derives only the exact
sealed permission role. No original fixture or copied-input ACL is changed.

The first filter in `94` executed zero tests and is not counted as coverage.
The corrected encoder case passed in `95`; its complete policy companion
passed in `97` (the same test case, not an additional distinct test). Recorder
compile failures `96` and `101`, schema/encoding failures `98` and `99`, and
the permission-representation refusal `102` are retained. The incomplete
v1/v2/v3 output directories were retained outside the repository fixture tree
with whole-byte equality receipts `100` and `103`; no original file was
overwritten. The normal replay `108` passed its complete answer/store case
but the negative fixture failed while creating a hard link after sealing on
Windows (PermissionDenied). Its original log remains; this is not counted
as a passing negative test. A corrected task-private linked specimen must
exercise the verifier before the final negative result is reported.

The corrected negative in `native-reconcile-final-109.json` passed 1/1,
exit 0, 36.929 seconds. It retains every full-plan, policy, root, seal, index,
aggregate, tree and whole-answer refusal. Its actual task-private permission
checks observe writable payload rejection, sealed payload verification and
multiply linked payload rejection; the linked specimen is created while
writable. The previously passed complete replay is retained rather than
repeated. Clippy's three byte-array spelling errors in `109` are preserved;
the equivalent newline byte-string literals change no encoded bytes.
`final-lint-111.json` records affected Hoststore/Agentd all-target clippy exit 0
and formatting exit 0. The official `fmt --all --check` hit Windows command
length error 206; `workspace-format-113.json` exhaustively checks all 13 exact
workspace members individually, every exit 0. No formatting assertion is
waived.

Health's independent whole-file readback is
`native-reconcile-v4-independent-readback-2.json`, SHA256
`60ed82f5014438600f2b321ba7834c93fc2a29261c3205c6a6244864ec0c419c`.
It validates every new data pin, original source pin, raw answer/snapshot,
complete owner tree and both diagnostic Session closures. Source review also
validated the exact root relation, full encoder/policy capsules, fixed-ID
lookup branch and sealed-input proof. These checks are software regressions;
they do not grant new authority or constitute a device result. The exact new
head's selected CI remains pending publication.


### Audited ignored-target execution receipts

Local targeted checks: `ignored-bookkeeping-final-126.json` records 47 focused
pure parser/runner guards, exit 0, and rechecks all five actual ignored-only
macOS receipts from the failed job artifact. Each remains zero passed,
`completed: false` and `coverage: false`; global workspace completion can
observe this expected exclusion without claiming substantive coverage. The
new verifier requires the exact audited nonempty names, full real libtest
summary, full-listed minus selected filtered count, and bound Cargo execution.
Missing, duplicate, unknown, malformed, ordinary-case, wrong-count and failed
Cargo results refuse. The original substantive `verify_execution` predicate,
all declared ignores, assertions, Catalog routes and fixtures are unchanged.
The initial new fixture truncated its summary (`124`, 45 pass/1 fail); that
log remains, and only the synthetic fixture was corrected to actual libtest
shape. `125` records the intermediate 46-case pass before final summary and
filter-count tightening; the final result is `126`. No Cargo, Runtime, account,
SDK or transport checks were repeated for this Python bookkeeping correction.

CI: PR #2628 head `1ffd9709a5e086cf15a1a527a6c7d384ea2aff09`, run
`37613667412`, macOS workspace job `112767208199` failed after all substantive
libtest cases passed because five existing ignored-only targets were treated
as missing coverage. Whole log `ci-job-112767208199-122.stdout.log` has SHA256
`515cd2af6d53839df6759acc32320ec3c1f12d23c34923fa0551f12f37ff8b75`.
The original execution receipt is retained in artifact `11479034644`, whole
ZIP SHA256 `957d33867d2ff349408e6b4102078827938868e3fe2157f6ed16f8a227bd608c`;
its five expected exclusions remain explicit. Windows workspace job
`112767208342` also has no failed assertion and reports its existing quiet-host
measurement ignored, before the same runner exit. Its full log is retained in
`ci-job-112767208342-127.stdout.log`. macOS parity job `112767208283` separately
has two Native c6 full-output comparison failures at the same assertion;
`ci-job-112767208283-127.stdout.log` preserves both. Those are distinct from
this bookkeeping fix and require exact output diagnosis. A new follow-up's
CI remains pending; no earlier failed job is relabelled passed.


### Current Native synthetic host-file permissions

Local targeted checks: `native-mode-final-133.json` records the affected
Hoststore/Agentd formatting, the isolated pinned-c6
`native_reconcile_current_oracle` target (2 passed, 0 failed, 1 explicitly
ignored recorder), affected all-target clippy with `-D warnings`, and affected
format checks; every command exits 0. The complete 22-answer/seven-snapshot
replay and expanded failure guards pass in 46.578 seconds (test body 2.63
seconds); clippy takes 42.935 seconds. The test child has all live and recording
opt-ins removed and reuses the existing fixed Cargo target. Both original and
v4 whole-file inventories are unchanged. The formatter's final helper SHA256
is `de5fe77951e6c5c85076ec253a1d702bf0b8901fefecf400e42f36ea6cddd2aa`.
`lower-mode-manifest-refresh-134.json` proves only that helper's source pin
changes; all 333 targets, routing, other source pins and 6,499 fixture pins
remain equal. No fixture is re-recorded and no live operation is executed.

CI: the two failed Native comparisons in macOS parity job `112767208283`
have exactly 24 scalar differences: three newly created fake host files in
each of seven snapshots and the final tree. macOS default creation produces
mode 644, while the Windows task-private files have mode 600; every other
complete value is equal. The current-only replay now initializes exactly
`hdc-answers.sh`, the empty `hdc-invocations.log`, and CREATE_NEW `hdc-mode`
with owner mode 600 before requests. All comparisons still require actual
mode 600 and exact original script/empty-log/normal-mode bytes. Three wrong
mode and three byte-tamper cases with matching raw hashes refuse. Shared
legacy creators, production permissions and all stored fixtures stay intact.
Root and Health independently reviewed this source scope CLEAN. The original
macOS failures remain preserved in `ci-job-112767208283-127.stdout.log` and
artifact `11479669711`; they are software portability defects, not device
results. Windows parity job `112767208302` finished in 38m56s, within its
40-minute limit, with no failed test assertion and the observed ignored-only
cost target followed by receipt exit 1. Its complete log is
`ci-job-112767208302-132.stdout.log`; without its uploaded receipt, no whole
Windows error census is claimed. The next exact follow-up head's CI is pending
publication. Earlier failed heads are not relabelled passed.

### Serial Catalog Cargo target commands

Local targeted checks: `catalog-scheduler-143-pure.json` records 18 passing
scheduler and execution-receipt tests, and
`catalog-scheduler-143-receipt-guards.json` records 31 passing view guards;
both commands exit 0. The two new scheduler cases request two workers with
both audited CLI and shared daemon targets. They require one active Cargo
command, exact list/ignored/selected/Running receipts, and every later target
plus library/bin, documentation and example stages after a failed first
target. The receipt reports effective `workers: 1` and the original
`requestedWorkers`. `catalog-scheduler-143-legacy.json` records five passing
unchanged legacy scheduler cases, including the real dependency-free Cargo
fixture that requires its two audited queues to overlap and preserves queue
and documentation failures. It exits 0 in 3.888 seconds. Initial fixture
receipt `catalog-scheduler-142-pure.json` retains two failed subcases caused
by expecting ignored names where the existing verified receipt stores the
ignored count; only the new expectation was corrected. No product Rust,
Runtime, account, SDK, signing or device checks were run for this change.
Catalog selectors, authority, test assertions and every fixture byte remain
unchanged. Only Catalog per-target Cargo scheduling is serial;
legacy `execute()` and its audited overlap list are unchanged.

CI: PR #2628 exact head `2c469af9fe58389b4737665e3d557d1618992812`,
run `37625508614`, has two actual macOS failures. Workspace job
`112806652137` fails
`artifact_retention_process::lapsed_artifacts_are_reclaimed_once_before_the_daemon_serves`
at line 126, spawning the Cargo daemon binary with OS error 2; its other
case passes. Parity job `112806652309` fails
`domain_leaves::a_capture_preset_submits_swifts_preset_inputs` at line 333,
spawning the Cargo CLI binary with the same error; its other eight cases
pass. The complete logs are
`lower-2c-ci-008-job-112806652137-full-log.stdout.log` and
`lower-2c-ci-011-job-112806652309-full-log.stdout.log`, respectively. Public
artifacts `11483919885` and `11484454254` retain complete receipts: exactly
one target error in each failed view, and the parity historical view is
complete with no errors. The overlapping commands are the daemon retention
execution with the workspace checkpoint ignored-list command, and the CLI
domain execution with the agent resume ignored-list command.
`tool-select-cargo-uplift-causal-readback-1.json` binds the two complete logs
to official Cargo 1.99.0 source commit
`5f94df4789f005f9a352888e8355ffc645b7ed0e`: fresh and compiled outputs both
refresh sibling binaries, and macOS removes then copies a different-inode
destination. A concurrent Cargo call can therefore remove an un-hashed
binary while another test spawns it. No syscall trace was retained; this
source and timing diagnosis is not a claim of an observed unlink event or
an invalid run under the four load criteria. There is no retry, added sleep,
assertion relaxation or binary-path workaround. Windows workspace and both
Ubuntu lanes pass on this head. Windows parity also passes in 38m03s, within
its 40-minute limit. The required `guard` checks pass and `swift` aggregate
job `112823729149` fails. Complete final receipt `lower-2c-ci-final.json`
preserves that terminal result. The next follow-up's CI remains pending; these failures stay
preserved and are not relabelled passed.

### ArkForge lane refusal diagnostics

Local targeted checks: `arkforge-lane-diagnostic-146.json` records affected
formatting, `test --offline -p arkdeck-provider-arkforge --test lane`,
`clippy --offline -p arkdeck-provider-arkforge -p arkdeck-agentd --all-targets
-- -D warnings`, and affected format checking through the official runner.
Every command exits 0 in the existing `signing-readiness` cache. The actual
Windows custom harness has seven cases, all passing; macOS has eight cases
and was not executed locally. Clippy passes in 26.671 seconds. Initial
`145` stopped before Cargo because the sandbox token differs from the
repository owner; it remains preserved. The approved original-owner `146`
executes the same offline commands, with live and recording opt-ins removed.
Initial SDD wrapper `144` lacked Git's `dirname` executable on PATH and is
retained separately; the final light check supplies the existing Git tool
PATH. `catalog-followup-light-148.json` records SDD and diff exit 0 plus
successful Python AST parsing. This is not a product or test assertion failure.
`lower-lane-manifest-refresh-147.json` proves complete generated JSON equality
and exactly one lane source-pin replacement, preserving every other byte,
order, route, 333-target census and 6,499 fixture pins. Existing exhaustive
format results remain applicable to all unchanged Rust files; only the
affected provider was formatted and checked again.

CI: upper PR #2629 head `671d9db4db0206f5173e83409dbbe5dba4a75010`,
run `37625593393`, macOS parity job `112806914925` has one historical-view
failure: `arkdeck-provider-arkforge/lane::a_daemon_that_is_not_ready_is_stopped_and_refused`.
The second `replay` scene fails its expected refusal prefix at line 621;
the other seven cases pass and every other historical receipt stage exits 0.
Its actual refusal detail was not printed and cannot be recovered from that
log. The minimal test-only change binds that existing detail once and prints
it on the same exact prefix assertion. The expected string, stop/ended and
public-endpoint checks remain unchanged. No AMFI, copy, permission, product,
protocol, timeout or replay behavior changes. The complete log and receipt
are `import-ci-macos-parity-37625593393-*.log` and the preserved historical
execution receipt, with whole SHA256
`716e0039004b6b378cb4d17dfb3a751c9301d538cc35d151a67410137a9db6ef`
and `99c183e7ad34a4942dad53c7630179d6a06ce2ef0315e6758dce706e64de90f6`,
respectively. Its cause remains undiagnosed until actual macOS evidence
reports that detail; it is not classified as the two lower spawn failures or
an invalid run. The next CI remains pending.


## Windows contract parity whole-job allowance follow-up

CI: PR #2628 head89c4fd42d226e740923d3c6a84cf461802fc492e, run37639394314,
Windows parity job112854680059, is cancelled. Its only failure annotation is
`The job has exceeded the maximum execution time of 40m0s`. Every actual
contract check completed successfully at15:26:46 UTC (39m47s after job start),
and the complete31,819,477-byte artifact11492399713 uploaded at15:26:55.
The candidate receipt71 targets/186 stages and historical203/561 are both
completed:true, with every stage exit0 and zero target errors. The final
required swift aggregate is genuinely failed; completed test receipts do not
override a cancelled CI job. All other selected lanes and guard succeeded.

Upper PR #2629 headd002ee2545a68484f3a0d11e4c76f1e5a72f9bb6,
run37639573364, Windows parity112855410962 has the same40m0s annotation.
The candidate receipt is complete; historical execution was interrupted
during the default Hoststore unit tests. Its last logged case passed, but
the next running case is unknown and there is no complete historical
receipt. This upper run is not counted as passed. Every other selected
lane succeeded, including the exact original Mac ArkForge8/8 cases.

The lower complete job log SHA256 is
`11a373e473faeee8cbb6edf10ffac4e812d92b8716f37dd2fe23f1d1dcb77ddb`;
complete Windows receipt proof is `lower-89c-windows-parity-critical-proof.json`,
SHA256 `907fc60eabcdc066477d76dab167d07ed528712891b53a4400fb76769113419f`.
Both original cancelled logs, annotation, artifacts and upper incomplete
execution remain retained. The phase comparison against successfulee0 shows
the same command/stage census,196 compilation lines, compile artifact
census, cache key and target namespaces; Windows already used one worker.
No duplicate-build defect or load/port invalid-run exception is proved.

Only the Windows contracts whole-job CI allowance changes40 to50 minutes.
macOS contracts stay50, Linux30 and Windows workspace40. All workflow
steps, isolated views, assertions, selected coverage, artifact upload,
failure aggregation and individual test/Runtime/operation/acceptance
budgets are unchanged. Full parsed workflow equality proves this sole
semantic delta. An incomplete or failed check still makes required swift red.

Local targeted checks: from scripts/ci,
`python -B -m unittest test_plan.PathClassificationTests.test_planner_and_workflow_changes_cannot_self_skip`
passes1/1, exit0. Full streams and command are retained in
`root-contract-allowance-targeted-20261007-1.*`; receipt SHA256
`fee9b03023903107049a9a0b276e3535e49d89ef05ffdd4482e344fb039d049d`.
YAML parsing and complete semantic readback pass; diff check exits0.
SDD is checked before the same-PR normal publication, with its full
command/exit/streams retained in the adjacent allowance light-check receipt.
No Rust/Catalog source changed, so no repeated Cargo build is required.
CI for the new head is pending; no Runtime or hardware acceptance is claimed.


### Job-specific workflow allowance contract alignment

The normal pushes at lower `4c9ec815ae070b318ab88fe7412800e38a0ff0a6` and upper `d164ff2d437a232a39cc1e82b1775912994e61ba` exposed an additional CI planner failure before any compiled lane ran. Lower Swift run37645884491/plan112876402150 and upper run37646552334/plan112878701472 both failed `scripts/test_agent_pr_workflow.py` with18 cases, one error and one failure. The workflow validator still required the old identical timeout token in both job blocks; its contract-only negative mutation consequently left the workflow unchanged. Complete original logs and the independent same-cause comparison receipt are retained. These runs are FAILED, not passes.

Move each exact allowance into the existing job-specific token set: workspace Windows40/macOS50/Linux30, contracts Windows50/macOS50/Linux30. Existing per-job and whole-workflow uniqueness checks remain unchanged. Seven negative mutations reject removal, independent drift and swapping of the two policies. Matrix, policy dependency, workers, cache discipline, compilation/test steps, Runtime deadlines, failure aggregation, operation semantics and acceptance requirements are unchanged. This CI-only test script has no exact source/fixture path binding in the Rust manifest, Catalog or contracts; no generated source pin is changed.

Local targeted checks: `python -X utf8 -B scripts/test_agent_pr_workflow.py` exited0, all18 tests passed (0.203s suite /0.394s process). Complete stdout/stderr and actual source SHA are recorded in `root-workflow-policy-alignment-targeted-20261007-2.json`. The first invocation without UTF8 mode failed while decoding an existing macOS workflow under Windows cp936; receipt1/full streams remain preserved as a failure. Explicit UTF8 matches the Linux CI encoding without an unrelated source edit. Changed Python AST parsing passed. SDD and diff results are in the separate lightweight receipt. No Cargo or local unified gate was repeated for this test-only alignment.

CI: new exact-head required checks remain pending until the ordinary stacked pushes finish. This correction does not infer maintainer adoption or any hardware acceptance.

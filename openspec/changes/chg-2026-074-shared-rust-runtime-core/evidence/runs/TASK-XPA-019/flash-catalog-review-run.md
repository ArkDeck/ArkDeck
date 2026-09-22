# TASK-XPA-019 — offline Flash review owned by Rust

Base: protected main `e5d8b69183f77820ce889fe51b459e931d78a16a` (#2119).
Branch: `agent/xpa-019-flash-review-projection`.

## Consumer contract

`ArkDeckCore.FlashReviewCatalogGenerated.json` is a generated Swift string, not a
Swift selection/hash implementation. It is emitted by
`cargo run --manifest-path rust/Cargo.toml -p arkdeck-hoststore --example flash_catalog_review`.
The output belongs at
`Packages/ArkDeckKit/Sources/ArkDeckCore/FlashReviewCatalogGenerated.swift`.
A Rust test parses the literal and compares it with the Runtime projection on every
macOS hoststore test run, so stale Catalog data cannot pass that lane.

The closed `arkdeck.catalog-review/1` document has `operation`, `providerId`,
`catalogDigest`, `selectionInputs`, `steps`, `stepSetDigestSHA256`,
`jobAdmitted: false`, and `dispatchDisposition: notDispatched`.
Each step has `stepId`, `kind`, `effect`, `cancellation`, `binding`, `optional`, and
`executionOwner: arkforgeLane | runtimeHost`. Ownership is the existing named Flash
lane disposition, not an inference from generic step kinds and not availability.
The fixed operation is `flash.full-restore@1`, provider `arkforge`, and selection
inputs are `verification: full`, as the existing App default request specifies.
The digest is the existing frozen Swift/bench correlation
`c1ab01f8c7c24649080d109c481f9c034ffb73edcc62033684ac8a59875e0b12`.

All modes and the no-target case consume the same static facts. The consumer assigns
planned/simulated/execution-locked presentation. No Runtime connection is required;
there is no offline behavior regression. A missing, undecodable or mismatched
projection is unavailable, never permission to synthesize steps or enable execution.
No target, Artifact, local state, Provider, capability or hardware is consulted.
No materialized plan digest or execution-availability claim is present.

`job.plan` now emits additive `stepSetDigestSHA256` from the same Runtime helper;
its step rows use the shared selector. The result schema permits this property
without requiring it from the still-published Swift daemon. The Rust CLI validates
it whenever present and still accepts the old Swift result. No durable record or
Runtime authority schema changes. If the field is present, the App verifies it against the reviewed projection; null
is not omission. For the still-published Swift response format, omission alone
provides no permission: the consumer may accept only a complete equivalent check
of Catalog, target/binding, Artifact and typed inputs, all ordered step fields
(including binding and optional), zero admission/dispatch and the materialized plan
digest. Submission still pins reviewedPlanDigest and Runtime owns admission. Pure
Rust execution tests and final acceptance must prove the new field exists and
matches; clients neither fabricate a Runtime digest nor infer authority from omission.
The existing 11 materialized operations acquire this provenance; Flash itself is
still unavailable until its actual lane materialization exists.

## Actual Flash dependency boundary

This audit accompanies the implementation, not a separate status PR.

| App dependency | Current Rust state | Remaining implementation |
| --- | --- | --- |
| operation.list, target.list | Real Control owners and closed App reads | Consume current wire fields |
| offline review | This generated projection, no Runtime dependency | B owns decoder/builder integration |
| operation.describe | Real Control owner; not an admitted App method | Closed App read if a consumer needs it; not required by offline review |
| artifact.import.begin/append/abort/commit | Real upload owner including flash-bundle kind | Bind App upload ownership and minimal typed ingress; preserve unknown commit outcome |
| flash.device-access, flash.bootloader-status | No real Control routes/owners | Trusted native USB observation, typed read projections; missing means unknown/unavailable |
| flash.prerequisites | No real owner | Target/revision/profile-bound preflight facts |
| flash.lanePlanPreview | No real owner | Pinned ArkForge Controller API, lane store and semantic plan observation |
| flash.bind-current-loader | No real owner | Runtime-owned fresh identity relationship, no caller proof |
| job.plan for flash.full-restore@1 | Not in MATERIALIZED; refuses before admission | Actual ArkForge lane materialization and complete plan, then source-bound digest comparison |
| job.submit/run/cancel for Flash | App gate recognizes exact `ArkDeckApp.FlashWorkspace`; backend Flash admission/execution unavailable | M4 authority, lane, durable recovery and execution; do not widen merely to get past the gate |
| job.show/timeline, artifact.list/read | Real shared reads | Existing consumption remains; successful read is not Flash execution evidence |

Implementation order after this consumer unblock remains M1 trusted USB and HDC
lifecycle/recovery plus signed independent IPC deployment, then the dependent Flash
observations, import ownership/preflight, ArkForge lane materialization/preview and
DEC-016 execution/recovery. Full M4 and Support Bundle are not concealed behind a
step-digest dependency. No destructive route is opened by this change.

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2`,
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`, and
`--manifest-path rust/Cargo.toml`. Results below include the exact failed attempts and their bounded follow-up.

- Projection/frozen digest and generated literal tests: 2 passed;
  `/private/tmp/arkdeck-flash-review-projection.log`.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak -p arkdeck-cli`:
  agentd + CLI completed (281 passed); the command then exited 101 on the existing
  capture-diagnostics whole-plan oracle, which lacked the new field. All existing
  fields matched. `/private/tmp/arkdeck-flash-review-tests.log`.
- Updated the legacy oracle comparison sites to validate and remove only the named
  additive field before strict old-field comparison. `cargo test -p arkdeck-hoststore
  --tests` completed 462 tests, 12 existing ignored, then hit a screen-sequence binary
  compiled before its same comparison update. Rebuilt and ran `--test screen_sequence_run
  --test target_adoption --test tool_list_native --test tool_macho
  --test tool_retirement_native --test workspace_mutation_oracle
  --test workspace_preset_transaction --test workspace_project`: exit 0,
  24 passed, 2 existing ignored. Combined hoststore coverage: 486 passed, 14 ignored;
  `/private/tmp/arkdeck-flash-review-hoststore-{final,remaining}.log`.
- `cargo test -p arkdeck-soak`: exit 0, 4 passed (harness tests, not soak acceptance);
  `/private/tmp/arkdeck-flash-review-soak-tests.log`.
- `cargo test -p arkdeck-contract -p arkdeck-control -p arkdeck-client`: exit 0,
  84 passed; `/private/tmp/arkdeck-flash-review-contract-tests.log`.
- All-target clippy with `-D warnings` for hoststore, agentd, soak, CLI, contract,
  control and client: exit 0. Hoststore clippy repeated after the test-only changes:
  exit 0; `/private/tmp/arkdeck-flash-review-clippy{,-final}.log`.
- Actual Rust daemon/CLI build: exit 0; `/private/tmp/arkdeck-flash-review-build.log`.
- `/private/tmp/arkdeck-validation-venv/bin/python rust/scripts/check-corpus-replay.py
  --fixture rust/tests/fixtures/observe-device
  --bin-dir /private/tmp/arkdeck-1330-rust-target/debug
  --record /private/tmp/arkdeck-flash-review-observe-pass.json`: exit 0,
  28 exchanges replayed, 0 skipped, 64 checks;
  `/private/tmp/arkdeck-flash-review-observe-pass.log`. Initial runs exposed the
  stale expectation that an unknown observation's `job.show` timeline stays
  byte-identical across restart. Existing `job_recovery.rs` appends its exact
  no-redispatch audit decision. The script now requires that one exact addition
  for unknown waiting observation Jobs, compares every other field unchanged,
  and additionally proves the fake HDC receives zero new calls across restart.
  Diagnostic failures remain in `/private/tmp/arkdeck-flash-review-observe{,-final}.log`.
- Generated Swift literal: `swiftc -typecheck` with a private module cache: exit 0;
  `/private/tmp/arkdeck-flash-review-swift.log`.
- Contract generator check, fmt and SDD: exit 0;
  `/private/tmp/arkdeck-flash-review-{contract,fmt,sdd}.log`.

The retained Swift Job-plan oracle checks the new analyzer step digest against an
exact fixed value and compares all existing fields unchanged. The live parity script
also expects that exact additive field instead of ignoring arbitrary extra output.
The initial implementation only syntax-checked the live Swift/Rust Job-plan
script. The previous statement that CI owned this lane was incorrect: no CI
workflow invokes it. The targeted live follow-up below supplies that evidence.
Full App behavior is B's consumer work; this change does not claim signed IPC,
physical-device acceptance, REAL_DEVICE_PASS or G5 completion.

## CI

The agent branch opens the implementation PR. CI and maintainer review remain
required; skipped lanes do not count as passes. No full unified gate runs locally.

### CI contract-view repair

CI run `35718238175` on `8b1d18957f7c5e4aba09a4479e1a84332047af7d`
failed: the published schema correctly rejected the additive plan field, while
both macOS contract views omitted the Swift generated projection required by
`include_str!`. The CLI and legacy oracle helper now assert the selected schema's
acceptance/rejection explicitly, validate the entire legacy projection, and
retain strict digest validation and all existing field comparisons. The view
materializer snapshots the current App projection together with the Rust source,
copies the same bytes into both views, records its SHA-256 in the summary and
rejects concurrent source changes. The Runtime/generated-literal equality test
remains active in both views; no schema, fixture or production guard was relaxed.

Local targeted checks for this repair (isolated target
`/private/tmp/arkdeck-2121-repair-target`, `CARGO_BUILD_JOBS=2`):

- `test_contract_checks.py`: exit 0, 42 tests; follow-up concurrent projection
  edit regression: exit 0, 1 test. Logs
  `/private/tmp/arkdeck-2121-view-python.log` and
  `/private/tmp/arkdeck-2121-view-drift.log`.
- Materialized actual published and candidate inputs with `check-contracts.py`'s
  materializer; ran only `arkdeck-cli --test job_plan`, `arkdeck-hoststore --lib
  catalog_review::tests` and `arkdeck-hoststore --test debug_hap_plan` in each view:
  exit 0, 18 total tests, no ignored tests. Logs
  `/private/tmp/arkdeck-2121-{published,candidate}-{cli,catalog,legacy}.log`.
- `cargo fmt --all --check` and `generate-contract.py --check`: exit 0;
  `/private/tmp/arkdeck-2121-repair-{fmt,contract}.log`.

CI: the failed run is not a pass. The repair requires a fresh PR-head run and
maintainer review. No full local unified lane or physical-device check was run.

- Repair targeted clippy (`hoststore --lib --test debug_hap_plan`, CLI
  `--test job_plan`, both `-D warnings`) and SDD: exit 0;
  `/private/tmp/arkdeck-2121-repair-clippy-{hoststore,cli}.log`,
  `/private/tmp/arkdeck-2121-repair-sdd.log`.


### Live Swift/Rust plan follow-up

Code under test: exact PR #2121 commit
`3a68678d1a702b2ee075054df23cf29cea58448b`, clean source worktree
`/private/tmp/arkdeck-2121-repair`. No product source changed for this follow-up.

Local targeted checks:

- Built `arkdeck-agentd` and `arkdeck-cli` with `CARGO_BUILD_JOBS=2` into a new,
  exclusive `/private/tmp/arkdeck-2121-live-target`: exit 0;
  `/private/tmp/arkdeck-2121-live-build-clean.log`.
- Reused Swift executable products from
  `/private/tmp/arkdeck-e190-swift/build/out/Products/Debug`, copied byte-for-byte
  with their runtime resource bundles to `/private/tmp/arkdeck-2121-swift-products`.
  They were produced at 2026-09-22 19:15:57 / 19:16:03 +08:00; the App task's
  existing `/private/tmp/arkdeck-e190-flash-final-tests.log` records their product
  builds. No new Swift build ran. The reused products do not carry an embedded
  source commit, so the current App worktree SHA is not asserted as their binary
  provenance. Exact source paths, sizes, timestamps and hashes are retained in
  `flash-live-swift-products.json`; authenticated CLI connections also verify the
  current control contract identity against the running daemons.
- `python3 rust/scripts/check-job-plan.py --bin-dir
  /private/tmp/arkdeck-2121-live-target/debug --swift-bin-dir
  /private/tmp/arkdeck-2121-swift-products --record
  /private/tmp/arkdeck-2121-live-plan-clean.json`: exit 0; 67 requests, 67 compared
  answers, 4 planned answers, 141 checks. Raw summary:
  `flash-live-plan-result.json`; log `/private/tmp/arkdeck-2121-live-plan-clean.log`.
  Rust planning wrote no new Artifact entries. Swift created its existing
  `job-oracle-absent` entry. The analyzer was `/usr/bin/true`, never dispatched;
  device dispatch count was zero. Each daemon ran sequentially over fresh
  copies at the same disposable path with an isolated home, never installed
  Runtime state or a real device.
- The first run used a target previously shared with temporary contract views
  and failed with Rust `job.plan` response `internalError` (exit 1);
  `/private/tmp/arkdeck-2121-live-plan.log`. It is not a pass or valid exact-source
  artifact. The fresh target run above passed with unchanged source, establishing
  the usable binary evidence without weakening validation. Contract-view
  rechecks now use a different target for each view as well.

CI: this live script is a local targeted check, not a hidden/skipped CI lane.
The PR still requires current-head CI and maintainer review. This follow-up is
host parity evidence, not pure Rust hardware acceptance or G5 completion.

- Follow-up view checks: exit 0, the same 18 tests, with separate
  `/private/tmp/arkdeck-2121-published-target` and
  `/private/tmp/arkdeck-2121-candidate-target`. Logs
  `/private/tmp/arkdeck-2121-{published,candidate}-{catalog,legacy,cli}-isolated.log`;
  orchestration `/private/tmp/arkdeck-2121-isolated-views.log`. These independent
  build artifacts supersede the earlier shared-target view run as reproducible
  view evidence. SDD exit 0: `/private/tmp/arkdeck-2121-live-sdd.log`.

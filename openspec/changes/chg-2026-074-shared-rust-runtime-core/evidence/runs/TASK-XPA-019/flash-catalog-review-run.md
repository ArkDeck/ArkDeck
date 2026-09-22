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
Runtime authority schema changes. The App's executing path must require the field
and verify it against the reviewed projection; absence does not authorize execution.
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
The live Swift/Rust Job-plan parity script was syntax-checked but not executed locally
because this worktree has no built Swift daemon/CLI products; CI owns that lane.
Full App behavior is B's consumer work; this change does not claim signed IPC,
physical-device acceptance, REAL_DEVICE_PASS or G5 completion.

## CI

The agent branch opens the implementation PR. CI and maintainer review remain
required; skipped lanes do not count as passes. No full unified gate runs locally.

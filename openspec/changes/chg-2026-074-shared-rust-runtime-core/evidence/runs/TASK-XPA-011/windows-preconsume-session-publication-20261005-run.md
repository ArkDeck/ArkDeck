# Windows pre-consume failure Session publication — 2026-10-05

An actual Windows `debug.hap@1` attempt failed before its first mutation with
confirmed read-only target/model/firmware preflight, no consumed admission audit,
known outcome and zero residue. Session composition rejected the absent admission
before appending `finalized`. The strict all-Job import-reference census correctly
refused a later independent import inspection; no patch apply was dispatched.
This implementation repairs publication, not the census or the historical Job.
It does not establish hardware acceptance.

The already approved scope is CHG-2026-075's
[Session publication scope review](../../../../chg-2026-075-single-v1-contracts/evidence/runs/TASK-SVC-002/session-publication-scope-review.md)
lines 244–255, with the matching scoped spec delta: pre-consume failure or
cancellation may record `runtimeAuthority: null` only when original durable
sources prove no mutation/destructive intent or compensation; a durable
consumption always requires its complete actual audit. Maintainer approval of
PR #1772 preceded protected merge `f0670ba6bcae64c98efe6ed90e8bf0f3101e2cd6`.
No policy decision, capability, consumption tuple, timestamp or missing legacy
tool fact is manufactured.

The producer supports the current HAP's three exact succeeded read-only preflight
declarations, correlated original outcome timestamps and machine-readback
observation. Known failed/cancelled execute, zero residue, absent admission,
no recovery fields, no foreign/unknown/torn/outstanding Journal and current
Catalog/target/binding/tool facts are required. The existing capability owner
checkpoint and complete ledger are also decoded under their existing strict
lock: any use for this Job, any torn/corrupt/missing proof refuses. The owner's
valid checkpoint with no first-use ledger keeps its established meaning.
New native nonrepairing reads refuse kept hardlinks without changing names or
bytes; ordinary reader/recovery behavior is unchanged.

Typed `job.reconcile` can retry only the retained HAP's confirmed unbound
`sourceIntegrityFailed` marker, before proposal/seals/receipt/storage claims.
A retry lock spans fresh reread, submission fingerprint and DB/disk comparison,
original proof, publication and marker persistence. Concurrent/repeated reads
keep one receipt; restart does not republish. No provider dispatch or
admission/capability/outcome rewrite occurs. The full import census, mutation
trust gates and all existing non-null Manifest branches remain enforced.

## Local targeted checks

Checks run on the development Windows host with jobs=2, the task's persistent
isolated target `D:/cargo-target/windows-mutation-tool-identity`, and the existing
bounded heavy-check executor. Every command for this increment runs from the
sole active worktree `D:/src/ArkDeck-wt/rc-smoke-path`; the same-task cache is
not shared by another running worktree. Cargo recompiles the current inputs.
All execution fixtures use the in-process
OracleFake or test-owned host processes, never the installed account Runtime or
physical HDC/device. The real account Runtime was stopped for the check window.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test debug_hap_run`:
  exit 0, 12 passed; final frozen source log
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-hap-frozen.log` (43.9 s).
  New regressions cover new/retained failure publication, full-census refusal
  before finalization and clearance afterwards, zero dispatch/authority writes,
  concurrent/reopen single receipt, owner/observation/recovery drift, partial or
  failed preflight, mutation, foreign/torn Journal, pending/settled consumption,
  malformed/torn/missing capability proof and kept Job/checkpoint/ledger links.
- `python rust/scripts/test_manifest_preconsume.py`: exit 0, 3 passed (0.4 s),
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-schema-recheck.log`.
  The class is imported by the existing `test_contract_checks.py` CI harness;
  `python rust/scripts/test_contract_checks.py PreconsumeManifestSchemaTests`
  also passed all 3 (exit 0, 0.6 s),
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-schema-harness.log`.
  Rust's matching explicit-null reader regression passed in the full owner
  run. JSON Schema retains consumed audit and legacy tool branches, and refuses
  missing authority, mutating/compensation declarations and non-failure nulls.
- `python rust/scripts/generate-contract.py --check`: exit 0; Manifest is not
  an embedded Control baseline input, so no generator/baseline repin is needed.
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-generator-final.log` (0.8 s).
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0,
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-fmt-checked-final.log` (9.1 s).
- `cargo clippy --manifest-path rust/Cargo.toml -p <packages below> --all-targets -- -D warnings`:
  exit 0 for all eleven changed/direct-dependent packages,
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-clippy-frozen.log` (32.5 s).
  After the fixture-only corrections, the affected platform/workspace packages
  passed the same `--all-targets -- -D warnings` command again (exit 0, 6.5 s),
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-fixture-clippy-final.log`.
- `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0;
  the current CLI sibling was refreshed in the same isolated target,
  `D:/src/ArkDeck-wt/tools/logs/import-preconsume-cli-build-final.log` (13.5 s).
- `cargo test --manifest-path rust/Cargo.toml -p <packages below>` was split
  after native fixture failures. Final tested-target counts are below, combining
  complete crate runs with only their failed suites rerun after fixture fixes.
  No assertions or production trust rules changed; earlier failures are retained.

| Package | Passed | Failed | Ignored |
| --- | ---: | ---: | ---: |
| arkdeck-agentd | 183 | 0 | 3 |
| arkdeck-bootstrap | 13 | 0 | 0 |
| arkdeck-cli | 266 | 0 | 0 |
| arkdeck-client | 6 | 0 | 0 |
| arkdeck-hoststore | 546 | 0 | 7 |
| arkdeck-platform | 253 | 0 | 3 |
| arkdeck-provider-arkforge | 95 | 0 | 0 |
| arkdeck-provider-hdc | 201 | 0 | 0 |
| arkdeck-provider-workspace | 35 | 0 | 0 |
| arkdeck-rockchip-binding | 1 | 0 | 0 |
| arkdeck-soak | 5 | 0 | 1 |

The combined log `D:/src/ArkDeck-wt/tools/logs/import-preconsume-direct-tests.log`
exited 101 after four unchanged `windows::bootstrap_tree` native-path tests
(1119.8 s). They also fail in a sequential isolated five-test group under
`require_escalated` (four failed, one passed; 8.9 s), recorded in
`D:/src/ArkDeck-wt/tools/logs/import-preconsume-bootstrap-diagnostic.log`.
The continuation `D:/src/ArkDeck-wt/tools/logs/import-preconsume-remaining-tests.log`
exited 101 at one unchanged workspace signing-publication fixture (90.1 s);
that exact test also fails alone under `require_escalated` with verified 8.3
TEMP/TMP (2.1 s), in
`D:/src/ArkDeck-wt/tools/logs/import-preconsume-workspace-diagnostic.log`.
The later complete native run used `cargo test ... -p arkdeck-platform
-p arkdeck-provider-workspace --no-fail-fast` (exit 101, 59.5 s),
`D:/src/ArkDeck-wt/tools/logs/import-preconsume-native-complete-no-fail-fast.log`,
exposing the remaining verified-source, signing-flow and DevEco fixture groups.
Other intermediate failures remain in `import-preconsume-native-fixture-tests.log`,
`import-preconsume-platform-fixture-final.log`,
`import-preconsume-workspace-fixture-final.log` and
`import-preconsume-workspace-native-complete.log` under the same private log root.

Eight Windows fixture constructors now follow the existing private-create then
`host_resolved_path` recipe: platform bootstrap tree, daemon fingerprint,
DevEco files and verified source; workspace maintenance unit fixture, daemon
binding, file identity and signing flow. Resolving only the parent before
creation did not prove the newly created child's physical name under packaged
LocalAppData relocation. The DevEco scratch additionally uses the existing
hoststore DevEco test recipe: token Profile root, fresh private directory and
native resolution, so every ancestor satisfies the unchanged production guard.
Anonymous read-only native ACL inspection confirmed foreign write rights on two
physical LocalAppData ancestors; the Profile chain satisfies the guard. The
production refusal was correct, and no real ancestor permissions were changed.
No existing ACL, real installed material, production reader or negative
foreign-write assertion was changed. These were real fixture prerequisite
failures, resolved explicitly; they are not classified as load-invalid runs.

The complete native run passed all other groups; only the three remaining failed
suites were rerun after their final fixture changes:

- `cargo test ... -p arkdeck-platform --test windows_verified_source`:
  exit 0, 3 passed (0.7 s), `import-preconsume-verified-source-final.log`.
- `cargo test ... -p arkdeck-provider-workspace --test windows_signing_flow`:
  exit 0, 6 passed (3.6 s), `import-preconsume-signing-flow-final.log`.
- `cargo test ... -p arkdeck-platform --test windows_deveco_files`:
  exit 0, 3 passed / 1 existing live-installation probe ignored (0.9 s),
  `import-preconsume-deveco-fixture-final.log`.

Binding and soak completed separately with exit 0 (2.8 s),
`D:/src/ArkDeck-wt/tools/logs/import-preconsume-binding-soak-tests.log`.
The ignored tests retain their existing fixture-helper/platform/signing gates.
Skipped doc-tests were completed with `cargo test --manifest-path rust/Cargo.toml
-p <all eleven packages> --doc`: exit 0 (4.0 s),
`D:/src/ArkDeck-wt/tools/logs/import-preconsume-direct-doc-tests.log`.

`sh scripts/check-sdd.sh`: exit 0 (2.8 s),
`D:/src/ArkDeck-wt/tools/logs/import-preconsume-sdd-final.log`.
`git diff --check`: exit 0.

## CI

This increment has not been pushed; its required CI and maintainer review are
pending. The dependency PR #2595's exact head
`326e2bd50b6cc7739a31324aeeafbdea18a26a7c` passed guard run `37326251744`
and Swift aggregate run `37326251935` (all three platform workspace and contract
parity lanes green) and merged as
`404f1478ccd9e723e8f0a123413ae9f66fd378d8` at 15:03:03 UTC. Those results
do not validate this increment. macOS/Linux execution and the full published
parity lane remain CI work; no local unified lane was run.

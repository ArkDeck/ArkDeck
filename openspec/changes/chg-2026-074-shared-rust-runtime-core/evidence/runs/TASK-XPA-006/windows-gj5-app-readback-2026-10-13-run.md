# Windows GJ-5 and installed capture readback — 2026-10-13

This continues the [GJ-1/2/3 run](windows-gj123-2026-10-13-run.md) on the same
clean, signed development RC from protected main
`caec3e7f77a9bfd3c2f15e39e9716385987ae568` and Catalog
`e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7`.
The installed App, CLI and account daemon remain that RC's unchanged bytes.
This delivery records GJ-5, adds an opt-in installed-App readback test, and
fixes the Runtime Job snapshot contention that test exposed. The installed
Runtime remains the released image; the candidate fix is tested in isolated
host fixtures. Catalog, contract and authority policy are unchanged.

## Signing prerequisite

The existing SDK release credential was bound to the previous daemon image.
The operator explicitly authorized restoring signing, then explicitly
authorized regeneration of the SDK release profile and credential for
`com.example.waterflowdemo` with the same SDK keystore and tools.

An initial DevEco migration attempt was refused: the registered fixture's
build profile had an unsafe inherited DACL and, after an authorized private
copy, no signing fields. Neither refusal changed the credential. The private
copy and its directory were removed. Re-registering the original unavailable
credential was also refused with `resourceConflict` and `newDispatchCount: 0`.
All original CLI outputs remain local; no refusal was edited away or counted
as device evidence.

The published `runtime signing install-sdk-release` path then regenerated
the bundle-bound profile. The SDK keystore, Java and signer JAR were checked
against the existing receipt's hashes. `workspace preset register` preserved
the original template, toolchain tuple and timeout with the new credential;
`runtime service restart` made it active. The final signing status was
`ready: true`, credential reference count one, and all build/test/signing
presets active. No password was displayed and no signing store was edited directly.
Maintenance journals are under
`D:/temp/arkdeck-windows-acceptance-20261013/raw-preparation*`.

## GJ-5 result

The unchanged `python -m gj_record assemble` generated
[the GJ-5 record](../../../../../../docs/design/references/v1.6-goal/gj-headless-rerun-2026-10-13-windows-gj5.json)
with `REAL_DEVICE_PASS`, 210 holding criteria and no failing criterion.
The committed file is byte-identical to the generated record, SHA-256
`3d0f8c50b7fad0cb298e76074affb707438fb0b74d44ae4f3a7a39d8dd1b8248`.

- The probe installed through `debug.hap@1`. After the crash window,
  liveness was `UNHEALTHY` / `targetProcessNotRunning`, exactly one crash-index
  entry was added, and `analyzer.extract-crash-signature@1` answered with the
  exact source Artifact provenance.
- `workspace.prepare-isolated-copy@1` matched the original 21-file source
  revision `701c5bd956121cbd187195411f2f12ec6c3db362ff10851d29b1a33cd8531dae`.
  The fixed patch applied only to that copy's exact revision. Build, the
  registered test preset and signing all succeeded. Original project source
  files were not modified.
- The signed HAP was exported locally, imported for the original target,
  deployed, and verified by install readback against the signed Artifact hash.
  After the crash window liveness was `HEALTHY`; the crash-index count remained
  unchanged from the reproduction.
- The independent stale-revision request returned `admissionDenied` at
  `preAdmission`, naming `workspace.revisionConflict`, with zero new dispatch.
  Complete adjacent Job inventories had the same set of IDs.
- Every successful Job was terminal with `outcomeUnknown: false`, zero
  blockers and zero outstanding residue. Published Artifacts were read in
  full and checked against their byte counts and SHA-256 values.

The retained budget was two rounds, 2,400 seconds, 268,435,456 Artifact bytes,
six Runtime `deviceMutation` Jobs, the eight named operations in the task
inputs, and stop-on-repeated-failure/unknown/HAR/authorization rules. Actual
consumption was one repair round, approximately 262.2 seconds, 9,931,632
Artifact bytes and five `deviceMutation` Jobs (including isolated workspace
writes). The bounded run used only published typed CLI operations: no raw
device commands, App interaction or repository source writes during the loop.

Original captures and inputs remain outside Git at
`D:/temp/arkdeck-windows-acceptance-20261013/raw-gj5` and `inputs`;
the budget start is `gj5-budget-start.json` in that same run root. The GJ-5
steps ran from 07:49:05 to 07:53:27 UTC. Raw identifiers, source paths, log
contents and signing material are not published with this record.

## Installed App readback

**Not accepted as a complete App readback pass.** Diagnostics/Trace and Viewer
each passed their English and Chinese assertions in individual runs, but the
combined rerun reproduced intermittent History unavailability. The final
diagnostic run failed immediately on
`unavailable(internalError): the result does not conform to the current contract`.
These failures remain in the original logs; a successful retry is not treated
as proof that the installed Runtime is fixed.

`InstalledCaptureTests` is an explicit opt-in against the installed RC's
production transport. Its expected inventory comes from original CLI
`job.result` envelopes selected by `ARKDECK_RC_CAPTURE_RESULT` (GJ-2
Diagnostics/Trace) and `ARKDECK_RC_VIEWER_RESULT` (screenshot/component tree);
missing opt-in inputs produce a skip, never an acceptance pass. Both `en-US`
and `zh-Hans` read the exact existing records.

The test compares History's Job/Target/Catalog and every Artifact's name,
status and published digest. It opens Diagnostics, verifies the historical
context and absence of live capture controls, compares the HiLog preview's
prefix to the same Artifact read through the published CLI, then opens the
Trace and verifies the entire App cache file's byte count and SHA-256. It
compares complete Job sets before and after. No new operation is submitted;
HiLog contents are not written to test logs, and the test-owned Trace cache is
removed. This does not claim the deferred Windows Trace parser is available.

A separate published `capture.diagnostics@1` supplied the screenshot/tree
input on the same target binding: it succeeded with no unknown outcome,
blockers or outstanding residue. All seven published Artifacts were read
whole and hash-verified (482,822 bytes). This capture was outside the GJ-5
loop and its budget. Its raw journal remains under the run root's
`raw-app-viewer` directory.

The Viewer test checks History's exact PNG/tree digests and historical
Job/Target context, opens the native PNG decoder, requires verified screenshot
coordinates, compares the full tree's component count and selected root type,
and reads that node's raw JSON. The expected tree itself is fully read and
SHA-256 checked through the published CLI. Complete before/after Job sets
match, so opening the record does not recapture. The History search is local
to the page; the test does not save or alter the account's filter.

## Job snapshot contention fix

History and the global Job Inspector both request `job.list` at App startup.
The Runtime's shared snapshot store used a nonblocking native file lock, so
simultaneous calls through the same Job owner could refuse one another with
`resourceConflict`. The published Job read schemas accept `conflict`; the
response validator therefore replaced that refusal with `internalError`.
The page stayed unavailable even when the Inspector's independent read
succeeded. Extending UIA readiness did not resolve it.

Job list and timeline reads now share one in-process mutex before entering
their shared snapshot pager. The native file lock remains in force. A
different holder still refuses immediately, with the existing published
`conflict`, `preAdmission` and zero-dispatch details. No request is replayed,
no Job is submitted and no contract or validation requirement is relaxed.

The regression first failed against the unchanged implementation with
`resourceConflict: Snapshot storage is being updated`. Its fixed form checks
two concurrent lists and a timeline, complete page contents and exact current
schema conformance. A separate held-lock test checks that list and timeline
return the published refusal, leave snapshot files unchanged and allow a read
after release. Installed-App acceptance needs a reviewed, protected-main RC
containing this fix and a fresh four-case readback run.

## Local targeted checks

- GJ-5 typed CLI phases and full Artifact readbacks: exit 0. The intentional
  negative request exited 77 with the required zero-dispatch refusal.
- `python -m gj_record assemble --out <raw-gj5> --date 2026-10-13
  --runtime-source-revision caec3e7f77a9bfd3c2f15e39e9716385987ae568
  --record <gj5.json> --journey GJ-5`: exit 0, `REAL_DEVICE_PASS`.
- Installed capture UIA compiled and ran against the unchanged released RC.
  Diagnostics/Trace passed 2/2 in `uia-capture-final`, and Viewer passed 2/2 in
  `uia-viewer-controls`. Combined runs failed (3/4 in `uia-readback-final`,
  2/4 in `uia-readback-search`, 1/4 in `uia-readback-complete`); the final
  `uia-viewer-reason` run passed 1/2 and captured the contract error immediately.
  Each failed run exited 1. Logs and matching TRX directories retain these
  names under the run root. No combined acceptance pass is claimed.
- Before the Runtime fix, the new concurrent-read regression exited 101 with
  `resourceConflict` (`history-concurrency-red.log`). After the fix,
  `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --lib
  job_owner::list_stream_tests -- --nocapture` exited 0, all six tests passed
  (`history-focused-green.log`). These are isolated host fixtures, not hardware
  evidence.
- `python rust/scripts/run-cargo.py fmt --all --check` hit Windows error 206
  before checking source (`history-fmt-all-check.log`). The equivalent
  `rustfmt --check` ran over all 356 Cargo target roots, grouped by edition in
  bounded argument batches through the same runner: exit 0
  (`history-fmt-batched-check.log`). This compatibility workaround preserves
  the workspace and per-session target directory; it does not omit roots.
- `python rust/scripts/run-cargo.py clippy -p <crate> --all-targets -- -D
  warnings` exited 0 for `arkdeck-hoststore`, `arkdeck-agentd` and
  `arkdeck-soak`; logs are `history-clippy-<crate>.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore` passed 370
  library tests with four existing ignores, then exited 101 on the frozen
  `debug_hap_plan::native_swift_plans_match_with_nothing_admitted_or_dispatched`
  oracle's historical Catalog digest (`history-test-arkdeck-hoststore.log`).
  That exact test is already routed to the historical Catalog by CI's
  `catalog-test-views.json`. The direct package command does not apply that
  route; the oracle, assertions and routing are unchanged.
- `python rust/scripts/run-cargo.py test -p arkdeck-agentd` initially exited
  101 because the standalone package command had not built its sibling CLI;
  two account-level cases also encountered the correctly held guard of this
  run's installed Runtime (`history-test-arkdeck-agentd.log`). After
  `build -p arkdeck-cli` exited 0, the released Runtime was stopped through its
  published service command with no active Jobs. The prepared rerun passed
  all 53 `spawning` cases with three existing fixture-entry ignores, the
  43 library/main cases, account-location tests and analyzer tests. It then
  exited 101 at the existing `windows_artifact_owner_process` historical
  receipt verification: the frozen receipt names the old Catalog while this
  direct package invocation composes the current Catalog. CI already routes
  that exact case to the historical view. Logs are
  `history-build-cli-fixture.log` and `history-test-arkdeck-agentd-prepared.log`.
  A `finally` block restored the same signed released Runtime, verified its
  health and exact daemon path, and compared complete before/after account
  Job inventories; the set was unchanged. The six maintenance captures are
  retained in `raw-host-test-maintenance`.
- `python rust/scripts/run-cargo.py test -p arkdeck-soak`: exit 0, five tests
  passed with one existing recorded-run ignore (`history-test-arkdeck-soak.log`).
- The test-routing validator accepted the current Catalog, all 927 source
  pins, 6,499 unchanged fixture pins and 333 unchanged integration routes.
  Only the two edited Rust files' source hashes were mechanically refreshed
  with `catalog_test_views.source_inventory`.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings and 121 acceptance
  IDs; log `D:/src/ArkDeck-wt/tools/windows-history-sdd-host-20261013.log`.
  Git for Windows' `sh.exe` was invoked by its absolute path on the host after
  sandbox process initialization failed. `git diff --check`: exit 0. No full
  local unified gate was run; final dual-Catalog coverage belongs to PR CI.

## CI

The preceding acceptance PR [#2632](https://github.com/ArkDeck/ArkDeck/pull/2632)
has successful SDD Guard runs `38363323645` and `38363423709`. Swift CI run
`38363323705` passed its planner and skipped code lanes/aggregate for that
documentation-only diff. The maintainer merged it as protected-main
`69c6418e7`; its tree matches the former parent head
`e7e583dbb6ee2bfac67f3ec0145afc0053c69132`. This follow-up therefore starts
directly from that latest main. Its own CI and maintainer review are pending.

## Remaining acceptance

GJ-4 still needs the matched Windows ArkForge release and AF-W1 result. The
2026-10-13 read found zero Windows acceptance runs and no releases in ArkForge.
Trusted Windows ArkTrace distribution, signed higher-version MSIX/feed,
clean-host installation, production release signing, cross-account/elevation/
remote-host identity checks and human accessibility observations remain
separate prerequisites. No platform conformance, performance baseline,
maintainer approval or production release readiness is inferred from these
device and App observations. The Windows CLI/App feature census is unchanged.

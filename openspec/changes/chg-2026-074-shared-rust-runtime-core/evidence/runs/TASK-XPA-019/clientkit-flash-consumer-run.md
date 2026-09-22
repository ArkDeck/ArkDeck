# Flash consumer and archive presentation boundary

TASK-XPA-019 / CHG-2026-074. This slice does not complete Flash execution or G5.
Integration dependencies: Runtime projection `2ce4a9a76a284de1379381aacc626857592cc69d`,
followed by its contract-view fixes through `3a68678d1a702b2ee075054df23cf29cea58448b`
(PR #2121; no generated API/data change), and the exact App/UI changes from
`1d7a6d07fb4c6cf9f4bf56b66c464f5312ba46d6` (PR #2123). The latter changes are
applied locally for integration validation and remain in their independent PR.

## Production behavior

Flash workspace, details and activity views consume ArkDeckClientKit. The Flash
provider and RockUSB access advice use the existing authenticated ClientKit XPC
transport; there is no Swift Runtime forwarding path added here. Runtime owns
observations, target binding, prerequisites, Artifact import, materialization,
admission and execution. App production assembly resolves the moved factories.

The canonical host-only gzip/tar reader, archive introspector and profile value
implementation live in Core. Existing Swift Runtime consumers use that same
implementation, with their original DeviceProviderError adapter retained in
Workflows. USB probes, binding stores, Provider logic and RuntimeJobEngine remain
outside ClientKit. No Package dependency or Runtime authority is moved into App.

Offline, no-target and all-mode reviews consume Rust-generated
FlashReviewCatalogGenerated.json. The client validates its Catalog identity and
step vocabulary, then renders the selected steps and supplied step-set digest.
It does not select executable steps, copy lowering ownership sets, or compute a
Runtime digest. Local selected-archive validation remains untrusted input review.
The generated projection is not execution availability or admission.

Execute review uses current job.plan wire names and strictly decodes booleans,
integers, inputs and rows. Catalog/step-set/materialized digests, target revision,
Artifact lease, profile, effect, authorization policy and zero-admission facts
must match. All six step fields (including binding and optional) are required and
compared against the generated projection in order. The additive step-set digest
may be entirely absent in an older valid response; present null, wrong type,
malformed or mismatched values are rejected. The client does not infer Runtime
implementation from absence or synthesize a returned digest. Pure Rust acceptance
still requires the new field plus independent process/identity evidence.
Extra malformed rows or changed cancellation semantics fail closed.
Run consumes its local one-shot dispatch handle before awaiting the reply; an
unconfirmed response cannot cause the same Job to be run again. Current status
remains a separate read. Missing/malformed Bootloader observations stay unknown,
not an invented zero-device observation, and cannot trigger Loader binding.

## Local targeted checks

Intermediate Core/device-access checks: 58 tests executed, 2 existing external
archive tests skipped, 0 failures. Log:
`/private/tmp/arkdeck-e190-flash-device-client-tests.log`.

An intermediate App build found FlashPlanDetailsView still importing Workflows
instead of the new ClientKit display aliases. The consumer import is corrected;
log `/private/tmp/arkdeck-e190-flash-client-build.log` records the failed build.
The fixed-dependency run completed with exit 0: 63 tests executed, 2 existing
external real-archive tests skipped, 0 failures. Command:
`ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --jobs 2 --filter
'FlashApplicationFacadeContractTests|FlashRuntimePlanClientContractTests|RockchipBootloaderStatusContractTests|RockchipImageArchiveIntrospectionContractTests|RockchipDeviceAccessAdvisorContractTests'`.
Log: `/private/tmp/arkdeck-e190-flash-final-tests.log`.

Final App `build-for-testing` passed with exit 0 using
`ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2
sh scripts/ci/run-xcodebuild.sh`;
`/private/tmp/arkdeck-e190-flash-final-build.log` contains TEST BUILD SUCCEEDED.
After the final required-blocker-field check, only
`--filter FlashRuntimePlanClientContractTests` was rerun: exit 0, 10 passed;
`/private/tmp/arkdeck-e190-flash-plan-final-tests.log`.
The existing `ArchitectureBoundaryContractTests` source-path assertion now points
to ClientKit without weakening any rule: exit 0, 16 passed;
`/private/tmp/arkdeck-e190-flash-architecture-tests.log`.

Targeted UI validation passed, exit 0, 2 tests (both languages), using
`ARKDECK_UI_TEST_DERIVED_DATA=/private/tmp/arkdeck-e190-ui sh scripts/ci/run-ui-tests.sh`
with the two `AppShellUITests` selectors
`testFlashAvailabilityRefreshBlocksACachedPlanInBothLanguages` and
`testFlashDeviceAccessAbsentAndUnavailableInBothLanguages`.
Log: `/private/tmp/arkdeck-e190-flash-ui-final.log`.
This rebuilt the final App and runner, including the last ClientKit guard and
#2123's independent native-AX fix. The baseline AX crash and causal reproduction
are documented separately in `flash-accessibility-run.md` from #2123.
SDD check passed with exit 0,
`/private/tmp/arkdeck-e190-flash-sdd.log`.

No real archive, signed standalone Rust Mach, hardware or recovery acceptance
is claimed by these fixtures. The installed LaunchAgent has not been touched.
The signed IPC harness still requires an independent existing login/VM with the
fixed production Mach name free.

## Remaining Runtime integration

Rust's generated review projection only closes offline review and the shared
step-set digest contract. The actual five flash.* projections, Flash Artifact
import/ingress and flash.full-restore@1 materialization/ArkForge execution remain
Runtime-owner work. The exact method/field/client-identity list has been sent to
the Runtime owner and monitor; unsupported responses stay unavailable. Support
Bundle and Settings production assembly still retain Workflows dependencies.

## CI

Pending the consumer PR, required guard/swift checks and maintainer review.

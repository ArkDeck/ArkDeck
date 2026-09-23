# Settings storage response and App composition boundary

TASK-XPA-019 / CHG-2026-074 remain incomplete. This slice hardens the production
ClientKit storage reader and removes the Swift storage owner from the App's
explicit UI-automation composition. The support bundle still needs a Runtime
resource interface, so the App's Workflows product dependency is not removed here.

Base: protected main `544a86c236ed89a73ae4ba5c6ec2ed688d68a55f` (#2116), which
includes #2126 (`fe06d10c8`): the Rust App ingress admits `runtime.storage.policy`
and `runtime.storage.root`. Branch: `agent/task-xpa-019-settings-client`.

## Production behavior

`SettingsApplicationFacade` now requires an actual JSON `ok: true` and an actual
JSON boolean `measurementIncomplete` before publishing storage facts. The reader
previously never looked at `ok` and read the flag through NSNumber bridging, so an
`ok: false` envelope carrying a well-formed result, or a numeric flag, could be
shown as Runtime facts. Existing exact-shape, canonical decimal, usage and quota
validation remains; the App still repeats no Runtime path or quota admission.

Policy/root requests read the current generation, then send one mutation in the
closed shape #2126 admits: policy carries exactly `expectedGeneration`,
`totalQuotaBytes`, `safetyMarginBytes` and `retentionDays` as decimal strings;
root carries `expectedGeneration` plus either `rootPath` or `resetToDefault: true`.
`resourceConflict` reads the winning status back without repeating the mutation.
A lost reply or one the reader cannot account for leaves the outcome unknown, and
any other refusal is final: each is reported after exactly one send, never
retried, never read back and never shown as a success. Tests exercise all three
mutations through the production provider and record the actual method sequence
and typed request fields.

## UI-automation composition

The App now selects `SettingsStoragePresentationFixture` in ClientKit only for
`--ui-test-runtime-history`. It supplies in-memory response snapshots and echoes
closed UI request shapes; it does not create a storage root (selecting a root
creates no directory), measure usage, validate host paths, enforce quotas,
persist state or dispatch transport. It publishes 12 GiB / 3 GiB / 45 days, which
matches no Runtime default, and honors the History fixture's unreachable switch
at launch or through `--ui-test-fixture-state`. Ordinary launches still use
`RuntimeXPCRequestTransport`.

No App source references `SettingsStorageUIFixture` or a Swift storage owner type.
The Workflows composition entry `SettingsStorageUIFixture.runtimeStorage()` was
removed; the owner-backed fixture remains only for the contract tests that hold
the Swift daemon's storage replies to the ClientKit reader. `docs/ArchitectureRules.md`
records the new composition. The App still imports ArkDeckWorkflows for the
support-bundle exporter, the auto-update production assembly
(`AutoUpdateApplicationFacade.make()`) and the Flash workspace (#2124 pending).

## Local targeted checks

The Swift tests and the App build below ran twice with the same results: on
`fe06d10c8` and again after rebasing onto the base above. The mutation checks and
the UI test ran on `fe06d10c8`; the rebase changed no Settings, ClientKit or App
source.

- `ARKDECK_SWIFTPM_CACHE_ROOT=/private/tmp/arkdeck-e190-swift sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  'SettingsApplicationFacadeContractTests|SettingsStorageUIFixtureContractTests|SettingsStorageDomainContractTests|ArchitectureBoundaryContractTests'`:
  exit 0, 35 tests, 0 failures (ClientKit Settings 9; ArchitectureBoundary 16,
  Settings facade 3, storage domain 3, Swift owner fixture 4);
  `/private/tmp/arkdeck-e190-settings-s2-tests.log`.
- Mutation checks (ClientKit Settings class, each reverted by checksum):
  dropping the `ok` check and reading the flag through NSNumber failed
  `testInvalidSuccessAndMeasurementFlagsNeverPublishStorageFacts`; reconciling
  every mutation failure by reading back failed
  `testALostUnreadableOrRefusedStorageMutationIsSentOnceAndNeverRetried`
  (`/private/tmp/arkdeck-e190-settings-s2-mutation-ab.log`, exit 1); re-sending
  the mutation after `resourceConflict` failed
  `testAConflictedStorageMutationReadsBackWithoutRepeatingIt`
  (`/private/tmp/arkdeck-e190-settings-s2-mutation-c.log`, exit 1).
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2 sh
  scripts/ci/run-xcodebuild.sh` (ArkDeck scheme, Debug build-for-testing): exit 0,
  `** TEST BUILD SUCCEEDED **`; `/private/tmp/arkdeck-e190-settings-s2-app-build.log`.
- `ARKDECK_UI_TEST_DERIVED_DATA=/private/tmp/arkdeck-e190-ui sh
  scripts/ci/run-ui-tests.sh
  -only-testing:ArkDeckHDCUITests/AppShellUITests/testSettingsOfferRefreshWhileTheRuntimeIsUnreachableAndRecoverThroughIt`:
  exit 0, `** TEST SUCCEEDED **` (11.4 s); `/private/tmp/arkdeck-e190-settings-s2-ui.log`.
  The real App, launched with the fixture state file set to unreachable, kept
  Refresh on both panes, then recovered in place and showed the fixture's 12 GiB
  quota once the file was cleared. No invalid-run signal appeared, and the wrapper
  left `Package.resolved` unchanged.
- `ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python sh
  scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-e190-settings-s2-sdd.log`.
- Not run: the full AppShell sweep that also reads 12/3/45 on the Storage pane
  (one long session test; only the single Settings case above was selected).
  Rust and contract-generator checks were not required: no Rust or contract input
  changed.

## CI

Pending the agent-branch PR and current-head CI. Full unified checks run in CI;
pending/skipped jobs are not passes. Maintainer review remains required.

## Acceptance limits

The Rust task owns admission of the policy/root methods and owner-level
persistence checks (#2126). This App slice does not implement or bypass that
admission. UI fixtures and injected replies are presentation evidence only, not
independent Rust Mach IPC, signed deployment, hardware or recovery acceptance.
The fixed Mach service is still occupied by the installed Swift service, which
this task has not modified. Signed independent-environment acceptance remains
outstanding.

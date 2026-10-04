# macOS directory sources and serial native-library deployment

Date: 2026-10-04. Task: TASK-XPA-019. Host/fixture verification only.

Artifacts accepts multiple local files and 1–4 directory roots, including SMB shares already
mounted in Finder. Directory enumeration is read-only, skips hidden entries and symbolic links,
and refuses more than 500 entries or 100 libraries. The user selects individual results. WSL
build output uses the existing verified SSH/SFTP source; the App neither mounts SMB nor starts
a WSL process. Persistent directory bookmarks and an App-owned SMB connector are not claimed.

The queue accepts at most 16 distinct library names for one exact target/binding and bundle.
Every item is imported, validated and planned through the existing facade before review. The
review displays each library's digest and steps. Execution submits the existing
`deploy.native-library.app-owned@1` Jobs serially, preserving independent admission, backup,
Ability restart, readback and rollback. A failure, lost reply, wrong Job receipt or unknown
outcome stops subsequent submissions. Earlier successful items stay deployed; the batch is not
atomic. Changing the selection/context invalidates review; a submitted Job may finish and its
receipt remains visible, but no subsequent item starts. There is no automatic retry or resume.

This is App orchestration of an already published operation, not a new operation, Provider,
profile or destructive admission policy. No capability, trusted fact or device path is supplied
by the App. `.abc` replacement remains outside this implementation pending the user's requested
deployment semantics.

## Local targeted checks

Logs are under `/private/tmp/arkdeck-macos-closeout-20261004/`.

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter NativeLibraryDeploymentBatchTests`:
  exit 0, 8 tests; `deployment-batch-tests.log`. Covers serial execution, unknown/failed/wrong
  receipts, lost submission replies, stop during submission, late preparation after invalidation,
  duplicate destinations, symlink refusal and directory bounds.
- Combined batch/design synchronization filter: exit 0, 8 Swift Testing + 3 XCTest cases;
  `deployment-batch-tests-final.log`. Final synchronization-only recheck includes new queue
  identifiers and copy; `deployment-batch-design-sync-final.log`.
- `npm test` in `docs/design/arkdeck-ds`: exit 0, 83 cases;
  `deployment-batch-design-tests.log`.
- App scheme build-for-testing via `ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`:
  exit 0, `deployment-batch-app-build.log`; final context-invalidation edits also pass,
  `deployment-batch-app-final.log`.
- Rust formatting, `git diff --check`, and `sh scripts/check-sdd.sh`: exit 0;
  `deployment-batch-sdd.log` (0 errors/warnings).

UI automation is not claimed: the preceding Diagnostics run and its one permitted retry both
failed to enable automation mode before any assertion. No further identical bootstrap retry was
attempted. No real SMB/WSL connection, device deployment or Golden Journey was executed.

## CI

Pending initial push. Required `guard` and `swift` are recorded on the PR. No CI result is a
maintainer approval or physical-device acceptance.

## CI follow-up: shared localization companions

Local targeted checks: `python3 windows/scripts/generate-ui-strings.py --check`
exited 0 after copying the three changed existing deployment labels into
`spec/ui-semantics/strings.json` and regenerating both Windows `.resw` files.
The source and generated values now agree; no App behavior changed in this
follow-up. `git diff --check` exited 0. The already-passing App build and Swift
behavior tests were not repeated for this generated-resource correction.

CI: PR #2466, Swift CI run `37179304977` passed Swift tests, App build and design
interactions; the Windows lane failed its generated UI-string drift check for
these three labels before compiling. SDD Guard run `37179376168` passed. The
follow-up commit corrects that drift; its new CI result remains pending.

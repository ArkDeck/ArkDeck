# TASK-AIN-BKMK-001 fresh D1 readiness r2

Date: 2026-07-28

Classification: host-only readiness; no implementation, no product-key installation, no target
tool launch, and no device access.

## Approval input, base, and concurrency

- Route A governance PR #706 was authored by `github-actions[bot]`; `lvye` approved exact
  head `ef2382aef3346a4ec07656b8b3dbd6475174f7d8` at
  `2026-07-28T07:29:23Z` and merged it at `2026-07-28T07:30:10Z` as
  `14b46e3066c52f54568e97545c59b3506ffc62a4`.
- Final audit base and `origin/main` were both
  `c295d4a45a30ea08d7ab66440c5593d1208f222a`. During drafting, #707, #708, and
  #709 advanced main from the #706 merge; their seven changed files were confined to
  CHG-2026-042, CHG-2026-008, and CHG-2026-022 and had zero intersection with this carrier,
  the allowed implementation surface, and all pinned source blobs.
- The complete open-PR query at `2026-07-28T07:49:42Z` returned `[]`. Thus the
  implementation surface had no concurrent PR intersection at the final audit point.

## Controlled ordinary-bookmark/defaults-domain matrix

Host: macOS 26.5.2 (`25F84`), arm64, Apple Swift 6.3.3.

The checked-in probe source has SHA-256
`08135e76baff4485235dd50074a20bad3fa68e969dd6e3f012cd3af5f917909b`.
It was compiled twice as separate files whose basename was exactly `arkdeck`, then ad-hoc signed:

| build | binary SHA-256 | Identifier | CDHash |
| --- | --- | --- | --- |
| A | `26172684d636c9870a51ed0b8c9dd9dc0b62a46a2f327d4924779145fde180d0` | `dev.arkdeck.readiness.a` | `94d3566dcfcd45bcf4afcb2cf4af0aea223bb16b` |
| B | `293431069b06e8c2054e3f3cdedb218bc77c6c75e21c31b4ee076ced14125986` | `dev.arkdeck.readiness.b` | `235f395b1d6ef047c893948bbc3709b07ed21416` |

The target was read and hashed only. Its SHA-256 was
`038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`,
exactly the production pin. Build A created an ordinary bookmark and persisted it through
`UserDefaults.standard` under the thread-unique, non-product key
`ArkDeck.Readiness.AINBKMKR2.019fa76f3a467a729a092a58ef36c0dc`. Build B read the same
key and resolved the same bytes using `[.withoutUI]`.

Observed result:

```text
A: process=arkdeck bookmark_bytes=1060 stale=false target_match=true
B: process=arkdeck bookmark_bytes=1060 stale=false target_match=true
B remove: present=false
A status after removal: present=false
```

Thus the same `arkdeck` defaults domain and ordinary bookmark survived both an Identifier change
and a CDHash change. No bookmark bytes are recorded here. The first sandbox-isolated attempt used
`CFFIXED_USER_HOME`; `cfprefsd` did not persist its write to the next process and B reported
`missingBookmark`, so that attempt is not counted as positive evidence. The controlled retry used
the unique key in the real user preference domain, deleted it immediately, and verified absence
from both identities. Neither formal product key was read, written, or deleted.

## Source reachability and implementation seam

- Current production reachability is unique:
  `ArkDeckCLIMain.swift:116` constructs `RockchipFlashExecutionHost()`; Host line 671 calls
  `RockchipProductExecutionSettings.load()`; the production composition at Host line 1011
  injects `.pinnedProduction`. Source-wide search found no App reference.
- The public default `RockchipDeviceDiscoveryAdapter()` remains
  `.pinnedReadOnlyDiscovery`; the RockUSB E0 registry remains
  `userSelectedSecurityScopedBookmark`. Route A must therefore be selected only by the internal
  production composition, never by the public E0 default or `ArkDeckApp`.
- `ArkDeckCLIMain.runFlash` has a closed subcommand switch and existing option parser, so
  `install-tool --path` can be added without a new target or package dependency.
- `ArkDeckWorkflows` already depends on `ArkDeckProcess`, and
  `FoundationProcessExecutor.prepareIdentityBoundLaunch` is package-visible. It performs
  `lstat`, `O_EXEC|O_NOFOLLOW`, regular/executable checks, descriptor identity checks, and the
  exact SHA-256 comparison before returning a closable prepared token. The installer can call it
  and immediately close the token; it never calls the execute method and cannot spawn.
- `ArkDeckContractTests` already depends on `ArkDeckWorkflows`, so an internal
  preferences/bookmark-codec/verifier seam is testable through `@testable import` without editing
  `Package.swift` or `ArkDeckProcess`.

The implementation is pinned to these internal seams:

1. Add a public product installer facade in `RockchipFlashExecutionHost.swift`; its production
   entry uses `UserDefaults.standard`, the fixed production hash, Foundation ordinary-bookmark
   APIs, and the package-visible descriptor verifier. Internal initializers may inject only
   preferences, bookmark codec, and verifier for tests; no caller-facing launch or hash input.
2. Split the first settings prerequisite into an internal loader using the same preferences
   seam. It checks old-key presence before type conversion, rejects dual-key state, requires new
   Data, resolves ordinary/non-stale/canonical exact path, and constructs the typed selected tool.
   The production `load()` remains private to the production composition for all later D-1 gates.
3. Replace the discovery Bool with a closed access-policy enum and neutral `bookmarkData`.
   Read-only E0 keeps scoped resolve plus successful scope start; production uses ordinary resolve
   and never starts/stops security scope. Remove the production process port's retained scoped URL.
4. Widen only the 2.1 Rockchip path-source validator/schema enum to the two approved values. New
   production output is `installedOrdinaryBookmark`; historical scoped manifests remain accepted
   byte-for-byte; unknown values remain rejected.

## Pinned fault and compatibility matrix

The new `RockchipToolBookmarkContractTests` must use an isolated `UserDefaults` suite and injected
single-fault seams. Every loader failure observes zero spawn.

| area | required cases |
| --- | --- |
| loader | new-only valid; missing; wrong type; corrupt; stale; non-file/relative; canonical path mismatch; legacy-only; dual-key |
| installer input | relative/non-canonical; final symlink; symlinked parent; non-regular; non-executable; production-hash mismatch |
| installer faults | verifier throw; bookmark creation throw; self-resolve throw/stale/path mismatch; write throw; readback missing/wrong bytes; legacy-delete throw |
| crash recovery | injected legacy-delete failure leaves dual-key and loader blocks; rerunning the installer completes deletion and the loader succeeds |
| typed discovery | E0 requires scoped bytes and a successful scope start; production requires ordinary bytes, never starts scope, and both policies reject the other path source |
| persistence | new 2.1 output uses `installedOrdinaryBookmark`; historical scoped 2.1 input remains accepted without canonical rewrite; unknown/mixed values and bookmark/path fields are rejected |

The exact post-implementation product matrix is also mandatory:

1. Build `arkdeck` twice with separate SwiftPM scratch paths; copy each product as basename
   `arkdeck`; ad-hoc sign A/B with distinct explicit Identifiers and record both CDHashes.
2. Fail closed unless the formal old key, formal new key, and quarantine-presence key are absent.
3. A runs `arkdeck flash install-tool --path <pinned-tool>`.
4. B runs the authorized-execute CLI shape with a syntactically valid readiness authorization ID.
   It must pass the ordinary locator and stop exactly at the next missing quarantine prerequisite;
   this proves B's real production `load()` consumed A's installed first prerequisite while process
   spawn, USB, and device dispatch remain zero.
5. Focused discovery/composition tests pass the same typed ordinary selection through the
   product-composed adapter with an injected zero-spawn executor.
6. Delete the formal new key, verify it absent from A and B, and record no raw bookmark/path bytes.

If any formal-key precondition is not absent, or B does not reach the controlled next D-1 gate, the
matrix stops and the task does not become done.

## Baseline and exact implementation verification

Fresh-base results:

- `CI=true swift test --package-path Packages/ArkDeckKit`: 442 tests, 1 skipped,
  0 failures.
- `./scripts/check-sdd.sh`: 0 errors, 0 warnings, 111 acceptance IDs.
- `python3 scripts/test_check_pr_paths.py`: 49/49 passed.

Implementation must run:

```text
swift test --package-path Packages/ArkDeckKit --filter RockchipToolBookmarkContractTests
swift test --package-path Packages/ArkDeckKit --filter RockchipDeviceDiscoveryContractTests
swift test --package-path Packages/ArkDeckKit --filter RockchipProductionCompositionContractTests
swift test --package-path Packages/ArkDeckKit --filter RockchipFlashExecutionContractTests
swift test --package-path Packages/ArkDeckKit --filter RockchipFlashExecutionFaultContractTests
swift test --package-path Packages/ArkDeckKit --filter SessionArtifactStorageContractTests
swift test --package-path Packages/ArkDeckKit --filter RockchipRockUSBFlashProviderContractTests
CI=true swift test --package-path Packages/ArkDeckKit
./scripts/check-sdd.sh
python3 scripts/test_check_pr_paths.py
git diff --check
```

The implementation run record must include the implementation/base OIDs, changed-file blob OIDs,
each focused/full summary, A/B Identifier/CDHash and controlled next-gate result, migration and
schema matrix summaries, and explicit counters:
`rkdeveloptool_spawn=0`, `real_device=0`, `USB=0`, `E1=0`, `E2=0`,
`destructive=0`. It must not contain bookmark bytes, credentials, raw device identity, or claim
hardware validation.

## Readiness verdict

The protected-main governance dependency is merged; source reachability is closed to the CLI
production composition; the implementation and test seams fit entirely inside the approved paths;
the host primitive works across same-basename/different-Identifier/different-CDHash builds; and the
fault, product, schema, and full-suite matrices are exact. The task may become `ready` only when
the readiness PR containing this record is reviewed and merged by the maintainer. No implementation
may start before that merge.

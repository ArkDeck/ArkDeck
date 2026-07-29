# TASK-BRC-003 package/sign/notary run — 2026-07-29

- Evidence class: `platform`
- Core baseline: `CORE-2.1.0`
- Implementation base: readiness merge
  `2e1fe11e0c5860599bde03448a1f48d9ee596b80`
- Producer → consumer: accepted TASK-BRC-002R unsigned artifact handoff +
  reviewed package contract + maintainer-controlled Developer ID/notary
  environment → signed/notarized/stapled ArkDeck DMG package tuple
- Final verdict: `PASS`
- Task state boundary: Governance Enforcement 2.2.0 merged after r2 readiness
  and now requires implementation/test/docs/evidence/task status in one vertical
  PR. This PR therefore drafts TASK-BRC-003 `done`; it becomes effective only
  after maintainer exact-head review/merge and does not mark the change
  `verified`

## Scope and authority boundary

This run implemented and verified the exact TASK-BRC-003 surface:

- Xcode named Copy Files/Executables phase `Embed Rockchip Component` with Code
  Sign On Copy at `Contents/MacOS/rkdeveloptool`;
- named metadata phase at
  `Contents/Resources/RockchipComponent/1.0.0/`;
- exact App/child entitlement and release-signing configuration;
- repository-owned fail-closed package/notary tool and mutation matrix;
- machine-readable package contract, release documentation, sanitized notary
  log, and immutable package receipt.

It did not change the existing App entitlement file, accepted registry/recipe/
SBOM/notices/source manifest, Core/spec/contracts, CHG-2026-026, product runtime
composition, workflow, or update feed. It did not start TASK-BRC-004.

The only carrier addition beyond r2's historical implementation shape is the
current `tasks.md` status/completion record required by the subsequently merged
higher-level Governance Enforcement 2.2.0. Package tooling is contained by the
already declared and indexed `scripts/rockchip_component/**` boundary; no
scripts root index change remains. This does not alter the accepted package
scope, pins, risk, AC, or D2 window.

No App/component launch, install, release upload, HDC/USB/device access,
file-picker/bookmark action, E1/E2/deviceMutation/destructive dispatch, helper,
privilege, system-rule, group, or ACL mutation occurred.

## Fixed environment and input

The run revalidated the readiness environment before packaging:

| Field | Observed |
| --- | --- |
| host | macOS 26.6 (`25G72`), arm64 |
| Xcode | 26.6 (`17F113`) |
| `notarytool` | 1.1.2 (41) |
| Developer ID Application count | exactly one |
| certificate SHA-1 | `38E3B7650DF0CE1DEC0CC8C403614AA0C38B0B4C` |
| Team ID | `8AQTYW5FKR` |
| validity/chain | current and trusted |
| notary authentication | PASS through an opaque Keychain profile |

Credential/profile/account/private-key/password/token/path values were not
captured. An unrelated Apple Development identity present on the host was never
selected; all three final leaf certificate extracts matched the fixed Developer
ID SHA-1.

The only accepted unsigned artifact remained:

| Field | Value |
| --- | --- |
| workflow run / head | `30233237693` / `01e6f9a6605f4a3a9463dcab2bf5731bd012ef48` |
| artifact name / ID | `rockchip-builder-a` / `8640763234` |
| archive digest | `sha256:3dc014b6e81a68942d9415a1bdb73faabbbb2472297d1ae14d7648a547628e67` |
| expiry | `2026-08-26T02:53:55Z` |
| component size | 247,488 bytes |
| component SHA-256 | `3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a` |
| file / architecture | regular, no symlink, Mach-O 64-bit executable, arm64 only |
| minimum macOS | 14.0 |
| signature | absent, as required |
| dependency closure | exact seven Apple system `/usr/lib`/`/System/Library` entries |

`file`, `lipo`, `vtool -show-build`, `otool -L`, `codesign -dv`, size, SHA-256,
load-command digest, static version literals, and file identity were inspected
before archive/sign/notary. No rebuild, normalization, PATH, Homebrew, cache,
download fallback, alternate component, or caller-supplied environment was
accepted by the package tool.

## Package run

The accepted run used a fresh OS temporary root and this sanitized command
shape:

```text
python3 -B scripts/release/rockchip_component_package.py
  --component $TEMP/artifact/rkdeveloptool
  --notary-profile <opaque-keychain-profile>
  --output $TEMP/release-output
```

That accepted run occurred before the source-only final-path correction
described below. The package tool's bytes were moved without modification to
`scripts/rockchip_component/rockchip_component_package.py`; its final-path
contract suite was rerun after the move.

The tool used only absolute executable paths and argument arrays. Its fixed
order completed:

1. exact unsigned input inspection;
2. fresh copy and exact ad-hoc ingest signature;
3. Xcode arm64 Release archive with Code Sign On Copy;
4. independent child then App signature/requirement/entitlement/runtime/
   timestamp/Team/certificate/binary/metadata inspection;
5. fixed HFS+ UDZO two-entry DMG creation and Developer ID signing;
6. outermost DMG submission and sanitized Apple log retrieval;
7. staple and validation;
8. DMG Gatekeeper assessment;
9. read-only mount, contained App strict/deep signature verification and
   Gatekeeper assessment;
10. atomic tuple receipt validation.

Final tuple:

| Field | Value |
| --- | --- |
| App | `com.arkdeck.desktop` / `0.1.0` (`1`) |
| App tree SHA-256 | `638f97739bae8636e126bfd8e66a36139af8ff000fe06d88c25c852ca86673d3` |
| component identifier | `com.arkdeck.desktop.rkdeveloptool` |
| signed component SHA-256 | `9711271d3399b3915bf8ba5beb43ca5321e9eb880a47016d403f1ec358c820bc` |
| DMG | `ArkDeck-0.1.0-arm64.dmg`, 3,124,878 bytes |
| final stapled DMG SHA-256 | `934c768dd8e44e3e2b9478b10005a0d0002f67b818f8dd9e191dc4c9dc69aa76` |
| atomic tuple SHA-256 | `23a566bfcf6ad875475202d08dc7c61db630d04b7aaa6b89968283c678f28654` |

The Apple log records submission
`aacc4d5e-9aa2-40c7-b78b-4244d0afb720`, upload
`2026-07-29T04:24:30.365Z`, uploaded pre-staple archive SHA-256
`70e37a1e5a27d37ce7fdc5d1711e76d44ec32a13f7cacda29b413bd6bb55c966`,
status `Accepted`, status code `0`, and issue count `0`. The pre-staple notary
hash and final stapled DMG hash are intentionally distinct and are not
interchanged.

## Independent inspection

After the packager returned PASS, a separate read-only verification mounted the
DMG into another fresh temporary directory and did not trust receipt fields as
the sole evidence.

| Check | Independent result |
| --- | --- |
| `hdiutil verify` | valid checksum |
| DMG `codesign --verify --strict` | valid; satisfies designated requirement |
| DMG signature | Developer ID Application, Team `8AQTYW5FKR`, secure timestamp |
| DMG leaf SHA-1 | exact fixed certificate SHA-1 |
| `stapler validate` | PASS |
| DMG `spctl -a -t open` | accepted; `Notarized Developer ID` |
| DMG root entries | exactly `ArkDeck.app`, `THIRD-PARTY-NOTICES.txt` |
| App `codesign --verify --deep --strict` | valid; nested child prepared/validated |
| App `spctl -a -t exec` | accepted; `Notarized Developer ID` |
| App identifier/version/build | `com.arkdeck.desktop` / `0.1.0` / `1` |
| App architecture/minimum OS | arm64 only / 14.0 |
| App signature | same Developer ID leaf/Team, runtime flag, secure timestamp |
| App designated requirement | exact identifier + Apple generic anchor + leaf OU |
| App entitlements | exact existing six boolean-true keys |
| child location | `Contents/MacOS/rkdeveloptool` |
| child identifier | `com.arkdeck.desktop.rkdeveloptool` |
| child architecture/minimum OS | arm64 only / 14.0 |
| child signature | same Developer ID leaf/Team, runtime flag, secure timestamp |
| child designated requirement | exact identifier + Apple generic anchor + leaf OU |
| child entitlements | exact `app-sandbox=true`, `inherit=true` |
| child dependencies | exact seven system dependencies; no bundled/non-system dylib |
| executable inventory | only `Contents/MacOS/ArkDeck` and `Contents/MacOS/rkdeveloptool` |
| symlinks | 0 |
| metadata set | exact five files; no missing/extra file |
| metadata digests | exact package contract values |
| Apple raw/sanitized log projection | submission/status/hash/time/issue count equal |
| receipt validator | PASS; tuple digest and all fixed inputs exact |
| mounted App tree digest | exact receipt tree digest |

The five bundled metadata hashes were:

| File | SHA-256 |
| --- | --- |
| `registry.yaml` | `0649cb6f0974107e15cb39e75844532dc9dbaff33a7099d0a64cc7c248e07f54` |
| `recipe.json` | `8b42fdc29d26f597f4c40506f581fd06b5df1fdc1a9cc8eac225e706ce3998f6` |
| `sbom.spdx.json` | `05ae1fa74cbabe55dac1ff0bca59607b555b60fb2dbfc556e3af95671e3100ed` |
| `THIRD-PARTY-NOTICES.txt` | `33383934a0db7a5b833c280e0d2904405772f01cc16fea7bf26c18d84f038e2a` |
| `source-distribution-manifest.json` | `558282ba42f6dfdfd21599f5987206bb9f6370180b1653676f826559e61dc563` |

## Negative and repository verification

`scripts/rockchip_component/test_rockchip_component_package.py` completed
24/24 test methods and 85 explicit negative mutation subcases. The matrix
independently mutated:

- missing/wrong/non-regular/symlink input, size/hash/Mach-O/architecture/
  minimum-OS/load-command/dependency/version/signature facts;
- nested location/identifier/binary shape and extra/missing executable/dylib;
- missing/extra App and child entitlements, including Hardened Runtime
  exceptions;
- ad-hoc/development/mixed-Team/wrong-certificate/expired/untrusted/
  missing-timestamp/non-runtime signatures and designated requirements;
- App ID/version/build/architecture/minimum OS;
- missing/extra/drifted registry/recipe/SBOM/notices/source manifest;
- unsigned/malformed/wrong-layout/wrong-Team DMG;
- Rejected/Invalid/Unknown/missing/mismatched notary log;
- staple, DMG Gatekeeper, App Gatekeeper, and contained-App drift;
- self-reported/mixed App/component/source/SBOM/notices atomic tuples and
  non-zero forbidden effect counters.

Every mutation raised a fail-closed error before its next irreversible package
stage. Additional checks:

| Command | Result |
| --- | --- |
| `xcodebuild ... Release archive` through packager | PASS |
| no-sign, no-launch `xcodebuild -quiet ... Debug build` | PASS |
| `swift test --package-path Packages/ArkDeckKit` | 557 tests, 1 skipped, 0 failures |
| `python3 -B scripts/rockchip_component/test_rockchip_component_package.py` | 24/24 PASS |
| `python3 -B scripts/test_check_pr_paths.py` | 50/50 PASS |
| `<fixed-sdd-python> -B scripts/test_check_sdd.py` | 62/62 PASS; Python 3.14.6 / PyYAML 6.0.3 |
| `sh ./scripts/check-sdd.sh` | 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | PASS |

## Deviations and fail-closed development attempts

Three pre-acceptance package attempts and one Debug configuration regression
were not hidden or counted as PASS:

1. entitlement XML parsing initially included a trailing `codesign` diagnostic;
   parsing failed after only an ad-hoc staging signature. Archive/Developer ID/
   DMG/notary dispatch count was 0. The parser now bounds XML at `</plist>` and
   has a regression test.
2. the first leaf-certificate inspection used the wrong separated
   `--extract-certificates` syntax; it stopped after a fresh Xcode archive and
   before DMG/notary. The option now uses the required single
   `--extract-certificates=<prefix>` form and has a regression test.
3. submission `7d8d082d-a632-4fc3-91d6-32ddc1a3a10c` was uploaded by a later
   fresh attempt, but the local Keychain profile became unavailable while Apple
   still reported `In Progress`. `notarytool` exited 69; the candidate was
   deleted, no staple/Gatekeeper/receipt existed, and this submission is
   excluded from acceptance even though Apple later reported it `Accepted`.
   The maintainer restored the D2 Keychain configuration. The accepted run then
   started from a newly materialized artifact, created a new DMG, and used only
   submission `aacc4d5e-9aa2-40c7-b78b-4244d0afb720`.
4. after rebasing to the latest main, a fresh no-sign Debug build showed Xcode
   still processing the `/usr/bin/false` placeholder because the exclusion used
   the logical file-reference name instead of the actual basename. Debug
   `EXCLUDED_SOURCE_FILE_NAMES` now uses `false`; a second fresh DerivedData
   build completed without that processing, and independent inventory found
   only `Contents/MacOS/ArkDeck`. Release input injection and the accepted
   package tuple were unchanged.
5. the first bot-authored PR exact-path run rejected `scripts/README.md`
   because that index was not present in the protected-base task declaration.
   The package scripts were moved, without changing packager bytes, into the
   already declared and indexed `scripts/rockchip_component/**` boundary; the
   scripts root index change was removed. The final-path package suite and
   repository guards were then rerun.

The default PATH Python lacked the repository's pinned PyYAML module, so the
SDD contract suite did not start under that interpreter. It was rerun with the
existing fixed SDD interpreter after independently confirming Python 3.14.6
and PyYAML 6.0.3; no dependency was downloaded or changed.

No failed candidate was reused or overwritten. All temporary binary, App, DMG,
raw notary log, public certificate extracts, DerivedData, and artifact material
were removed after evidence capture. Binary/package artifacts are not present
in Git.

## Acceptance conclusion

- `BRC-PACKAGE-001`: **PASS for TASK-BRC-003** — fixed topology, exact
  entitlements, arm64/minimum OS, inside-out same-identity Developer ID
  signatures, Hardened Runtime/timestamps, metadata/atomic tuple, Accepted
  notarization, staple, and both Gatekeeper assessments have independent
  evidence.
- `AC-JOB-005-01`: **PASS for this task slice** — the package tool accepts one
  explicit component path, uses absolute executable paths/argument arrays, and
  has no shell/PATH/caller-environment or alternate-binary fallback. This does
  not claim successor runtime composition acceptance.
- `AC-UX-007-01`: **PASS for this task slice** — no elevation/install/helper/
  system-rule/group/ACL action; permission/sign/notary failures are explicit
  fail-closed results.
- `AC-FLASH-013-01`: **PASS only for the package handoff slice** — failures
  delete the candidate and retain no distributable tuple. No runtime reconnect,
  hardware, or device-recovery claim is made here.

Residual boundary: this run proves the TASK-BRC-003 package shape only. It does
not publish a release, prove clean-host install/update/rollback, make the child
reachable from production composition, execute the component, or prove E0/
hardware/runtime behavior. Those remain gated successor tasks.

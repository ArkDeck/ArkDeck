# TASK-BRC-001 decision run

## Identity

- Classification：`documentReview`
- proposedDisposition：`accept`
- Effective condition：maintainer `@lvye` APPROVES and merges this exact
  decision/evidence head
- Audit base：
  `e32cdaba9f465fc2e264f8b61ad135efab3487a8`
- Readiness PR / exact head / merge：
  `#537` /
  `34aa3d140e6e094d811550354a29df55a74215a1` /
  `e32cdaba9f465fc2e264f8b61ad135efab3487a8`
- Host：macOS 26.5.2 (`25F84`) arm64
- Xcode / SDK / compiler：
  Xcode 26.6 (`17F113`) /
  macOS SDK 26.5 (`25F70`) /
  Apple clang 21.0.0 (`clang-2100.1.1.101`)
- Source retrieval：`2026-07-25T08:32:59Z` through
  `2026-07-25T08:33:28Z`
- NVD response timestamp：`2026-07-25T08:37:16.053Z`
- Hardware：none
- Product/App/component/process/USB/device execution：none

## Preconditions and concurrency

`gh pr view 537 --json ...` returned maintainer `lvye` APPROVED on exact head
`34aa3d140e6e094d811550354a29df55a74215a1`, merged at
`2026-07-25T08:29:22Z` as
`e32cdaba9f465fc2e264f8b61ad135efab3487a8`.

`git merge-base --is-ancestor` passed for:

- CHG-2026-035 archive
  `5fc517f7ecfccd61ed0d140f9080e4b49e2cad95`；
- CHG-2026-036 proposal
  `16b3dbc7f7d2c565f15388bc1ca0f2aef41dd867`；
- CHG-2026-036 approval
  `9bbc51313af9575c3d762db0f15692da753a3e01`；
- TASK-BRC-001 readiness
  `e32cdaba9f465fc2e264f8b61ad135efab3487a8`.

The complete open-PR query returned only #523, whose seven paths are confined to
CHG-2026-034. It does not overlap this task. Before edits, the two exact deliverable
paths and the future bundled-component registry path were absent.

## Commands and results

All source files were kept under
`/private/tmp/arkdeck-brc001-decision.JAMvp9`; nothing from that directory is a
repository deliverable.

### Source retrieval and identity

```text
curl -L --fail --silent --show-error \
  https://codeload.github.com/rockchip-linux/rkdeveloptool/tar.gz/304f073752fd25c854e1bcf05d8e7f925b1f4e14 \
  -o /private/tmp/arkdeck-brc001-decision.JAMvp9/rkdeveloptool-304f073752fd25c854e1bcf05d8e7f925b1f4e14.tar.gz

curl -L --fail --silent --show-error \
  https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 \
  -o /private/tmp/arkdeck-brc001-decision.JAMvp9/libusb-1.0.30.tar.bz2

curl -L --fail --silent --show-error \
  https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2.asc \
  -o /private/tmp/arkdeck-brc001-decision.JAMvp9/libusb-1.0.30.tar.bz2.asc

curl -L --fail --silent --show-error \
  https://raw.githubusercontent.com/libusb/libusb/v1.0.30/KEYS \
  -o /private/tmp/arkdeck-brc001-decision.JAMvp9/libusb-v1.0.30-KEYS
```

Exact `shasum -a 256` and `stat -f` results:

| Input | Bytes | SHA-256 |
| --- | ---: | --- |
| rkdeveloptool source | 59,310 | `389ba41af6986c16f1eeebdc1febcb0bf4b8acb7abd694d3d652e78504215843` |
| libusb source | 656,112 | `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf` |
| libusb signature | 833 | `7e8916e689a399b98df1087cfc48eab33a6bfd8027291c5af00c3fbba90a2cec` |
| libusb KEYS | 7,048 | `52b20b8f44c0912fdbd0c7f53c14629b9b72834118dd52ecff3fec671ba50ff3` |

The initial `gpg --import && gpg --verify` attempt imported the public key but
returned 2 because the isolated environment could not connect to `gpg-agent`; it
performed no signing or trust mutation outside OS temp. Verification was repeated
with the read-only verifier:

```text
gpgv --status-fd 1 \
  --keyring /private/tmp/arkdeck-brc001-decision.JAMvp9/gnupg/pubring.kbx \
  /private/tmp/arkdeck-brc001-decision.JAMvp9/libusb-1.0.30.tar.bz2.asc \
  /private/tmp/arkdeck-brc001-decision.JAMvp9/libusb-1.0.30.tar.bz2
```

Result：`GOODSIG` and `VALIDSIG`
`9C7EA94939C69C4FBC3DBFA8AA0639079EFB61B9`, primary fingerprint
`C68187379B23DE9EFC46651E2C80FF56C6830A0E`.

The first globbed hash command also returned 1 after encountering newly created
directories; it had already printed correct file hashes. The exact four-file command
was rerun and returned 0 with the table above.

`tar -tv` confirmed both chosen archives contain only directories and regular files.
Read-only extraction plus `rg` confirmed:

- exactly nine rkdeveloptool files carry literal `GPL-2.0+`；
- `Property.hpp` carries its distinct keep-the-header redistribution notice；
- exact source calls libusb and has zero iconv API/include references；
- upstream CMake alone hard-codes Homebrew libusb 1.0.22/libiconv paths；
- libusb `COPYING` SHA-256 is
  `5df07007198989c622f5d41de8d703e7bef3d0e79d62e24332ee739a452af62a`；
- libusb Darwin configuration links Objective-C, IOKit, CoreFoundation and
  Security.

### Vulnerability sources

Exact-commit OSV POST queries for
`304f073752fd25c854e1bcf05d8e7f925b1f4e14` and
`87a55632db62c9bdc58cd31d3ccfa673f1bb017f` each returned `{}`.

The NVD CVE 2.0 query:

```text
curl -L --fail --silent --show-error \
  'https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=libusb&resultsPerPage=200'
```

returned eight keyword matches. Six refer to other products or kernel paths.
`CVE-2026-23679` and `CVE-2026-47104` identify `cpe:2.3:a:libusb:libusb` with
`versionEndExcluding: 1.0.30`; therefore they reject 1.0.22 and do not match selected
1.0.30. This is a dated review, not a permanent no-vulnerability statement.

### Repository and platform facts

Read-only Git/source/SDK inspection confirmed:

- product feed accepts only `architectures == ["arm64"]`；
- ArkDeck project/package deployment target is macOS 14.0；
- SDK `iconv.h` / `libiconv.2.tbd` identities match readiness pins；
- selected source/dependency/build/distribution decisions in the record have exact
  successor machine gates；
- no existing decision/evidence/registry path was overwritten.

Base checks:

```text
PATH=/private/tmp/arkdeck-sdd.rqX8w2/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  scripts/check-sdd.sh
  -> check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

/private/tmp/arkdeck-sdd.rqX8w2/venv/bin/python \
  scripts/test_check_pr_paths.py
  -> 24/24 PASS
```

Post-edit checks:

```text
PATH=/private/tmp/arkdeck-sdd.rqX8w2/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  scripts/check-sdd.sh
  -> check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

/private/tmp/arkdeck-sdd.rqX8w2/venv/bin/python \
  scripts/test_check_pr_paths.py
  -> 24/24 PASS

git diff --check
  -> PASS
```

Changed-path, forbidden-path and secret/privacy scans are recorded as PASS below.

## Decision result

| Field | Result |
| --- | --- |
| upstream/sourceArchive | PASS — exact commit/tree/URL/size/hash |
| licenseInventory | PASS — GPL/package files/Property/libusb separated |
| notices | PASS — deterministic required content fixed |
| correspondingSource | PASS — §3(a), same-release complete source, five-year minimum retention |
| source modifications | PASS — zero；any future patch requires fresh D1 |
| libusbChoice | PASS — signed `1.0.30`, static；`1.0.22` rejected |
| libiconvChoice | PASS — Apple `systemProvided`, zero bundled GNU/Homebrew bytes |
| transitiveDependencies | PASS — exact direct/system allowlist fixed |
| architecture/minimum OS | PASS — `arm64` / `14.0.0` |
| builder/toolchain | PASS — exact OS/Xcode/SDK/clang/make/shell |
| hermetic/reproducibility | PASS — closed environment, two byte-identical builders, no normalization |
| sbomFormat | PASS — SPDX 2.3 JSON |
| vulnerability ownership/SLA | PASS — exact sources/owners/freshness/response windows |
| release/update/rollback/retention | PASS — atomic tuple, higher-version disable/restore, five years |
| successor machine gates | PASS — exact build/dependency/SBOM/negative-drift contract |

`proposedDisposition: accept`. It becomes the maintainer-accepted envelope only when
this exact head is reviewed and merged. Until then TASK-BRC-001 remains `ready`;
TASK-BRC-002 remains `blocked`.

## AC mapping

| Acceptance | This run's result |
| --- | --- |
| `BRC-SUPPLY-001` | proposed PASS：source/license/dependency/distribution fields, owners and machine pins are complete |
| `BRC-HANDOFF-001` | PASS：only the two readiness-authorized document/evidence paths changed；Core/HDC/CHG-2026-026/product unchanged |
| `AC-FLASH-013-01` | PASS for this task's document-review slice：future diagnostics name component/source/dependency/SBOM stage and actionable block/rollback owner；no sensitive data |
| `AC-UX-007-01` | PASS for this task's distribution slice：no silent install/elevation/helper/rule/group/ACL path；missing tuple remains execute-disabled |

This run does not claim the remaining platform/runtime/hardware slices of canonical
ACs or any real Flash support.

## Effect and privacy counters

| Effect | Count |
| --- | ---: |
| ArkDeck/App build or launch | 0 |
| rkdeveloptool/libusb configure, compile, link or launch | 0 |
| binary/package/sign/notarize/install/update | 0 |
| HDC/process/helper/XPC/daemon dispatch | 0 |
| USB/device/file-picker/bookmark access | 0 |
| device mutation / E1 / E2 / destructive step | 0 |
| entitlement/system-rule/group/ACL/privilege mutation | 0 |
| source/dependency/binary bytes added to repository | 0 |

The only network effects were analyst-side official GitHub/GNU/OSV/NVD reads. No
credential, private key, user path, device identifier, bookmark, image/key content,
raw system log or source/binary payload is committed.

## Changed-path and scope audit

Exact changed paths:

1. `docs/release/rockchip-component-distribution.md`
2. `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/runs/TASK-BRC-001/run.md`

Forbidden-path changes：0.
Secret/privacy scan：PASS.
Product/build/source/vendor/registry changes：0.
Task status remains `ready`; D0 `done` is a separate future PR.

## Residual risk and handoff

- Legal/distribution acceptance is pending maintainer exact-head review/merge.
- Reproducible build, actual Mach-O dependency graph and source-package bytes do not
  exist yet; Task 002 must prove them on two clean builders.
- Developer ID, nested entitlements, notarization, signed Sandbox child/file/RockUSB
  E0 and clean-host update/rollback remain Tasks 003–006.
- No hardware support or one-click Flash claim follows from this decision.
- Any record revalidation trigger returns the lane to `blocked`; no fallback is
  authorized.

# TASK-RKFUI-001D immutable rkdeveloptool source-provenance closure

- Time: `2026-07-24T15:13:31Z`
- Executor: autonomous agent
- Base: `37e16c5dd42951c02422627b9f7ca0d72a5cdafc`
- Authorization input: `PR#491@37e16c5dd42951c02422627b9f7ca0d72a5cdafc`
- Classification: host-only registry/probe implementation and hermetic tests
- Hardware required/used: no / no
- Result: **PASS; no task status change and no real HDC, rkdeveloptool, USB or device dispatch**

## Readiness and input closure

PR #491 merged CHG-2026-026 r6 and made TASK-RKFUI-001D ready. The implementation began from
that exact merge commit. The approved input blobs matched without drift:

| Input | Git blob |
| --- | --- |
| loader-transition registry | `107f00279259674e0d8928f77b4c8170e11ea0b1` |
| probe | `e98b5306c95f2c3ff511cffb2c04c366a29fae06` |
| probe tests | `88ac093320ae74231ed4a089b1eb862689845d2c` |
| probe README | `0f6bf758d497127b7df6eb7d26f940e8daf54e6a` |
| reviewed source evidence | `fb57e765a27801d5842e29dad14c108cbbc2510d` |

The reviewed source evidence byte SHA-256 was independently rechecked as
`d0b5089954e19a4aba354846fe6108b2d5c89bfc12ab0396c2cd7eb4a082189a`.
Only the TASK-RKFUI-001D Allowed paths changed. No proposal/task status, RockUSB discovery
registry, Swift/Packages, App, Core/spec/contract, Provider/Profile or destructive pin changed.

## Implementation

- Appended the exact r6 authorization ref
  `PR#491@37e16c5dd42951c02422627b9f7ca0d72a5cdafc`.
- Added one registry `sourceProvenance` tuple binding:
  - kind `protectedMainArtifactDigestToUpstreamCommit`;
  - artifact SHA-256 `bbd7bdc0…9923`;
  - upstream commit `304f0737…`;
  - source acceptance `PR#445@cbad982cc211c7d8579a025b8c35f4ed1a519f16`;
  - reviewed evidence path and exact SHA-256 `d0b50899…189a`.
- The loader-transition probe now validates the exact registry shape, top-level/provenance
  tuple equality, safe repository-relative evidence path and reviewed evidence bytes before any
  external runner call. It then independently retains the actual artifact regular-file,
  executable, hash, version, ad-hoc signature and quarantine-absent gates.
- Removed executable-parent `/usr/bin/git -C <parent> rev-parse HEAD` source inference and its
  command receipt. The sanitized tool receipt now records the reviewed provenance tuple,
  evidence digest and validation verdict; it does not manufacture a replacement command receipt.
- Updated the host-only README and negative matrix. Missing/unknown provenance, every registered
  field drift, top-level tuple drift and evidence-byte drift fail closed. The same exact binary
  under two different unrelated `.git/HEAD` values produces the same provenance verdict and
  dispatches Git zero times.

The implementation output blobs before this evidence file were:

| Output | Git blob |
| --- | --- |
| loader-transition registry | `a9b489ee7a4ed6a3382d01b036fa4d5c7f821b1a` |
| probe | `54140eec7557858982be1b8768ae93047867306a` |
| probe tests | `dbcc9ebb1c8fda8094da71972edd5b1d15fb3713` |
| probe README | `c3bbbd64c7cf33735836c5107ac7c784901972de` |

## Verification

| Command/check | Result |
| --- | --- |
| `python3 -m unittest scripts/rockchip_loader_transition_probe/test_probe.py -v` | PASS: 31 tests, 0 failures |
| `python3 scripts/rockchip_loader_transition_probe/probe.py selftest-host` | PASS |
| registry before/after semantic equality with only r6 ref + exact `sourceProvenance` added | PASS |
| reviewed source evidence SHA-256 | PASS: exact `d0b50899…189a` |
| AST/source audit of `inspect_rkdeveloptool` | PASS: no `/usr/bin/git`, `rev-parse`, executable `path.parent` inference or `commitReceipt` |
| unrelated parent Git HEAD positive matrix | PASS: two distinct HEAD values, equal provenance receipts, Git dispatch 0 |
| provenance negative matrix | PASS: all failures before tool/version/codesign/xattr/`ld` runner calls |
| `ARKDECK_PYTHON=/opt/homebrew/anaconda3/bin/python3 CI=true sh scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| `python3 scripts/test_check_pr_paths.py` | PASS: 24 tests |
| exact TASK-RKFUI-001D PR allowed-path simulation | PASS: 6 changed paths |
| targeted private-key/token/password scan of the diff | PASS |
| `git diff --check` | PASS |

The unit suite remains hermetic. Its pre-existing combined-output-limit test launches one
synthetic Python child process; fake runners cover all HDC/rkdeveloptool/codesign/xattr/device
paths and do not constitute hardware or production provenance evidence.

## Safety counters

- Real HDC commands and server lifecycle mutations: **0 / 0**.
- Real `rkdeveloptool -v` / `ld`: **0 / 0**.
- Real codesign/xattr/USB observations: **0 / 0 / 0**.
- Runtime `/usr/bin/git` source inference: **0**.
- Binding, capability evidence, impact confirmation, intent and usage reservation: **0**.
- E1/deviceMutation, `reboot loader` and retry: **0 / 0 / 0**.
- E2/destructive and `ppt/wlx/rd`: **0 / 0**.
- Flash/erase/format/unlock/update, host shell, sudo/helper/driver/system mutation: **0**.

## AC conclusion and remaining gate

The scoped implementation and negative behavior for `AC-FLASH-002-01`, `AC-DEV-001-01` and
`AC-DEV-002-01` pass at the registry/probe contract layer. This run is not device capability,
real-hardware or E1 evidence and does not mark TASK-RKFUI-001D done.

After this implementation/evidence PR is maintainer-reviewed and merged, a separate D0 status
PR must mark TASK-RKFUI-001D done and restore TASK-RKFUI-001A fresh E0 preparation. The PR #487
candidate count remains unobserved (`null`), not zero. Fresh E0 must still prove zero
pre-existing RockUSB candidates and every exact target/tool/source pin before a separate
per-device typed capability evidence acceptance PR can be proposed. Until that D2 gate merges,
E1 remains zero.

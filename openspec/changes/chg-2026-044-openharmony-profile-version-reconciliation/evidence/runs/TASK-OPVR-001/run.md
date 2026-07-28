# TASK-OPVR-001 host-only implementation run

- Date:2026-07-28 (Asia/Shanghai)
- Executor:agent
- Evidence class:contract / repository host-only
- Platform:macOS 26.6, arm64
- Python:3.14.6
- PyYAML:6.0.3
- Protected-main base:
  `ae07a98ee525ff65e578611e209e7ab9b7bdcd06`
- Readiness approval:
  - PR #745 exact head:
    `32ca5837322b2bc26ff1fbd121573da8325c1e51`
  - PR #745 merge:
    `018b28c346c896a3d23342510f310d74a3bf6b61`
  - maintainer `lvye` review on the exact head:`APPROVED`
- Subsequent base change:#746 only changed TASK-AIN-009R readiness; no overlap with
  this task's profile, lock, checker, tests, change package or allowed paths.
- Governance-only network outside the run:the user-requested `gh pr view` /
  `git fetch origin main` confirmed and fetched the merged readiness; later
  push/PR publication may use the same governance channel. These do not
  execute task tests or modify scoped product/runtime state.
- Implementation/verification effect declaration:installed HDC 0, real device
  0, network 0, server lifecycle 0, binding/device mutation 0, destructive
  dispatch 0.

`<sdd-python>` below denotes the repository's prescribed shared
`.venv-sdd/bin/python`, selected by `scripts/check-sdd.sh`; the user-home prefix
is deliberately not copied into evidence. The PATH `python3` was 3.14.6 but did
not import PyYAML, so the direct preflight attempt
`python3 scripts/test_check_sdd.py` exited 1 with
`ModuleNotFoundError: No module named 'yaml'`. No repository or runtime state
was changed. The repository-selected interpreter had the pinned PyYAML 6.0.3
and ran all authoritative checks below.

## Input and output pins

| Input/output | Readiness/base identity | Run identity/result |
| --- | --- | --- |
| `proposal.md` | blob `f0a8fd9e373c86e9d2417855b3390319fe09d22a` | unchanged |
| `verification.md` | blob `e8774b51e96510d7286fd652f693b0ffc48ce782` | unchanged |
| OpenHarmony profile | blob `8889864cb023e43a745862e99a3f307d168e410c`; SHA-256 `6bcf7e8ed5ee74215bc72963a5b0a7e862010e48bad03438445ae442c235cfd2` | blob `4bfe204b1c13e53b93b35f840652206274614299`; SHA-256 `477373827f026376e91d6629fa2eb95f87d5b9b99e61dafaf815e86689fc4824` |
| profile with the sole `> Version...` line removed | SHA-256 `ab57ba2877ed6b8bd124e8aa21f7c05a8f9b91762fb8cdf736a80d28aef6d43c` | same SHA-256; body byte-identical |
| integration lock | blob `9297820f25b9276859c60ba6bd89ab399066dcd0`; SHA-256 `802d87819b8ce39f197b7b59bfffde24d074cf7db33c3e80c89f9f8b3a5f8b46` | unchanged |
| device-observation registry | blob `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a`; SHA-256 `79814e45901ab7e4d9f9a271645cad62b0053a50534cba884cdff0c2e50b9d49` | unchanged |
| readonly registry | blob `99e8cc3d9929f9502a3e978a53cd56ad285d2aad`; SHA-256 `b0ac1564109b8138c7a73cbb83684400967633f6e6b04701175a22d314d88da6` | unchanged |
| trace registry | blob `9c59c102784661fb1f50c31916e29cbeeb6bd457`; SHA-256 `9d2a390b84092f1d78d86c10bf182884bc3a2ef8b3cdc3d35ed8e7e2b087b613` | unchanged |
| core conformance | blob `799d0051463f9aed50ff3c9e50045ef06f61c35e`; SHA-256 `9e7b1e2c0c0cbb26fd3ab8881c80aeea04dd55e24853fba54bfc4bce1053adc5` | unchanged |
| macOS profile | blob `e4bcf6da97f94c55efaf0a13806881038efa12e0`; SHA-256 `8ae19225659b2974db6adc8b150537e5c35c17bf0bfdbe21633297bc2fd91f99` | unchanged |
| `scripts/check_sdd.py` | blob `3144f77e33d500d64d49ca1f087868dfa50493b4` | blob `aa7dc6e34d187cb6458689d72ac28564b58fb29b`; SHA-256 `1c2b8c71cb856db5f0ddef69af4e8c070f14b537b6c92706344b5304951fa151` |
| `scripts/test_check_sdd.py` | blob `e61e3c5439aedc40dc0b347005ffcb74e985cc38` | blob `7e6c47044b31065d2752ce78d9185b6a3869732b`; SHA-256 `75ee8ab314b48f374813655794f6e71530cf551fb80a57ff93ec2ce7fef5dbc6` |

## Implementation result

- The living profile changed only `> Version：0.4.0` to
  `> Version：0.5.0`; deleting that one line from the result reproduces the
  readiness body digest exactly.
- `check_sdd` now validates every integration `profiles[]` entry as a mapping
  with non-empty string `id`/`version`/`path`, unique IDs and paths, and a
  repository-local readable Markdown target.
- The profile reader accepts only the first contiguous blockquote metadata
  block after the first Markdown H1 (with blank-line separation), recognizes
  exact `ID`/`Version` keys with ASCII or full-width colon, trims value and
  Markdown trailing spaces, and does not infer from prose, fuzzy prefixes or
  later blockquotes.
- Missing, duplicate, empty, malformed, wrong-type, missing-path,
  non-Markdown, unreadable, ID mismatch and version mismatch cases append
  deterministic errors. A malformed profile does not suppress later
  core-conformance diagnostics.
- The lock remains `INTEGRATION-PROFILES-0.6.0`; no
  `OPENHARMONY-TOOLS@0.6.0` or `INTEGRATION-PROFILES-0.7.0` was created.

## Commands and results

| Command | Result |
| --- | --- |
| `<sdd-python> scripts/test_check_sdd.py IntegrationProfileHeaderLockTests -v` | PASS; 8 tests, 0 failures |
| `<sdd-python> -m unittest test_check_sdd` from `scripts/` | PASS; 56 tests, 0 failures |
| `python3 scripts/test_check_pr_paths.py` | PASS; 50 tests, 0 failures |
| `scripts/check-sdd.sh` | PASS; 0 errors, 0 warnings, 111 canonical acceptance IDs |
| independent `Path`/`re` + YAML/JSON extraction (without importing `check_sdd`) | header `OPENHARMONY-TOOLS@0.5.0`; lock `INTEGRATION-PROFILES-0.6.0` with one `OPENHARMONY-TOOLS@0.5.0` profile entry; device registry `OPENHARMONY-TOOLS@0.5.0` |
| `sed '/^> Version[：:]/d' .../profile.md \| shasum -a 256` | PASS; `ab57ba2877ed6b8bd124e8aa21f7c05a8f9b91762fb8cdf736a80d28aef6d43c` |
| `git diff --name-only origin/main` before adding this run | exact implementation paths only: profile, checker, checker tests |
| forbidden-path `git diff --name-only origin/main -- <closed forbidden set>` | PASS; no output |
| `git hash-object` over lock, device/readonly/trace registries, core conformance and macOS profile | PASS; all six readiness blobs exact |
| `git diff --check` | PASS |
| changed-file token/private-key/user-home scan with `rg` | PASS; 0 matches (`rg` exit 1) |

### Explicit mutation-red / restored-green

The fixture supplies the expected lock values independently; no expected value
is copied from parser output.

```text
mutation-red:
ERROR openspec/integrations/INTEGRATION-PROFILES.lock.yaml: profiles[0].version '0.5.0' does not match profile metadata Version '0.4.0' at openspec/integrations/fixture/profile.md
restored-green-errors: 0
```

The same focused suite also proves ASCII/full-width clean controls, ID
mutation, missing/duplicate/empty/fuzzy metadata, non-mapping and wrong-type
entries, duplicate ID/path, missing/non-Markdown/unreadable targets, and
continued independent conformance reporting.

## Acceptance conclusion

| Change-local AC | Result | Evidence |
| --- | --- | --- |
| `OPVR-HEADER-LOCK-001` | PASS (`contract`) | independent header/lock/device extraction; exact 0.5.0 lineage; profile body digest exact; lock blob unchanged |
| `OPVR-MUTATION-001` | PASS (`contract`) | 8 focused tests; explicit 0.5.0→0.4.0 red diagnostic and restored green; full malformed/duplicate/type/path matrix |
| `OPVR-NONINTERFERENCE-001` | PASS (`contract`) | forbidden blobs exact; full SDD/path suites green; changed-path secret/privacy scan clean; all external dispatch counts 0 |

## Deviations and residual risk

- Scope deviation:none.
- The unpinned PATH interpreter lacks PyYAML; the repository-prescribed shared
  SDD interpreter is available, exactly matches the dependency pin and passes
  the complete suite. No dependency install or dependency-fetch network access
  was attempted.
- The checker is synchronous and read-only. Cancellation or process failure
  can leave neither repository mutation nor runtime/device state; synthetic
  fixture writes are confined to OS temporary directories.
- This run is not real-hardware evidence and makes no integration support,
  conformance or release claim beyond the three change-local ACs.
- `TASK-OPVR-001` remains `ready` until the separate `ready→done` status PR is
  reviewed and merged. CHG-2026-044 remains unverified; CHG-2026-043
  `TASK-HSO-001` remains blocked pending the later verified gate and its own
  fresh D1 readiness.

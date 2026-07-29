# TASK-RTC-001 verification closure replay r1

Date:2026-07-29

Classification:`contract`. This record is not installed-HDC, real-device,
platform-conformance or `realHardware` evidence.

## Verdict

PR #774 exact head
`d45b3090976fef6e1b47ea9ddbbec688edd6b383` was approved by maintainer
`lvye` and merged as
`4ef6932a53f86a0c8ef53367ecb3c091cf9e3442`. Its same-revision
`run-r1.md` records all five `RTC-*` AC as PASS.

The closure replay began on protected main
`d037768f5e92850861219cd64edf53bfbb4b56ae`. During the replay, #792 merged
as `487b4c0ecefd37461c2b83aa9e2f32e90e26fdf9`; its diff is confined to
CHG-049 device-window plan/evidence/task files. `Packages/ArkDeckKit`,
`Catalog/` and `openspec/governance/enforcement.md` retain identical tree/blob
identities across those two commits:

```text
a5a7e1d8e30f42dee6627b43b4906c7a2750560d  Packages/ArkDeckKit
dd470e3c27889825c8defb40cff0ae8924cef2ea  Catalog
c65f050778fd2faba95ee61193cbd075c8c3520f  openspec/governance/enforcement.md
```

The full Swift and script results below therefore apply to verification base
`487b4c0ecefd37461c2b83aa9e2f32e90e26fdf9`; `scripts/check-sdd.sh` and
`git diff --check` were also replayed directly after the #792 advance.

All five `RTC-*` conclusions remain PASS. This record does not itself approve
`verified`; that state takes effect only if the maintainer reviews and merges
the verification PR.

## Delivery trust chain

- Proposal #773 exact head
  `84324ccc308b625f8ebebbb09a7956519fdbf0bf` was approved by maintainer
  `lvye` and merged as
  `30caed6f9e0776a43df8e0b4e03b8bd99757497a`.
- Implementation #774 exact head
  `d45b3090976fef6e1b47ea9ddbbec688edd6b383` was approved by maintainer
  `lvye` and merged as
  `4ef6932a53f86a0c8ef53367ecb3c091cf9e3442`.
- Both PRs' required Agent PR, SDD Guard and Swift CI checks were `SUCCESS`.
- The approval/merge facts establish authority. The concrete AC truth remains
  the implementation and closure run evidence.

## Approved evolution after #774

Later merged MUs extended the catalog runtime foundation. Relative to #774,
current main changes these original CHG-046 surfaces:

```text
M Catalog/generated/effect-authorization-matrix.md
M Catalog/operations/capture.diagnostics.v1.json
M Catalog/operations/debug.hap.v1.json
M Catalog/operations/flash.dayu200.v1.json
M Catalog/schema/operation.schema.json
M Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift
M Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift
M scripts/catalog_gen/generate.py
M scripts/catalog_gen/test_generate.py
```

The CHG-046 governance documents, Runtime API v2, RuntimeCapability model/store,
legacy adapter and four original Swift test files are otherwise unchanged from
#774. The changed catalog/generator inputs are not assumed equivalent: their
current behavior is covered by the fresh schema/generator/SDD/full-Swift
results below.

Current changed-input blob identities:

```text
7dde378010da7acb85b4bd75206389a0904c8905  Catalog/generated/effect-authorization-matrix.md
37ce723faf58780e00c11f5718f78a4271aef5ae  Catalog/operations/capture.diagnostics.v1.json
1189c9f5d4e73eab71c8ec3d52e7aa53eadf1627  Catalog/operations/debug.hap.v1.json
81e465086bcc14672daafa5e8efb45719903126d  Catalog/operations/flash.dayu200.v1.json
d0320ec62c6346fb59e6fa21d59533e851ce52d0  Catalog/schema/operation.schema.json
c4f22f82ab983dc6ae8a119d52598aed50d9f434  RuntimeOperationCatalogGenerated.swift
f51d5f327a12f8f0b681a651c3d435107ccd318e  RuntimeOperationCatalogTypes.swift
d17aaa56616cd5149d1d16b3b8d084bddc715f62  scripts/catalog_gen/generate.py
275f7c0acd6246c21203e2f1dff253fb4b8cb6a1  scripts/catalog_gen/test_generate.py
```

## Replay environment

```text
macOS 26.6 (25G72), arm64
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101)
SDD interpreter: shared repository .venv-sdd, Python 3.14 / pinned PyYAML
```

## Commands and results

| Command/gate | Result |
| --- | --- |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS, 651 tests / 1 existing opt-in manual sleep/wake skip / 0 failures |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 acceptance IDs; repeated on #792 base |
| shared-Python `scripts/test_check_sdd.py` | PASS, 62/62 |
| shared-Python `scripts/test_check_pr_paths.py` | PASS, 50/50 |
| shared-Python `scripts/test_agent_pr_workflow.py` | PASS, 8/8 |
| shared-Python `scripts/test_sdd_runtime_entry.py` | PASS, 33/33 |
| shared-Python `scripts/catalog_gen/test_generate.py` | PASS, 34/34 |
| shared-Python `-m unittest discover -s host_loop -t .` from `scripts/` | PASS, 644 tests / 1 expected failure / 0 unexpected failures |
| `git diff --check` | PASS |

The runtime-entry suite's linked-worktree integration case and two host_loop
redirect tests were first refused by the filesystem/network sandbox before
their assertions ran. They were rerun outside that sandbox with their intended
temporary Git metadata and loopback-only sockets; both complete suites then
passed as recorded above. No product network request or device command was
introduced by those test fixtures.

## Acceptance and effect boundary

- `RTC-GOV-001`:PASS through current governance text, path/automation/host_loop
  contract suites and unchanged D2/E2 enforcement.
- `RTC-API-001`:PASS through the unchanged v2 contract suite and fresh full
  regression.
- `RTC-CAP-001`:PASS through the unchanged model/store tests and fresh full
  regression.
- `RTC-CAT-001`:PASS through current catalog schema, generator 34/34,
  check-sdd drift family and generated Swift contract tests.
- `RTC-COMPAT-001`:PASS through the 651-test Swift regression and all declared
  script suites.

Closure activity executed contract/fake paths only. It did not intentionally
invoke the installed HDC, address a real device, dispatch device mutation or
destructive work, alter runtime capability state, or claim hardware/platform
support.

If protected main changes any governance, Runtime API/Capability,
catalog/generator or corresponding test input before this verification PR
merges, the affected replay must be repeated and recorded rather than inferred.

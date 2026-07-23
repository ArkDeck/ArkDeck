# TASK-TR-003 parser-golden host run

- Date:2026-07-23(Asia/Shanghai)
- Base:`main` `2f0c53e2924382bdf051c4975d1ed35b4ffd042d`
- Branch:`agent/task-tr-003`
- Environment:macOS arm64;Apple Swift 6.3.3;SDD guard CPython 3.14.6 + PyYAML
  6.0.3 from the existing host interpreter.
- Evidence class:`parserGolden`;all authority-bearing positive bytes come from the merged
  TASK-TR-001 registry/resource closure.All inline mutations and post-header event lines are
  parser-negative or derived contract vectors,not device observations or new golden provenance.
- Dispatch classification(task-specific suite):real device 0,HDC 0,network 0,external process 0.
  The full regression suite also exercises pre-existing local fake/process fixtures;it performs no
  real-device Trace work.No adapter command,capture,device mutation or hardware verification was
  dispatched.

## Readiness and scope pins

TASK-TR-003 began only after readiness PR #354 was maintainer-approved and merged to protected
`main` as `af9608917575e28b217f53cfffbe8eec3e60ba6f` from exact reviewed head
`6163701634552017793ae95c546d0aa1f05e0542`.The branch was then advanced through unrelated
governance PR #353 (`ff4bc40f3af7280a31bccd9996945ce44c18bf92`),PR #356,PR #355 and PR #357
to the current base `2f0c53e2924382bdf051c4975d1ed35b4ffd042d`;their CHG-028/CHG-029
governance files overlap neither this task's allowed paths nor its pinned inputs.The approved
change,`ready` task state,completed
TASK-TR-001/TASK-TR-002/TASK-TR-002R dependencies,allowed paths and verification methods were
rechecked before implementation.

The pre-edit audit matched the complete readiness closure,including:

| Input | Pinned value |
| --- | --- |
| Trace registry SHA-256 | `0c093f98b57706b3723a68ae7552bef0db0731a675fb6cc023f69bbe21d6e566` |
| Trace resources SHA-256 | `6b77b020b50921ef419720a434a186aba48c13e7284fa66598d4efd0c4f14879` |
| hitrace help SHA-256 | `9ab0718d7da1d5beb459c74548f89cc69775a931be7931686637d6e584d70e39` |
| bytrace help SHA-256 | `690ca26bbe14d6edd8ad163cce18c1f1a494e4984e8d86f1866f32b7f8bb94fd` |
| raw ftrace header SHA-256 | `4b6433a1845d533dd466aeb3db965e273f4d4db582c94fe67cf1cb6e1a625ae0` |
| HDC seam Git blob | `2dfe8e9d8290d6e939b4e3531ac81bb332a7cc29` |
| `Package.swift` Git blob | `91a1032f8a5ff9285154ef6f48ef35470b294eb7` |

All seven registered resource hashes,sizes and pack membership are also asserted directly by the
new contract suite.The final diff is limited to the new adapter source,the corresponding parser-
golden contract test and this run record.No accepted spec,contract,registry/resource,Package
manifest,UI,workflow,other task evidence or `tasks.md` state was changed.

## Scope implemented

- Adopted the exact `OPENHARMONY-TRACE-PROBES`@1.0.0 profile and complete resource closure.
  `hitrace.dayu200-oh7.text-v1` is capture-eligible;the registered bytrace family remains
  `probeOnlyNotCaptureEligible`;wrong-tool,unknown,byte-drifted,missing-marker,invalid-timestamp
  and stderr-bearing output is unsupported while raw stdout/stderr and its hash remain
  inspectable.
- Help normalization permits only the registry-authorized leading
  `YYYY/MM/DD HH:MM:SS ` token pair,including calendar/time range checks.Executable name,
  firmware,marker fragments or process exit status cannot independently create family authority.
- Ftrace postprocessing first requires the exact 601-byte registered header,retains an immutable
  raw snapshot/hash,and copies the header prefix byte-for-byte before considering any filter.No
  fixed-position line deletion exists.
- The optional derived filter removes only identifier-boundary-matched `CreateFileAsset` lines
  after the registered header,never comments/header lines or larger identifiers;it reports exact
  removed line/byte counts.Unknown headers fail closed while preserving raw evidence.

## Verification commands and results

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit --build-tests` | PASS. |
| `swift test --package-path Packages/ArkDeckKit --filter TraceAdapterGoldenTests` | PASS;7 tests,0 failures. |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS;365 tests executed,1 existing opt-in manual sleep/wake test skipped,0 failures/0 unexpected(baseline 358 + 7 TASK-TR-003 tests). |
| `python3 -m unittest scripts/trace_capture/test_registry.py -v` | PASS;4 tests,0 failures,including registry closure and fail-closed tamper/unlisted cases. |
| `python3 scripts/trace_capture/validate_registry.py` | PASS;7 entries,7 resources,14939 fixture bytes,registry/resources pins matched,real-device dispatch 0. |
| `ARKDECK_PYTHON=/opt/homebrew/anaconda3/bin/python3 ./scripts/check-sdd.sh` | PASS;0 errors,0 warnings,111 acceptance IDs. |
| `python3 scripts/test_check_pr_paths.py` | PASS;12 tests,0 failures. |
| `swift format lint <two TASK-TR-003 Swift files>` | PASS;0 diagnostics. |
| `git diff --check` + allowed/forbidden-path audit | PASS;only the three exact allowed paths above;forbidden matches 0. |
| sensitive-material scan over changed files | PASS;credential assignment/token-prefix markers and real device identifiers matched 0. |

The first Swift baseline attempt inside the filesystem sandbox stopped before compilation because
the compiler's user cache path was not writable.The identical command was rerun using the approved
sandbox-external Swift prefix and passed;this was an execution-environment failure,not a product
test failure.No dependency installation or network access occurred.

## AC conclusions

| Acceptance | Result | Reproducible evidence line |
| --- | --- | --- |
| `AC-TRACE-001-01` | PASS | `TEST-AC-TRACE-001-01 PASS hitrace=eligible bytrace=probeOnlyNotCaptureEligible unknown=unsupported raw=inspectable real_device=0 hdc=0 network=0 process=0` |
| `AC-TRACE-007-01` | PASS | `TEST-AC-TRACE-007-01 PASS registered_header=preserved raw_sha256=unchanged fixed_line_deletion=0 removed_lines=0 real_device=0 hdc=0 network=0 process=0` |

## Deviations and residual risk

- No scope or product deviation.The cache-path retry above is the only execution-environment
  deviation.
- Only the two exact registered help families and exact registered header are recognized.Any
  future firmware/tool byte family requires a reviewed registry/integration change;unknown drift
  remains unsupported.The bytrace family remains intentionally probe-only.
- `CreateFileAsset` filtering is optional,derived-only and closed to the exact post-header token;
  raw bytes and their pre-filter hash remain authoritative.No broader noise classifier is claimed.
- This parser-golden run establishes no real-device,firmware,adapter-command,capture-performance or
  hardware-support result.It intentionally leaves TASK-TR-003 `ready` and the change not
  `verified`;status progression requires a separate maintainer-reviewed governance PR.

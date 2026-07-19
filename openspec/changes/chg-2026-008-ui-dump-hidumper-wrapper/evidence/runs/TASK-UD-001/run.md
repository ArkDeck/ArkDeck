# TASK-UD-001 headless implementation and acceptance run

- Date/time: 2026-07-19 19:13:42–19:14:38 CST (Asia/Shanghai)
- Base revision: `8c1311b8be74c0393c2d490f72c63ffa39b3cdb6`
- Implementation revision: `1ef6d6ae6db44cdea82cd64f91c6edc5ad6b266b`
- Implementation tree: `45e8af3cdf90846be9707f1996eece6f2c1dc44a`
- Environment: macOS 26.5.2 (25F84), arm64; Xcode 26.6 (17F113); Swift 6.3.3;
  swift-format 6.3.0; existing SDD virtualenv with CPython 3.14.6 and PyYAML 6.0.3.
- Evidence class: deterministic contract tests plus registration review of pre-existing
  `controlledHumanCapture` inputs. No new capture or hardware/support evidence was produced.

## Scope and implementation result

The implementation pins the four canonical Recipe invocations to remote executable `hidumper`
with argv `-s WindowManagerService -a <typed service argument>`. The service argument is not a
host shell command: it is selected by the closed `HiDumperRecipe` enum and contains only fixed
tokens plus ASCII identifiers validated before an invocation value can be constructed.

M0B registered only the `System ability list:` success family, so Recipe and window-inventory
outputs deliberately remain unregistered/`unknownOutput`. Exit code zero is insufficient for
success; the observed `hidumper: option ... missed` form is an explicit failure, and failure takes
precedence across stdout/stderr and chunk boundaries. No unobserved Recipe output marker was
invented and no compatibility claim was added.

The four existing M0B streams were copied byte-exactly into HiDumper Golden pack 1.0.0. The pack
records its controlled-human-capture boundary, redacted-manifest/tool hashes, privacy self-check,
per-stream size/hash, command lineage, and semantic role. Root `.gitattributes` marks every pack
`.bin` as binary before commit; SwiftPM exposes the unique
`Bundle.module/HiDumper/Golden/1.0.0/` tree. OPENHARMONY-TOOLS and its integration lock were bumped
to 0.3.0 and 0.4.0 respectively.

## Fixed Recipe argv

| Recipe | Remote argv |
| --- | --- |
| `nodeSummary` | `["-s", "WindowManagerService", "-a", "-w <windowId> -default"]` |
| `elementTree` | `["-s", "WindowManagerService", "-a", "-w <windowId> -element -c"]` |
| `fullDefaultTree` | `["-s", "WindowManagerService", "-a", "-w <windowId> -default -all"]` |
| `componentDetail` | `["-s", "WindowManagerService", "-a", "-w <windowId> -element -lastpage <componentId>"]` |

## Input and fixture integrity

| Stream | Bytes | SHA-256 | Controlled input vs fixture |
| --- | ---: | --- | --- |
| help stdout | 34 | `a4904901becfb1a15517c14c51f6fa26524162008578bab3dc64f1c7baa006e5` | byte-exact PASS |
| help stderr | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | byte-exact PASS |
| services stdout | 3121 | `351fc59ea33de263a6123c6030624e1a1fcd17ae0eb5dab6d67ffba09ec07a4b` | byte-exact PASS |
| services stderr | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | byte-exact PASS |

The repository redacted manifest hash is
`14e0ce82eaccbd92b8755417104f8c0a57a8aa313db4566d19db3d5a83f1811f`, matching the registry.
Its `selfCheckPassed` is true and its per-stream serial/user-path/key-material flags are false.
The fixture/registry privacy scan found no `/Users/`, HDC key material, private-key marker, or
redacted connect-key placeholder.

## Commands and results on the implementation revision

| Command / audit | Result |
| --- | --- |
| `xcrun swift-format lint <three changed Swift files>` | PASS; 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter HiDumperWrapperContractTests` | PASS; 7 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter HiDumperGoldenResourceContractTests` | PASS; 4 tests / 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | PASS; 244 tests / 1 existing opt-in manual sleep/wake skip / 0 failures |
| `env ARKDECK_PYTHON=<existing-main-.venv-sdd> scripts/check-sdd.sh` | PASS; 0 errors / 0 warnings / 111 acceptance IDs |
| `cmp` for all four controlled M0B streams vs Golden streams | PASS; all four byte-exact |
| `shasum -a 256` for streams and redacted manifest | PASS; all sizes/hashes equal registry, profile, lock, and M0B evidence |
| `git check-attr text diff merge -- <HiDumper .bin>` | PASS; all three attributes unset by `binary` macro |
| fixture privacy scan | PASS; no forbidden path/key/private/connect-key bytes |
| changed-source launch API scan | PASS; no `ProcessRequest`, executor, `Process`, network, shell, DevEco/HDC path, `system`, or `popen` surface |
| base-to-implementation allowed-path audit | PASS; all 12 paths are TASK-UD-001 allowed paths |
| staged secret/private-key scan | PASS; no matches |
| `git diff --check` | PASS |

The default `scripts/check-sdd.sh` interpreter failed before executing the guard because PyYAML
was absent; rerunning outside the sandbox showed the same missing dependency. The final run used
the pre-existing main-repository `.venv-sdd` containing PyYAML 6.0.3. No package was downloaded,
no environment was modified, and the final guard result above is the acceptance result.

## Change-local binary acceptance

| Test ID | Result | Evidence |
| --- | --- | --- |
| `TEST-INT-UD-WRAPPER-001` | PASS | exact argv for all four Recipes; malicious/missing/unexpected identifiers rejected before invocation construction; exit-0 success/failure/unknown branches, nonzero exit, failure precedence, split markers, stderr, and family isolation covered by 7 deterministic tests |
| `TEST-INT-UD-GOLDEN-001` | PASS | all four human-captured streams byte-equal and hash-equal; Golden registry, privacy/provenance boundary, profile, lock, `.gitattributes`, and Bundle.module paths agree; registered bytes drive only their declared family in 4 deterministic tests |

Both Test IDs bind to the same implementation revision
`1ef6d6ae6db44cdea82cd64f91c6edc5ad6b266b`.

## Dispatch and claim boundary

- TASK-UD-001 dedicated real HDC dispatch: `0`.
- Real device, capture, collector, device mutation/destructive dispatch: `0`.
- Non-loopback network dispatch by TASK-UD-001: `0`.
- Dedicated tests consume only in-memory adversarial bytes and `Bundle.module` fixtures.
- The required full suite separately exercised pre-existing repository fake-child and loopback
  regressions; those results are not TASK-UD-001 HDC, hardware, conformance, or support evidence.
- TASK-M1-006 remains blocked/non-done; no missing HDC probe, XCUITest, source-task AC, platform
  conformance, hardware, support, or release evidence was consumed or advanced.

## Deviations and remaining risk

- No implementation deviation or failing TASK-UD-001 acceptance remains.
- The four Recipe success output families are intentionally unregistered. Until a future approved
  integration change adds byte-pinned successful output, they fail closed as `unknownOutput`.
- The source capture covers only the observed DAYU200/toolchain combination and remains
  observed-only; this task makes no compatibility, conformance, hardware-support, or release claim.
- The full suite's one opt-in manual sleep/wake test remains skipped, unchanged and unrelated.

## Rollback

Revert implementation revision `1ef6d6ae6db44cdea82cd64f91c6edc5ad6b266b` together with this
evidence/status follow-up commit through a normal reviewed PR. Do not edit the controlled M0B raw
inputs or rewrite their history.

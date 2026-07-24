# TASK-RKFUI-001B — homogeneous LF/CRLF parser closure

- Time: `2026-07-24T05:03:06Z`
- Executor: autonomous agent
- Base: `f14d9de8d5f32d0998837466674adeff9516e5b5`
- Readiness: CHG-2026-026 r4 merged by PR #461; dependencies #301/#305/#460 merged
- Classification: host-only contract/fake implementation
- Result: **PASS for TASK-RKFUI-001B scoped acceptance**

## Implementation

- Replaced the single LF-only registry string with a closed structured grammar:
  homogeneous LF or homogeneous CRLF, mandatory final terminator, and explicit blocked
  dispositions for bare CR, mixed terminators, missing final terminators and empty records.
- Updated the canonical registry and byte-identical bundled mirror.
- Added seven binary fixtures and pinned all 17 fixture hashes/sizes in the canonical and bundled
  resource manifests:
  - LF/CRLF single and multi-device parity controls;
  - a synthetic 52-byte CRLF Maskrom wrong-mode control;
  - bare CR, mixed LF/CRLF, missing-final-terminator and empty-record faults.
- Swift and Python parsers now scan raw bytes for terminator family before record parsing. They do
  not use a generic line splitter that could silently accept mixed or incomplete input.
- Device semantics are unchanged. Only `0x2207:0x350a + Loader` is applicable; Maskrom,
  non-matching VID/PID, unknown mode, duplicate identity and malformed records remain blocked.

## Verification

| Command | Result |
| --- | --- |
| `swift test --package-path Packages/ArkDeckKit --filter RockchipDeviceDiscoveryContractTests` | PASS, 7 tests |
| `swift test --package-path Packages/ArkDeckKit --filter RockchipRockUSBFlashProviderContractTests` | PASS, 15 tests |
| `python3 -m unittest scripts/rockchip_loader_transition_probe/test_probe.py` | PASS, 23 tests |
| `python3 -m unittest scripts/rockchip_e0_probe/test_probe.py` | PASS, 6 tests; canonical/bundled registry and resource bytes match |
| `python3 -m py_compile scripts/rockchip_loader_transition_probe/probe.py scripts/rockchip_loader_transition_probe/test_probe.py` | PASS |
| `ARKDECK_PYTHON=python3.11 ./scripts/check-sdd.sh` | PASS, 0 errors, 0 warnings, 111 acceptance IDs |
| `PYTHONPATH=scripts python3.11 -m unittest scripts/test_check_sdd.py` | PASS, 19 tests |
| `xcrun swift-format lint --strict <changed Swift files>` | PASS |
| `git diff --check -- . ':(exclude)**/*.bin'` plus canonical/bundled `cmp` | PASS |
| full `git diff --check` | Seven expected warnings from the raw `.bin` fault/control bytes: CRLF or bare CR is reported as trailing whitespace, and the intentional empty record as a blank line |

The complete local ArkDeckKit run executed 383 tests: 381 passed, one manual sleep/wake test was
skipped, and two unrelated HDC packaged-resource path tests failed because the `/private/tmp`
worktree produced `/private` versus `/tmp` URL spellings. The failing
`HDCGoldenResourceContractTests` and `HDCProbeRegistryContractTests` files/resources are outside
this task's diff and allowed paths. The first failure was reproduced from a clean
`git archive origin/main` of base `5b41a153…` under another `/private/tmp` directory, confirming
that it predates this diff; the second reports the same `/private` versus `/tmp` path shape.
Required GitHub Swift CI remains a merge gate and must pass in its canonical checkout. This
implementation PR intentionally leaves `tasks.md` unchanged because that path is outside
TASK-RKFUI-001B's implementation allowlist; a separate D0 state-only PR may draft the `done`
transition after this implementation is maintainer-merged.

## Acceptance and safety conclusion

- `AC-FLASH-001-01`: PASS at contract/fake parser scope. Registered LF and CRLF produce identical
  observations. All new line-termination faults block, and the CRLF Maskrom control remains
  visible but Provider-inapplicable.
- This run is not real-hardware or per-device capability evidence and does not change hardware
  support.
- HDC commands: **0**.
- `rkdeveloptool` and USB observations: **0**.
- E1/deviceMutation, E2/destructive, `reboot loader`, `ppt/wlx/rd`: **0**.
- Binding materialization, `enterUpdater` intent and usage reservation: **0**.
- Host shell, privilege escalation and system mutation: **0**.

## Remaining gate

TASK-RKFUI-001B remains `ready` in `tasks.md` until this implementation is maintainer-merged and a
separate D0 state-only PR records its `done` transition.

TASK-RKFUI-001A remains E1-blocked. After this implementation is maintainer-merged, it may run a
new E0 capability preflight only when the environment has no pre-existing RockUSB candidate.
That per-device typed capability evidence must be accepted in a later maintainer-merged PR before
the one-shot E1 gate can be reconsidered.

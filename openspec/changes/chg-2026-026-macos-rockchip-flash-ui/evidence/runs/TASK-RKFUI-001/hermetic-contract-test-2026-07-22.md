# TASK-RKFUI-001 hermetic contract-test rerun

- Run time: 2026-07-22
- Executor: maintainer-directed agent
- Evidence classification: contract/fake and host-side static verification
- Hardware/device dispatch: 0
- Registry version: unchanged at `1.0.0`
- Task/change status change: none

## Scope and result

Removed the `#filePath` repository-root traversal from
`RockchipDeviceDiscoveryContractTests`: the suite previously derived the repository root from
the compile-time source path to read the canonical
`openspec/integrations/rockchip/rockusb-discovery/1.0.0/registry.yaml` / `resources.json` and
the manifest's repository-relative fixture paths, which breaks when the built test binary runs
from a different location than the build path.

- `registry.yaml` and `resources.json` are now copied into
  `Tests/ArkDeckContractTests/Fixtures/Rockchip/Discovery/1.0.0/` and enter `Bundle.module`
  through the existing `.copy("Fixtures/Rockchip")` resource rule; the Swift suite reads only
  `Bundle.module`.
- Manifest fixture verification resolves each resource against the bundle by stripping the
  pinned repository prefix, which itself stays asserted so the manifest keeps recording
  canonical repository paths.
- Copy/canonical divergence fails closed in `scripts/rockchip_e0_probe/test_probe.py`: a new
  test asserts byte equality between the canonical openspec files and the bundled copies.
  Registry bytes are not renamed, reserialized, or reformatted.

The same-family `#filePath` pattern in the HDC Golden/Probe and Trace contract suites is
outside TASK-RKFUI-001 allowed paths and remains recorded as a known limitation
(see PR #270 done notes).

## Verification

| Command / check | Result |
| --- | --- |
| `swift test --filter RockchipDeviceDiscoveryContractTests` from `Packages/ArkDeckKit` | PASS: 6 tests, 0 failures, in a `/private/tmp` worktree (bundle-only reads) |
| `python3 -m unittest scripts/rockchip_e0_probe/test_probe.py` | PASS: 6 tests, 0 failures |
| one-byte tamper of bundled `registry.yaml` → rerun python suite → restore | FAILS as intended, restore verified via `git status` clean |
| `xcrun swift-format lint --strict` on the changed contract test | PASS |
| `ARKDECK_PYTHON=<main-checkout .venv-sdd> scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |

No signed Sandbox E0/device attempt was rerun. The existing execute-readiness conclusion
remains blocked, and no task/change status is changed by this host-only rerun.

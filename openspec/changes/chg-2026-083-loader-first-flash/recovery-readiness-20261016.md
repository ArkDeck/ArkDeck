# Loader recovery follow-up — 2026-10-16

The existing four-hour recovery limit in `POL-RECOVERY-001` and `POL-AGENT-002`
applies to every campaign. The Rust recovery classifier retained a legacy
exception for any present campaign value, including an empty value. This repair
removes that exception and its admission message. It preserves the existing
in-budget classification, sixteen-epoch limit and recognition of already
completed, fully proved historical recovery without device dispatch.

Compatibility: this restores the current Core budget rule; it adds no operation,
profile, identity source, authority or safety-policy exception. Original unknown
outcomes, capability records and supersession requirements are unchanged.

## Local targeted checks

All logs below are local files under `D:/src/ArkDeck-wt/tools/`. Synthetic tests
use isolated stores and are not hardware evidence.

- The new regression against the original implementation failed at the exact
  four-hour boundary with `Some("")`: exit 101;
  `recovery-budget-regression-before-runnable.log`. The first test compilation
  failed because its diagnostic tried to format types without `Debug`; that
  test-only error was corrected before reproducing the behavioral failure.
- The same regression after the repair passed: exit 0, one test covering absent,
  empty and named campaigns before, at and after expiry;
  `recovery-budget-regression-after.log`. Every case preserves the original
  unknown Job and journal bytes and creates no capability use or recovery epoch.
- `python rust/scripts/run-cargo.py clippy -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0;
  `recovery-budget-clippy.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --lib`: exit 0, 396 passed and four existing ignored;
  `recovery-budget-library-tests.log`. Agentd's `--bin arkdeck-agentd` unit
  tests also passed: exit 0, 41 passed; `recovery-budget-agentd-tests.log`.
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1, Windows command
  length limit (OS error 206); `recovery-budget-fmt-all.log`. Both changed Rust
  files passed `rustfmt --edition 2024 --config skip_children=true --check`:
  exit 0; `recovery-budget-rustfmt-changed.log`.
- Source and frozen fixture inventories match their routing manifest. Only the
  two changed source pins were regenerated; fixture bytes and routes are unchanged.
- `sh scripts/check-sdd.sh` through Git Bash: exit 0, no errors or warnings;
  `recovery-budget-sdd.log`. `git diff --check` passed.

The local Cargo commands use the existing fixed session cache and two build jobs.
No local unified gate was run. The complete routed historical/process suites
remain in PR CI because some require the historical Catalog and an isolated
account Runtime. Swift and App checks require macOS and were not run locally;
no Swift, App or contract input changed.

The published Runtime used for read-only inspection came from protected main
`7c7f52b69d2f8b41cd59ea076d11d13a91996753`. After the user restored the board to
Normal/HDC, Runtime observed the original Target at its original binding revision
and produced an immutable Normal hardware observation through `job plan`.
The plan remained `planOnly`, `notDispatched`, `jobAdmitted: false`; its provider
blocker was `normalLoaderIdentity.boundLoaderIdentityMismatch`. The original
unknown Job, Agent execution and all ten original protected files were unchanged.
Raw CLI capture: `normal-common-identity-inspection-20261016-7c7f52b69d2f/`.

Five additional fixed, target-scoped HDC reads used the existing managed server.
They were diagnostics only: CPU information, device-tree serial, boot command
line, eMMC CID and system serial property. The eMMC CID matches the Normal USB
identity. The device-tree serial matches a retained Loader USB serial, while the
CPU Serial differs. Raw bytes and a derived comparison remain local in
`normal-identity-read-only-20261016-hdc/`; no identifiers are copied here.
An earlier capture wrapper rejected the HDC output format before executing any
HDC command; its two CLI status records are retained separately.

The matching device-tree value is a useful lead, not accepted hardware proof.
[Rockchip U-Boot's board initialization](https://github.com/rockchip-linux/u-boot/blob/next-dev/arch/arm/mach-rockchip/board.c)
can obtain `serial#` from vendor storage; its
[device-tree writer](https://github.com/rockchip-linux/u-boot/blob/next-dev/common/fdt_support.c)
and [USB gadget](https://github.com/rockchip-linux/u-boot/blob/next-dev/drivers/usb/gadget/g_dnl.c)
consume that value. These upstream sources explain a possible origin, but do not
attest this board's exact firmware or immutable SoC association. The current
Rockchip profile's fixed CPU identity requirement remains enforced.

The old automation window has also expired. Current observations cannot backfill
its original transition, create a different Target around the unknown Job,
replace its complete-overwrite proof or restart its budget. No operation was
submitted, no device mutation was dispatched, and no `REAL_DEVICE_PASS` or
`SupersedingRecoveryEpoch` is claimed. Real acceptance remains blocked on the
published identity and recovery rules; user confirmation cannot bypass them.

## CI

The preceding implementation PR #2653 merged at the protected-main revision
above after run `38837439367` passed. This follow-up's selected PR checks remain
pending until its own head has completed CI. No green head will be amended merely
to record its later CI result.

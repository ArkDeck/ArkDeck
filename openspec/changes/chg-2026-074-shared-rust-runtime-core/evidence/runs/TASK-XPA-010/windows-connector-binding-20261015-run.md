# Windows ArkForge connector binding — 2026-10-15

Windows census stores a 64-bit attachment topology derived from LocationPaths. The ArkForge observation join previously parsed it as a macOS 32-bit location identifier, so the Windows binding could not select its daemon observation. This increment preserves the existing census and stored target binding, and independently resolves the current attachment through its parent hub and port. Reciprocal USB 2/3 companion queries use the pinned ArkForge connector byte rule. Missing, duplicate, changed, malformed or non-reciprocal observations refuse the join.

The resolver is shared by public/controller materialization, Loader confirmation, and the authority's normal/Loader lineage. Production uses the host observer; synthetic ports explicitly provide their fixture resolver. A five-second caller deadline retains the worker and its synchronous OS handles until completion, excludes a second outstanding observation, and prevents another hub query after cancellation. No RockUSB bulk transfer, device mutation, capability administration or new operation is introduced.

## Local targeted checks

Commands ran through `python rust/scripts/run-cargo.py` with the existing session cache and two compiler jobs. Logs remain in the local `arkdeck-connector-checks` and `arkdeck-connector-checks-2` directories, outside Git.

- Whole-workspace rustfmt target coverage: exit 0 (`fmt-batched.log`); Windows' command-line bound requires the existing batched equivalent of `fmt --all --check`.
- `clippy --locked --workspace --all-targets -- -D warnings`: exit 0 (`clippy.log`), covering platform consumers.
- `test --locked -p arkdeck-platform`: exit 0, 214 libtest cases passed and three existing cases ignored; custom Windows harnesses also passed (`platform.log`).
- `test --locked -p arkdeck-provider-arkforge`: exit 0, 91 libtest cases passed and the lane harness passed (`provider.log`). New cases cover the 64-bit attachment join, zero/multiple/mismatched observations, permit refusal without an independent connector, normal/Loader lineage and preservation of the stored binding.
- HostStore Loader confirmation and bundle import: 3 + 2 cases passed; post-flash alias: 2 passed. Direct current-Catalog `flash_plan` and `flash_run` fixture targets failed with their historical c6 Catalog expectations (1 and 11 failures respectively); these existing targets remain routed to the historical view by CI. No fixture, Catalog, route or assertion was changed. The `recovery_epoch` target is macOS-only and ran zero cases on this host. Logs: `hoststore-flash.log`, `hoststore-remaining.log`.
- `test --locked -p arkdeck-agentd --test spawning flash_`: exit 0, 20 passed, three existing fixture-entry cases ignored (`agentd-flash.log`). Includes primary/alias execution, complete-overwrite recovery and preserving unknown outcomes.
- Final Loader diagnostics: `test -p arkdeck-provider-arkforge --lib loader::tests`, exit 0 (4 passed; `arkdeck-connector-final-loader-test.log`).
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings, 121 acceptance IDs (`arkdeck-connector-sdd-2.log`); the first sandboxed Git Bash launch was unavailable.
- `python rust/scripts/test_catalog_test_views.py`: exit 0, 31 passed (`test-routes.log`). Source inventory includes the new modules; routes and frozen fixtures are unchanged.

A separate read-only host diagnostic resolved the currently attached Normal-mode board's 64-bit attachment to a physical connector. The released signed ArkForge bundle also started under the existing installed ArkDeck Runtime, which completed its own restart and returned healthy. These observations diagnose integration only: they are not Runtime hardware acceptance, and no new flash job ran in this increment. Raw observations remain local.

## CI

The dependency PR is #2644. Its first run 38712440818 compiled successfully but refused a stale source inventory before the routed tests; the two source digests were corrected. Run 38713739746 is validating that fix; Linux workspace and contract parity have passed, while the remaining hosts were still running at this record's creation. This connector increment has not yet been pushed. Current-head results will be recorded in a follow-up without amending an already-green head.

Windows GJ-4 acceptance remains pending the merged Runtime, fresh Runtime-owned admission and an actual full-restore/postflight result. This increment does not promote ArkForge or ArkDeck production maturity.

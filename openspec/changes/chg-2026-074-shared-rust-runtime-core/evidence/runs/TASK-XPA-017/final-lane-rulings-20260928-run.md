# TASK-XPA-017 — maintainer rulings of 2026-09-28 recorded, dashboard refreshed on `2e687ca82` (macOS, 2026-09-28)

Documentation only. No code, contract input, `tasks.md`, lock or traceability file changes; nothing ran
against a device, the installed Runtime or the account's state.

## What changed

- `docs/design/cross-platform/macos-rust-cutover-runbook.md`: a new opening section records the
  maintainer's 2026-09-28 rulings on appendix B (notarization required, overriding Q11; the Rust
  baseline and a soak rerun are not window conditions; the ArkForge digest-domain decision; no Swift
  transitional release and no separate Swift rollback build; a DMG ships; real-device acceptance last,
  after all software including the Swift retirement) and the defaults applied to the remaining items.
  Step 2 now passes the release's ArkForge.bundle explicitly; step 7 (the rollback drill) is marked not
  performed per XPA-AC-9; the stale ArkForge pin in P7 is corrected to `c1dc0553`.
- `design.md`: the design document pin moves from blob `fdd61022` (r11) to `2e9ad45a`, sha256
  `a1fcfdea…`, the document as it stands on `main` after five later edits (including #2219 and #2274).
- `evidence/macos-remaining.md`: header, dashboard row and supplements recounted at `2e687ca82`, the
  rulings and the software gaps found on 2026-09-28, and a History entry.

## ArkForge digest-domain decision (F1/F2)

Delegated to the agent by the maintainer. ArkDeck follows the pinned ArkForge revision
`c1dc0553b42627581583abfba3fec34d13343282`: `arkforge/v1/usb-topology\0` for the USB topology digest and
`arkforge/v1/admission-device-facts\0` for the admission device-facts digest
(`arkforge-core/src/digest/mod.rs:92-93` at that revision). The retired `device-facts` domain is not kept.
Grounds, checked read-only: neither product has a release; durable state and recorded oracles hold raw
`usbTopology` values and no digests; no normative OpenSpec text fixes the domain. The code change is a
separate PR under maintainer review because it changes destructive admission facts.

## Counts at `2e687ca82`

The dashboard's PYCOUNT (ref updated to this pin): 105 / 105 routes, 199 parser names, 140 / 256
registered feature names, 16 ClientKit facades and 0 in Workflows, 0 App imports of `ArkDeckWorkflows`,
0 / 6 Swift targets deleted, `MATERIALIZED` 28 / 30. `count_operations.py` from
`dashboard-refresh-20260926-run.md`: 17 / 30 isolated, 25 / 30 either composition, all citations verify;
`workspace.run-tests@1` adds one production-composition run (`workspace_tests_process.rs`, #2265), 26 / 30.
Registry leaves answered: 209 / 209 by reading the parser (`runtime_update::serves` and
`update_feed::answer` dispatch ten leaves before the positional match); not re-measured with a binary.

## Local targeted checks

- `sh scripts/check-sdd.sh`: exit 0, 0 errors, 0 warnings, 121 acceptance IDs
  (`/private/tmp/arkdeck-s0-check-sdd.log`).

Not run: any build or test (documentation only); `count_cli.py` against a built CLI (its parse of the
removed `blocked_leaves.rs` needs adapting; the release-candidate check measures the leaves).

## CI

Pending.

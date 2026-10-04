# Observe the installed legacy facade in the release-mismatch negative case

The installed launchd owner is the signed `arkdeck-facade`, identifier
`com.arkdeck.agentd.facade`. Its enclosing `ArkDeckAgent.app` identifies the
Swift daemon as `com.arkdeck.agentd`. The negative harness verified both the
bundle and its live owner against the latter identifier, so it failed with
`codesign exited 3` before launching the release App. This reproduced on the
reference Mac with the signed 0.1.0 build 2 RC from release run 36656654187.

Only the negative harness now recognizes the two exact executable identities.
It verifies the live owner's own version/build and CodeDirectory hash before
checking whether that same identity matches the App's version/build. An
unrecognized executable or failed identity check is still a failure, not a
release mismatch. It verifies live code again after the two App refreshes.
The result distinguishes `pre-cutover-legacy-facade` from
`installed-daemon-release-mismatch`. The App transport requirement, pure-Rust
positive case and foreign-client case are unchanged; the retired facade has
not been admitted back into the product.

## Local targeted checks

- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/ci/test_installed_spk8_negatives.py`:
  exit 0, 14 tests; `/private/tmp/arkdeck-macos-closeout-20261004/spk8-unit.log`.
  Covers the live facade and daemon identities, owner/code drift, refusal of a
  same-release owner, App refusal wording, a hanging App and foreign-client
  dispatch. The printed opt-in skips are assertions within the host tests.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `fmt-spk8.log` in the same local directory. `sh scripts/check-sdd.sh`:
  exit 0, zero errors/warnings; `sdd-spk8.log`. `git diff --check`: exit 0.
- Actual `installed_spk8_negatives.py version-mismatch`, pinned to the verified
  RC2 App, against the unchanged installed build 1 facade: initial exit 1
  (`codesign exited 3`); corrected harness exit 0, `PASS`,
  `acceptanceScope: pre-cutover-legacy-facade`. The real App reported the
  release mismatch and update remedy on both refreshes and exited. Raw records
  are under `/private/tmp/arkdeck-macos-closeout-20261004/rc2-version-mismatch`
  and `rc2-version-mismatch-fixed`. Neither run installed or restarted Runtime,
  changed its records, or dispatched a device operation.
- RC2 download integrity was verified against independently recorded source
  `66b7474baac9c9e175f7125c11ca618c8fd1dc44` and DMG SHA-256
  `84e3e94df5d03affd735211e02445934ef2f4ef0f14505c0e4ce66a3f714942c`.
  `stapler validate`, Gatekeeper assessment and the App/CLI/daemon executable
  digest and team/identifier signature checks all exited 0. This older RC is
  diagnostic material, not the final build 3 acceptance candidate.

This is host/App negative-case evidence, not positive installed pure-Rust
acceptance or `REAL_DEVICE_PASS`. Swift and Rust product sources are unchanged,
so no Swift build, Cargo suite or device acceptance was run for this fix.

## CI

Pending the implementation PR. No local full unified gate was run.

## Independent release and installation blockers

Release run 37075826611 attempts 2 and 3 still fail at `notarytool history`
with HTTP 403, a required Apple agreement missing or expired. The account
holder is handling it; no credentials or agreements were accessed by the agent.

The RC2 daemon's one-shot, unlocked `--cutover-preflight` read on 2026-10-04
returns `clear: false` with one `retainedSessions` / `recordUnreadable` block:
the previously documented historical Rockchip Session still lacks a Manifest
and no failed publication accounts for it. Counts are 67 Jobs, 61 agent
executions and 29 capability uses; 64 terminal Jobs, three parked Jobs and two
unknown uses are carried over, not themselves blockers. Original records were
preserved. Raw local output: `rc2-preflight-20261004.json` in the directory above.
No locked preflight, service switch, identity refresh, recovery or device run
was attempted. The current Rust CLI reads the installation configuration as
ready, but its current contract does not negotiate with the historical daemon;
an older CLI's configuration/protocol refusals are not new installed-state
defects.

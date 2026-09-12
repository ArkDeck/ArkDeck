# HDC registration owner — macOS, 2026-09-11

Integration base: protected main `b315f371`. This independently reviewable
capture and registration library phase preserves the existing owner format.
Integration with the DevEco registration RPC slice and the Rust CLI/Runtime
connection merged in PR #1860 at `d00e4ec`; see [the RPC validation](hdc-rpc-run.md).

The Rust storage owner captures the HDC executable and its fixed optional
`libusb_shared.dylib` dependency into its own private staging directory. It
holds source descriptors, verifies bounded Mach-O roles, preserves quarantine
bytes, compares source/copy identities and invokes existing native signature
inspection without executing the captured files. Immutable publication uses
exclusive rename; it never replaces or removes existing registered content.
Only exact newly created staging files can be removed during cleanup.

The owner initializes the existing frozen Bootstrap indexes under the shared
lock. Missing indexes beside retained state, corrupt metadata, concurrent lock
holders and exhausted record/content/staging quotas refuse registration. It
preserves existing selection metadata, references and registration timestamps
on duplicate registration. A retired record stays retired. Native content
published before an interrupted index transaction is retained for inspection;
uncertain publication never causes an automatic retry.

## Completed host checks

- Platform integration tests: 7 passed with real native signature inspection,
  bounded byte/quarantine copies, immutable destination preservation, inode
  replacement refusals and source/staging/link/size failures. The private rename
  interruption test passed and preserves published content on an unknown result.
  Logs: `/private/tmp/xpa012-hdc-capture-tests.log` and the platform agent's
  retained targeted unit output.
- Owner tests: 4 passed for initialization, corrupt/retained state, held locks,
  actual native registration, duplicate/restart reads and both content/index
  publication interruption boundaries. A separate test passed for preservation
  of existing selection metadata and refusal of retired records. Selection here
  is a preservation fixture, not an installed service selection or execution grant.
- An explicit real HDC plus sibling-library registration passed. The retained
  source was read from the installed immutable HDC registration and was not
  written or executed. Rust produced the same content-addressed identity,
  preserved source bytes and successfully repeated and reopened the new record.
  Native signature and published-profile matching were computed from the actual
  content. Log: `/private/tmp/xpa012-hdc-registration-native-source.log`.
- Actual Swift strict-decoder/native readback passed: 1 test, 0 failures and
  0 skips. The complete Rust registration result matched production Swift native
  inspection, with all existing registry bytes and recursive metadata unchanged.
  See [the native readback record](hdc-capture-native-swift-readback-macos-20260911.md).
- Warnings-denied Clippy passed for platform, hoststore and daemon targets.
  Log: `/private/tmp/xpa012-hdc-registration-clippy-r2.log`.

The actual HDC fixture is retained at
`/private/var/folders/kq/6vwvyjds2nx0tc3g0xt_19br0000gn/T/hdc-registration-a64284818d8942feeca930046eb4f883`.
Its reference is
`tool:sha256:adcf3a3c1fa05fdee3ca2523986bfcc128e8a2106c1ece3b7e018f81b6370f35`.
The source test is explicitly opt-in via `ARKDECK_HDC_REGISTER_SOURCE`; absence
is reported as SKIP. Ordinary macOS native owner tests use `/usr/bin/true` only
as a real signed Mach-O storage sample, never as HDC execution evidence.

## Final repository validation

The required unified gate passed on protected main `b315f371` with
`--merge-base --include-worktree --run-local`: common checks, design-system,
full selected Swift lanes, Rust formatting and warnings-denied Clippy, workspace
tests, published/candidate contracts and existing actual process checks, cargo
deny and cargo vet (26 fully audited). The planner selected `app: false`; no
App build or UI/device acceptance is claimed. Explicit native source and Swift
readback opt-in tests are recorded above; default runs report those as skipped.

Log: `/private/tmp/xpa012-hdc-register-full-gate.log`, SHA-256
`341ab2989610b3bcce7b2dfd5bdeccea3c30e0237e49381a373ca2710f291b7c`.
Contract recordings:
`rust/target/readonly-check/5d7b826049df4e819201414fe35f8cc1`.

## Integration status (updated 2026-09-12)

Typed HDC registration RPC, the Rust CLI consumer, actual producer-derived
contracts and isolated process validation merged in PR #1860. The Swift HDC
registration consumer retains its existing in-process path. This is isolated host work;
installed activation, Session deletion, Runtime authority and device acceptance
are not completed by these tests. TASK-XPA-012 remains in progress.

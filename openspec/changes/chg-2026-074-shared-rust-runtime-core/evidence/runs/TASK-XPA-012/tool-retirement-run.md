# HDC and DevEco metadata retirement — macOS, 2026-09-11

Historical local validation from commit `3abe5c55`; current integration and
verification are in [tool-list-retirement-run.md](tool-list-retirement-run.md).

Integration base of that local run: protected main `b315f371`. TASK-XPA-012 remains in progress.
The existing `runtime tool remove` CLI leaf now reaches a typed Runtime owner
for both registered tool families. No source content is deleted, no selection or
reference is acquired/released, and no executable or device job is launched.

## Observable behavior

Both owners hold the shared Bootstrap lock, strictly decode their indexes,
resolve the exact reference, and require expected generation `1`. HDC verifies
native content before returning an already-retired receipt; DevEco preserves
Swift's existing early return for retired metadata without rereading its external
source. Available entries are verified before reference protection is evaluated.
Only an unreferenced entry becomes removed/generation 2. Repeated generation `1`
returns the same receipt without index publication; generation `2` is refused.

HDC retains its immutable registered content. DevEco's `contentRetained: false`
means its external application is not retained by this registry; retirement does
not delete it. Every reference and the selection/pending/outcome ledger remain
unchanged. A real HDC write uses the same existing Swift legacy `/1` to `/2`
normalization; a repeat never upgrades an index. DevEco's `/1` format is unchanged.

DevEco identity and read-overflow tags preserve the existing platform I/O kinds
while allowing its retirement owner to retain Swift's `fileIdentityChanged` and
`inputTooLarge` errors. HDC continues to map its verification failures to
`recordUnreadable`. The CLI preserves the 11 published protocol/owner entries
only with the exact owner proof where required. Lost transport or inconsistent
receipts remain uncertain, with no automatic replay or local-store fallback.

Only `runtime.tool.remove` is added to the control method set. The 99 existing
schemas retain their published shapes and provenance; only the shared registry
identity changes. The new result reuses the full existing Tool inspection union.
Actual Swift frames, including both tool families and current health, produced
the new corpus. No unmerged schema is used to advance a published Rust pin.

## Verification completed so far

Swift's default producer run passed five tests with one explicit-input skip.
The separate native producer then passed with zero skips: actual signed system
executables exercise the registered HDC-shaped content, and the real
`/Applications/DevEco-Studio.app/Contents` supplies DevEco metadata. System
executables are not claimed as HDC device-acceptance evidence and are not run.
The test writes only a fresh temporary registry and preserves external sources.

Rust retired both available records in that exact temporary registry, matched
Swift-derived complete receipts, reopened, and verified repeat and stale-generation
behavior. Index bytes were unchanged on retries; non-index bytes, inodes, modes,
times and actual DevEco sealed-role facts remained unchanged. Swift read back both
Rust results and repeated them without publication. The Rust receipt is
`/private/tmp/tool-retirement-rpc-49d21be5-7bd0-4001-b620-d04109f2cb85/actual-rust-retirement.json`,
SHA-256 `f23ab164e177e5351e890017b5dd55a6b6915bc632a2143cb2afd16ebbcd7e7d`.

Seven focused owner tests, 22 candidate-100-method CLI tests, warnings-denied
Clippy and formatting passed. CLI tests consume both actual producer receipts,
exercise all 11 error/proof mappings, and test uncertain transport with an
in-memory no-replay fixture that is not native evidence. Logs:

- `/private/tmp/xpa012-tool-retirement-swift-oracle.log`
- `/private/tmp/xpa012-tool-retirement-swift-native.log`
- `/private/tmp/xpa012-tool-retirement-rust-native.log`
- `/private/tmp/xpa012-tool-retirement-reverse-swift.log`
- `/private/tmp/xpa012-tool-retirement-cli-tests.log`
- `/private/tmp/xpa012-tool-retirement-cli-clippy.log`

Actual frames are retained in `tool-retirement-native-frames-macos-20260911/`.
Actual process checks passed with an empty registry (9 control exchanges),
native Rust CLI (14 exchanges), and Swift CLI against Rust daemon (14 exchanges).
Each native process test retires both families in its own fresh registry copy,
verifies exact target-only index changes, restart retries and retained source
bytes, then checks lock, malformed-request and corrupt-index refusals. Logs:
`/private/tmp/xpa012-tool-retirement-process-empty.log`,
`/private/tmp/xpa012-tool-retirement-process-native.log`, and
`/private/tmp/xpa012-tool-retirement-process-swift-cli.log`.
The final unified local gate passed common checks, design-system checks, Swift
tests, App build-for-testing, published/candidate Rust contract checks, and
dependency deny/vet checks. Log: `/private/tmp/xpa012-tool-retirement-full-gate.log`. This phase changes no App
presentation, so App UI assertions are not required. Installed owner cutover,
remaining host-store writes and GJ-1 acceptance remain pending.

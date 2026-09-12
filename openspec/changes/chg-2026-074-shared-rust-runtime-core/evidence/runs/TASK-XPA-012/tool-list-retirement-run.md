# Tool inventory and metadata retirement — macOS, 2026-09-12

Integration base: protected main `d00e4ec0617868b7f35ebbc5a7c566ff07d8f4c6`.
PR #1860 already delivered Rust HDC registration; that path is preserved.
This is one bounded TASK-XPA-012 phase, not completion of the Task or migration.

## Product behavior

`runtime tool list` now uses Rust CLI → typed Runtime RPC → Rust owner to merge
HDC and DevEco records. The existing `toolRef:asc` ordering, immutable pages,
query-bound opaque cursors and restart readback are preserved. Current registry
and native content validation precede page-size and cursor validation. Reclaimed
snapshots return `invalidCursor`; there is no implicit restart or CLI registry
fallback. Empty initialization belongs to the locked Bootstrap owner and refuses
missing indexes beside retained state.

`runtime tool remove` uses the same boundary for exact-reference metadata
retirement. Available generation is literally `1`; successful retirement returns
generation `2`, repeating generation `1` returns the same receipt without writing,
and generation `2` is refused. Referenced entries cannot retire. HDC verifies its
retained content even after retirement; retired DevEco metadata preserves the
existing early return without rereading its external source. Neither family
deletes content, changes references, selects a tool or launches an executable.

The Runtime and CLI preserve `outcomeUnknown` if a possibly published retirement
has no bounded, conforming receipt. A real socket proxy drops an actual successful
owner response and checks one owner call and no reconnection/replay. This also
covers both families through the Swift CLI.

The Swift producer and consumers keep existing Bootstrap business semantics.
The candidate adds only `runtime.tool.list` and `runtime.tool.remove` (104 methods);
the published Rust pin is the reviewed 102-method `d00e4ec` input. Existing method
schemas receive only the shared identity update, apart from current health
recordings. New Tool results reuse native inspection-recorded optional fields so
the permitted fixtures do not narrow dependency, trust or selection projections.
Every committed producer frame is unedited.

## Validation

All writes use newly created temporary registries. Signed system executables are
native HDC-shaped storage samples and are never run or claimed as device evidence.
DevEco verification reads `/Applications/DevEco-Studio.app/Contents`; it does not
modify the application or installed Bootstrap state.

- Rust tool owner checks: 22 passed, including locks, namespace replacement,
  validation order, missing-index guards, generation and every reference kind.
- Candidate CLI and typed control checks: 16 and 12 passed. The existing HDC
  registration, Bundle list and Bundle retirement cases remain covered.
- Native Swift producer: 13 tests, 2 explicit Rust-readback inputs initially
  skipped, no failures. Both skipped cases were subsequently supplied real Rust
  outputs and passed as part of 127 strict readback/CLI/contract tests.
- Rust reads the actual Swift registry, retires both families and reopens it;
  Swift reads those exact receipts and repeats without publication. Native
  content bytes, inode/mode/time facts and actual DevEco sealed-role facts remain
  unchanged. Rust/Swift cursor readback covers the merged retired inventory.
- Real Rust and Swift CLI/daemon process checks cover empty/mixed lists, all
  continuation pages, restart, invalid/reclaimed cursors, held locks, version
  conflict, retained references, corrupt metadata/content and lost publication
  responses without replay. Each check retains its isolated root and raw frames.
- Formatting and warnings-denied Clippy pass. The repository gate passed common
  checks, 2,625 parallel Swift tests plus 6 serialized tests, App build-for-testing,
  83 design-system checks, Rust published/candidate views and dependency policy.
  Its read-only harness initially expected an unimplemented-method refusal for
  Tool list; the correct unconfigured-owner result is `operationUnavailable`,
  matching Bundle list. After that one-line harness fix, the Rust tail passed in
  `unified-gate-rust-resume.log`. Source hashes verified that the previously passed
  Swift/App/common/workspace inputs were unchanged, so their results were reused.

Python is fixed to `/private/tmp/xpa012-hdc-rpc-venv/bin/python3`, verified with
`PyYAML==6.0.3` and `jsonschema==4.26.0`. `ARKDECK_PYTHON` and `PATH` keep every
subcheck on that interpreter and the pinned Rust toolchain. Shared Swift/App
builds use the repository wrappers serially.

```sh
"$ARKDECK_PYTHON" scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

Logs and disposable candidate builds are retained in
`/private/tmp/arkdeck-xpa012-stage-20260912/`, including `swift-native.log`,
`swift-readback-contracts.log`, `native-retirement-rust.log`, `native-list-rust.log`,
`process-*.log`, `unified-gate.log`, `unified-gate-rust-resume.log` and the combined
`unified-gate-result.json`. All 143 actual responses in the eight unedited
recordings passed strict result/error schema validation. Production recordings are in
`tool-list-retirement-native-frames-macos-20260912/` beside this report.

## Scope and preserved work

The original `/private/tmp/arkdeck-xpa012-tool-list` and
`/private/tmp/arkdeck-xpa012-tool-retirement` directories remain untouched,
including retirement commit `3abe5c5529df99882d919784be1912d9a347f442` and all 13
modified/untracked list files (verified by SHA-256). Their source changes were
integrated into current main without overwriting newer HDC or Bundle behavior;
generated products were rebuilt from the merged current sources.

All changed paths already belong to TASK-XPA-012 on this base. No Allowed paths
or Scope-Extension trailers are added. The older three retirement trailers are
not carried forward. Historical local retirement evidence is retained separately.

Tool selection, installation, HDC execution, Bundle capture, Session deletion,
installed Runtime cutover and Windows implementation are outside this phase.
No UI assertion is required because App presentation is unchanged. Previously
gated hardware/selected-tool tests remain gated, and no nightly wait is added.
This phase stops after PR delivery and required CI; maintainer review/merge,
remaining TASK-XPA-012 work and macOS migration completion remain outstanding.

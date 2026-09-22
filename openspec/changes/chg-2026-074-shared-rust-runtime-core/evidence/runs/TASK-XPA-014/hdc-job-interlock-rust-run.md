# TASK-XPA-014 — Rust HDC final Job admission interlock

Base: protected main `5d176172b` (#2101), checked on 2026-09-22. No open PRs
at that check; required status contexts were `guard` and `swift`. This is one
C2b implementation slice, not completion of C2b, M1 or G5, and not hardware
evidence. The ADR-0009 ruling recorded on 2026-09-19 permits porting the existing
Swift behavior; the older pending-ruling text is historical.

The Job owner now provides an exclusive HDC lifecycle lease. It freezes new
admission before reading its own current-Job census, refuses active Jobs,
unknown outcomes, cleanup residue and unreadable records, and releases on a
normal error return. A panic poisons the gate rather than silently reopening
admission. No RPC accepts an interlock flag or a caller-provided census.

`JobAdmitter` checks after idempotency lookup and before materialization, then
again after materialization. Its final shared lease spans authority issuance,
durable admission and initial publication. Concurrent ordinary submissions can
still proceed; a lifecycle never waits while holding an incomplete inventory.
Direct `JobStore::admit` also takes the shared lease. The census includes
resident recovery records that are ahead of disk, so their uncertainty cannot
be hidden by a terminal durable record.

Tests cover submission through both normal and Agent admission, direct-store
admission, competing lifecycle ownership, both orders of the materialization
race, active/unknown/future/unreadable records, terminal cleanup residue,
resident uncertainty, normal release and panic poisoning. All use isolated
host stores; no device transport is opened by these added tests.

Still required: compose this lease into the Rust console challenge/receipt and
lifecycle driver, retain it until durable outcome/recovery, port the lifecycle
audit and supervisor/recovery wiring, and establish trusted USB relations and
the deployment conditions for formal pure-Rust GJ-1 acceptance. No installed
Runtime or LaunchAgent was changed.

## Local targeted checks

Checks use `CARGO_BUILD_JOBS=2` and the worktree-specific
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.

- `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0,
  `/private/tmp/arkdeck-1330-cli-build.log` (process-test prerequisite).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak`:
  exit 0, 541 passed, 0 failed, 14 existing ignored cases (not counted as passes),
  `/private/tmp/arkdeck-1330-interlock-tests-final.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0, `/private/tmp/arkdeck-1330-interlock-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0,
  `/private/tmp/arkdeck-1330-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings,
  `/private/tmp/arkdeck-1330-sdd.log`.

No full local unified gate, performance measurement or hardware acceptance was
run. Initial attempts exposed a noncanonical test temp
path (fixed), sandbox socket restrictions (rerun outside the sandbox), and the
existing daemon process tests' CLI-build prerequisite (built `arkdeck-cli`).
The new future-state case correctly expects `recordUnreadable`, since the Rust
record decoder rejects unknown states before a census can classify them.

## CI

PR #2102 merged as `c015bd15b`. Swift CI run `35695314850` passed its
`swift` aggregate and all four selected Rust jobs; App/Swift/UI interaction
jobs were skipped. SDD Guard runs `35695314763` and `35695375866` passed.
These results validate the interlock slice, not hardware acceptance.

Main's green Performance lanes run `35653709244`
executed `harness-tests` and `nightly` but **skipped** `soak`; it does not clear
the earlier soak failure. Main's slow UI run `35534480398` failed the
presentation-only package import assertion. These remain separate work in the
macOS migration goal.

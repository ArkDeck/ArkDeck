# TASK-XPA-016 — optimize `sha2` in the dev profile so a debug daemon observes its HDC server

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane B, a build-profile follow-up to R2
(#2004). Host measurement only (POL-VERIFY-001, POL-MODE-001). Base: protected main `74c3b2b1`.
No source, contract, Catalog, entitlement, `openspec/specs` or constitution change; `Cargo.lock`
unchanged.

## Why

During today's development-root GJ-1 run (A lane, option A), the isolated Rust daemon — built
with the dev profile — answered `runtime.hdc.status` with `availability: unknown` /
`hdc.identityObservationTimedOut` for the managed server on `127.0.0.1:8710`, and
`doctor --deep` reported `hdc.identityUnavailable`. The GJ-1 session timed the observation
against the installed server (registered 3.2.0f `hdc`, 6.2 MB, 673 processes on the host):

| Build | `VerifiedTool::open` | `LoopbackServerLease::acquire` | `CommandlessIdentity::observe` |
| --- | --- | --- | --- |
| release (load 28–34) | 13–19 ms | 45–62 ms | 55–66 ms |
| dev (load 16–27) | 345–606 ms | 660–800 ms | 986–1098 ms (4 of 5 past the 1000 ms deadline) |

The time is the unoptimized SHA-256 of the tool, computed three times per observation (the pin
at open and the two revalidations inside `acquire`); the two process scans take tens of
milliseconds. The deadline is Swift's `HDCSupervisorObservationProbeCatalog.timeoutMilliseconds`
and stays.

## What

`rust/Cargo.toml`: `[profile.dev.package.sha2] opt-level = 3`. Only the `sha2` package is
compiled optimized in dev (and test) builds; every check, digest and code path is unchanged,
and release builds are untouched.

## Measurement (this host, dev profile)

A throwaway test (not committed) opened a 6.2 MB private file as a `VerifiedTool` and
revalidated it twice — the hashing one observation does — five rounds each:

| | open | open + 2 × revalidate |
| --- | --- | --- |
| before | 313–386 ms | 930–1123 ms |
| after | 19–25 ms | 56–73 ms |

## Local targeted checks

- `cargo build --workspace --all-targets --locked` (CARGO_BUILD_JOBS=2): exit 0.
- `cargo test -p arkdeck-platform -p arkdeck-provider-hdc --locked`: exit 0, 302 passed, 0 failed,
  4 ignored.
- `cargo fmt --all --check`: exit 0.

## CI

Pending (this PR).

## Not run

The observation against a real HDC server with the new profile (the GJ-1 session rebuilds its
debug daemon and reruns); any device.

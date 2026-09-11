# Read-only Rust CLI leaves — 2026-09-11

Final integration base: approved main `b315f371`.

The Rust CLI now forwards `operation describe|example --operation <reference>` and
`job status --job <id> [--timeout <duration>]`, `job list`, `job show`,
`job evidence` and `job timeline` to
the current typed Runtime methods. Job list preserves the current pagination,
projection and four string filters; Job show preserves result/publication and
unknown-outcome semantics. It validates descriptor identity and Job status/publication/nextAction
relationships before rendering the standard CLI envelope. A successful read
never turns an unknown execution outcome into success or replays an operation.
No polling loop or secondary local catalog fallback is introduced.

The Rust control owner now serves operation.describe from the compiled published
Catalog and its actual availability projection. All 24 current Swift descriptor
recordings compare exactly; all 30 compiled descriptors pass the current result
validator. Discovery keeps every unregistered Provider unavailable and cannot
admit execution. The Rust job.status backend remains unavailable until the Job
owner is delivered; the CLI can consume the existing Runtime method.

The actual Job producer refuses waitingForHuman records and only emits wait,
readResult or reconcile nextAction. The humanAction producer belongs to the
agent-execution owner, not job.status; no protocol/schema change is needed.

Final targeted verification passed 20 CLI resource tests in each of the current,
isolated published and isolated candidate views, plus 10 client deadline/no-replay
tests, warnings-denied Clippy and diff checks. Controlled-endpoint tests invoke the actual executable and
cover success, backend refusal and malformed response consumption. Their fixture
messages are protocol tests, not proof of a replaced backend or hardware pass.

The actual Rust CLI and daemon process check passed with 116 control responses,
12 CLI envelopes and 107 valid requests. It covers descriptor equality across
CLI/wire, missing references, invalid parameters and unknown Job refusal. Every
record was schema-checked after the processes finished. Recordings are under
`rust/target/readonly-check/3a5dc01479064392a8488e09f07c8acd` (local retained output).
The current Swift CLI and Rust CLI also consumed the same isolated Rust daemon
through an explicit socket: all 30 descriptors and all 30 example requests
compared exactly. Example output comes verbatim from the Runtime descriptor.
This is a host-only process check, not installed Runtime or device acceptance.

Parser samples are packaged under `rust/tests/fixtures/current-cli-argv` so both
isolated contract views can compile them. The check runner requires exact byte
equality with the current Swift argv corpus before taking its source snapshot.

Every added Job read uses the default 30-second total timeout (bounded by 24 hours
when explicitly configured). The timeout shares one absolute deadline across health, request
and every IO call; expiry makes the client unusable and produces `clientTimeout`
without a snapshot. Native connection/authentication elapsed time consumes the
budget, but this slice does not add interruption inside those synchronous platform
calls. Delayed health plus status, partial slow frames and zero replay are tested.

The Job list producer was recorded through the actual Swift handler with ledger
fixtures, including filtered results, pagination, thread identity and the existing
large-timeline snapshotPages result. The schema adds only the four actual string
filter keys; integer/null rejection recordings remain test evidence and do not
widen the typed request. The existing five parameter schemas and contract identity
are unchanged. See [job-list-oracle-macos-20260911.md](job-list-oracle-macos-20260911.md)
for the actual producer commands and retained raw frames.

Candidate checks consume 20 actual
job.list and 13 job.show producer results, three filtered/continuation/large
timeline CLI successes, and reject a wrong-thread page without extra requests.
The published view rejects unsupported filters before connecting: protocolMalformed,
no result and no accepted socket connection. Each leaf validates its compiled
request schema before transport; this check is local to the added CLI leaves.

The evidence consumer preserves all 15 actual Swift producer success results. It
preserves the closed evidence fields while keeping status and blocker strings
open. A successful query emits its result before exiting: verified returns 0,
resultNotReady returns 75, and other statuses return 2. Wrong identity or malformed
evidence produces a failure envelope. Tests also cover a shared expired deadline
without a result or replay.

The actual timeline producer supplement covers Unicode long-entry segmentation,
continuation from partIndex 1, immutable snapshot continuation, empty timelines
and cursor binding to method, Job and page size. It retains all old corpus rows
and appends 16 actual timeline frames; the schema only adds the existing
invalidCursor error code. The producer test and four schema tests passed. See
[job-timeline-oracle-macos-20260911.md](job-timeline-oracle-macos-20260911.md).

The timeline consumer preserves all seven actual success rows, including a page
starting at partIndex 1. It validates canonical Int64 indices, contiguous parts
and the 64 KiB UTF-8 segment limit before returning one page. The published
view retains its original corpus and rejects unpublished invalidCursor responses
as protocolMalformed; the candidate maps only a proven preAdmission/zero-dispatch
refusal to invalidCursor. Unproven responses remain internalError.

The final unified gate passed for this integrated product source on base
`f71ff8b8`: common checks, 83 design-system tests, full Swift tests (2595 parallel,
1 serialized race and 5 scale tests), Rust workspace and Clippy, published/candidate
conformance and real owner processes, cargo deny and cargo vet (26 fully audited).
The planner did not select App build for this final diff; no App or device
acceptance is claimed. Log: `/private/tmp/xpa018-readonly-main-full-gate.log`,
SHA-256 `6c9142f8d35812c547abd8102c631c2a621d67b63cd293667c9de08c2aa76a36`.
Recordings: `rust/target/readonly-check/35756191206e44d5b6f73d812d029ea9`.

Subsequent integration of main `b315f371` changed only its Swift CI workflow cache
key and corresponding workflow tests; no product source or contract input changed.
The workflow tests and common checks were revalidated after that integration.
The existing functional passes remain applicable. TASK-XPA-018 full parity,
CLI retirement and GJ-1..5 acceptance remain incomplete.

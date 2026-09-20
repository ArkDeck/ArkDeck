# TASK-XPA-018 — `job watch` and the registry's output modes (macOS, 2026-09-20)

TASK-XPA-018 remains in progress. Base: protected main `5c9075c5` (#2095); no stack. Nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001): the Runtime under test is the fake one the CLI tests serve
recorded answers from. No Swift source or test, control schema, corpus, Catalog, entitlement,
`openspec/contracts`, `openspec/specs` or constitution change.

The fourth leaf of the audit's category 2 group that reads over routed methods, and the first that
streams: it is also what makes `--output jsonl` mean something, since `job watch` and `job wait` are
the only two leaves the registry publishes it for.

## What changes

- **`--output` is judged by the leaf.** The option's own grammar is the registry's enumeration
  (`human|json|jsonl`); which of those a leaf serves is its published `outputModes`, and a mode
  outside them is `invalidOption` (64) naming the leaf, as Swift's registry answers:
  ``​`job watch` --output must be one of human|jsonl``. The parser refused `jsonl` for every leaf
  before this, which was right for 207 of the registry's 209 leaves and wrong for these two.
- **`arkdeck job watch --job <id> [--after-cursor <cursor>] [--page-size 1…1000] [--timeout 30s]`**
  (Swift `RuntimeCLI.emitJobEventObservation` for `watch`) follows durable Job events until its own
  deadline or an interruption, and never runs or cancels anything:
  - **Its grammar is the handler's**, as Swift's is: an exact Job identity (`invalidInput`,
    `an exact Job identity is required`), a page size in 1…1000 (`invalid event page size`), a
    bounded opaque cursor (`invalidCursor`), and a bounded duration (`timeout must be a bounded
    duration`).
  - **Each page is proved before any of it is delivered** (`job_events::validate`, already the rule
    for `job events`), then the stream's own checks: a high-water revision that never moves
    backwards, a row identity that is either the replay of one already delivered — skipped — or new
    at the next position, a first row that is the retained origin when no cursor was given
    (`eventHistoryUnavailable`, exit 75, with `earliestRetainedPosition`), and a page that actually
    advanced the delivered stream. Each is `recordUnreadable` (exit 2) with Swift's message.
  - **Rows are written as they arrive**, and the cursor advances with each row delivered rather than
    at the end of a page, so a stream that fails mid-page resumes from the last row a caller saw.
  - **`--output jsonl` writes one `arkdeck.cli.event/1` document per line**: the row's own fields
    plus the command, the correlation and a sequence that counts every line. The stream always ends
    with one terminal line — `type: "terminal"`, the exit code, the error, and `lastCursor`, which is
    null until a Runtime event was delivered, because a cursor is a resume point and inventing one
    would say a caller can continue from somewhere it never was (§8.3).
  - **The end is always a failure**, as Swift's is: `clientTimeout` (75) at the deadline — a request
    that runs into it and a check between rows both answer it — `clientInterrupted` (130) on a stop,
    and `runtimeUnavailable` only after Swift's two retries 100 ms apart. Every one of them names
    the Job and the cursor it would resume from.
  - **Without `--timeout`** the observation is bounded at 30 s from its first request, never
    renewed, which is Swift's cap for the same case.
- **`support`** (tests): the harness no longer forces `--output json` when the test names its own
  mode, tolerates a client that walked away mid-exchange, and stops waiting for exchanges a leaf's
  own deadline means it will never ask for.

## Declared differences from Swift

- **A stop is a stop.** Swift ignores `SIGINT` and watches it with a dispatch source; this leaf
  catches `SIGINT` and `SIGTERM` together (`arkdeck_platform::StopSignal`) and ends the observation
  the same way for both — `clientInterrupted`, the Job untouched — rather than letting `SIGTERM`
  kill the process mid-line. A host without signals never reports a stop.
- Inherited, not new here: `--output human` prints each row as the pretty-printed answer rather than
  Swift's prose rendering.

## Tests

| Test | What it holds |
| --- | --- |
| `job_watch.rs` (fake Runtime, macOS) | Rows written as they arrive with their sequence, the terminal line's `lastCursor` and `details`, and exit 75 at the deadline — the Runtime answers the same page on every read, so the answer does not depend on how many reads the deadline allows; a page served again is skipped and the same identity at a new position is refused (exit 2); a stream that cannot start at its origin says where it can, with no resume point to name; `--output human` prints the rows and no terminal line |
| `job_events.rs` (unit) | The request resumes from the cursor the last page ended with while a row's cursor is the mid-page resume point; the five refusals a followed stream can earn; the shape of an event line and of both terminal lines |
| `argv_fixtures.rs` (existing) | The leaf's Swift argv fixture is copied in and replays: 105 fixtures, 632 cases |
| `command_registry.rs` (via the replay) | Every leaf's `jsonlRefused` case is now the registry's own answer, and `runtime health --output jsonl` is refused by name |

## Local targeted checks

Run 2026-09-20 in this worktree's own `rust/target`, `CARGO_BUILD_JOBS=4`.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-cli --all-targets -- -D warnings`, and with `--target x86_64-unknown-linux-gnu`, `--target x86_64-pc-windows-msvc` | exit 0 on all three |
| The CLI suite | `cargo test -p arkdeck-cli` | exit 0; 199 passed, 0 failed |
| The audit, rewritten from this head | `python3 …/TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck` | the tables of `cli-parity-audit-20260919.md`: 146 / 55 / 40 / 15, 105 of 209 leaves served |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI

The first run of #2100 (head `7175db3d`) passed everywhere but the Rust workspace on `macos-26`,
where `rows_are_written_as_they_arrive_and_the_stream_ends_at_its_deadline` expected the resume
point of the *second* page: the loaded runner reached the deadline while the leaf was pausing
between reads, so only the first page had arrived. The assertion was counting reads, which is the
one thing a loaded host changes.

Both deadline tests now let the fake Runtime answer the same page every time it is asked. A replay
delivers nothing — the stream recognises each row's identity — so the lines written, the resume
point named and the way the wait ended are the same whether the deadline arrives after one read or
after nine, and the deadline is two seconds rather than a few hundred milliseconds so a slow host
still completes the first read. No sleep was added and no assertion was relaxed.

The whole lane is recorded here once it finishes.

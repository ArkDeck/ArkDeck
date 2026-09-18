# Rust human-action list/show CLI — 2026-09-18

Scope: TASK-XPA-018 continuous macOS CLI parity. Two read leaves are added:
`human-action.list` and `human-action.show`. The Rust executable connects to the
Runtime, performs contract/identity negotiation, and issues exactly one typed
read with the current Swift parameters. List owner filters remain paired,
page-size is a canonical positive integer bounded to 1..1000, show requires an
exact action identity, and `--timeout` remains a local bounded client deadline
rather than a wire parameter. Help lists both leaves.

As in Swift `RuntimeCLI.runRuntimeExecution`, successful human-action projections
and snapshot pages are emitted unchanged. Named Runtime refusals retain their
codes only with the existing pre-admission zero-dispatch proof. Read transport
failures do not become mutation `outcomeUnknown` or trigger replay.

Validation:

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test human_action_resources`
  — 6 tests passed. Replays both committed Swift argv fixture families and all
  4 successful recorded human-action control frames through the actual Rust
  executable and a private fixture socket. Asserts exact method/parameters,
  projection preservation, no extra connection/request, paired filters,
  bounded numeric/duration options, refusal proof handling, lost replies, and
  invalid identity rejection before connection.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — passed, all CLI
  regression suites and doc tests.
- `cargo fmt --manifest-path rust/Cargo.toml -p arkdeck-cli` — applied.

The first targeted run's two socket tests were blocked by sandbox Unix socket
binding restrictions; rerun with approved local socket permissions passed.
The combined slice's repository unified verification is recorded by the parent
integration run. This is CLI contract/process evidence using recorded Swift
answers, not real-device evidence or a completed Golden Journey. Runtime
physical-assistance resume, impact approval, installation cutover, and Swift
retirement are not claimed by this slice.

Final repository unified local check passed on 2026-09-19 using CI-pinned
PyYAML/jsonschema: common gates, Rust workspace/Clippy, published and candidate
contract checks, cargo deny and vet. Initial environment runs lacked jsonschema;
a concurrent-build run exceeded the existing process overflow test's two-second
wall-clock bound. The final isolated rerun passed unchanged assertions.

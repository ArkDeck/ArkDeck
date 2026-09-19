# TASK-XPA-016 — the managed-HDC process tests' port race

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane B, a test-only fix to R2's
`rust/crates/arkdeck-agentd/tests/managed_hdc_process.rs` (#2004, extended by #2008 and #2023).
Host measurement only. Base: protected main `dc989225`.

## What was wrong

#2037's CI (run 35446802660, Rust workspace on macos-26) went red in
`a_foreign_listener_on_the_endpoint_never_becomes_the_managed_server`: "no managed server was left
behind". The test held a foreign listener from `bind(0)` without recording its port among the
ports `free_port()` issues; after it dropped the listener, a test running in parallel in the same
binary could be handed that just-released port by `free_port()` and start its own fake server on
it, so the final "is the port still reachable?" check saw the neighbour's server. The same
reachability checks in the main test and in #2023's refusal cases carry the same race. #2037
changed none of this code.

## What changed

- One `ISSUED` set for the binary: `issued_listener()` binds `bind(0)` until the kernel hands a
  port no test was issued, records it and returns the held listener; `free_port()` uses it. The
  foreign-listener test holds its listener through it, so no other test can be handed that port.
- "No managed server is left / was left behind / was started" now asks whether any process still
  runs this test's own fake (`pgrep -f <root>/tools/hdc`), which is what those assertions mean;
  a reachable port may belong to another test. The one positive check ("the managed server
  listens") keeps the port, which only this test was issued.
- The CLI helper names what it needs when the `arkdeck` binary is missing (a crate-only test
  run does not build it), instead of a bare `unwrap`.

## Local targeted checks

- `cargo fmt --all --check`: exit 0.
- `cargo build -p arkdeck-cli`, then `cargo test -p arkdeck-agentd --test managed_hdc_process`
  five times in a row (CARGO_BUILD_JOBS=2): 4 passed, 0 failed each run.
- `cargo clippy -p arkdeck-agentd --all-targets -- -D warnings`: exit 0.

## CI

Pending (this PR).

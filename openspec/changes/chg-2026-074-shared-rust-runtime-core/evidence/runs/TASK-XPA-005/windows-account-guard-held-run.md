# TASK-XPA-005 — the account daemon's guard held by another profile's daemon: named, and its tests serialized

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2. Base: protected `main`
`bd8fe172` (#2486). Host: the Windows 11 x64 reference host, non-elevated. No device or HDC was
used, and no installed Runtime was read or written. Host tests are not Windows acceptance.

## The flake

`windows_account_locations_process::the_cli_reads_the_same_account_locations_from_a_dev_signed_daemon`
failed for at least three agents (WHR, G2's era, CI2 in #2505). Its daemon ended without a line
on stdout (`no line starting "arkdeck-agentd listening on "`).

**The cause.** These tests run the real daemon's account composition over a fake profile
(`USERPROFILE` naming a directory below `TEMP`). Its state root is the fake account's, but its
single-instance guard (`Local\ArkDeck.Agentd.<user SID>`) and pipe
(`\\.\pipe\arkdeck-agentd-<logon SID>`) are the user's own, shared by every worktree on the host.
- When two runs overlap, the second daemon finds the guard held. It answered "another Runtime
  holds the state root <its fake root> but left no instance document", which is wrong: no other
  Runtime holds that root. It printed this on stderr, which the test never read.
- `account_free()` checks the pipe once, before the start, so it cannot exclude a run that starts
  just after.

**Reproduced.** Three copies of `main`'s test binary started at once, in 2 rounds, with four
CPU-spinning processes, passed 1 of 6 runs. Each failure was the missing listening line, in
`an_earlier_root_beside_sessions_…` or in the signed-CLI test.

## The fix

**The product.** When a daemon finds its single-instance guard held and its own root holds no
instance document (`windows_lifecycle::guard_held`), it now says what happened and nothing is
started:
- the guard is named;
- the pipe and the process serving it are named, through `arkdeck_platform::pipe_server_pid`;
- the reason is given: the holder left no instance document in this root, so it serves another
  root.

The message reads: "another Runtime holds this daemon's single-instance guard … and its pipe … is
served by pid N; it left no instance document in the state root …, so it serves another root;
nothing was started".

`pipe_server_pid` opens one client instance of the pipe for attributes only, reads
`GetNamedPipeServerProcessId`, and closes it. It sends nothing. A missing pipe answers `None`, and
so does one whose every instance is busy. A held guard whose root does hold an instance document
is answered as before, with Swift's second-instance `already running`.

**The tests.** Every test in the file now holds two things for its whole run: its own process's
turn, and the account's daemon starters' turn (`StarterLock`, the named mutex clients take to
start the account's daemon).
- No client starts the account's daemon while a test runs.
- No other process running these tests, in another worktree of the same user, starts one either.
  It waits up to ten minutes for the turn.
- A daemon that ends without its listening line now fails with its exit status and its whole
  stderr.

**What the tests prove is unchanged.** They still run the real account composition over a fake
profile. They still skip, saying so, when an account daemon of this user already serves.

**New test.** `a_held_account_guard_names_the_process_serving_its_pipe`:
1. The account daemon serves over a first fake profile.
2. A second one, over another fake profile, exits non-zero. It names the guard and the first
   daemon's pipe and pid, serves nothing, and writes no instance document.
3. The first daemon answers on and stops as always.

## Measured

Three copies of the test binary started at once in each round, with four CPU-spinning processes:

| binary | rounds | runs passed |
| --- | ---: | ---: |
| `main` (`bd8fe172`) | 2 | 1 of 6 |
| this change | 6 | **18 of 18** |

## Delegated minor decisions, pending the next rulings batch

- **The new start refusal and its message**, for a held guard whose holder left no instance
  document in this root. It was a misleading "holds the state root" and is now a named guard,
  pipe and pid. The second-instance answer is unchanged.
- **The tests' serialization through the account's starters' turn**, which a client starting the
  account's daemon also takes.

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/ci2-acct`,
`ARKDECK_DEV_SIGNER_THUMBPRINT` set.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-agentd -p arkdeck-platform --no-fail-fast` | exit 0: 360 passed, 3 ignored |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: (`AD-SHO~4`) | exit 0: the same counts |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) check and clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check` | exit 0 |

The two SKIPPED lines are the known wildcard-listener skips. No account-locations test skipped:
no account daemon of this user served.

## CI

To be recorded by the next slice.

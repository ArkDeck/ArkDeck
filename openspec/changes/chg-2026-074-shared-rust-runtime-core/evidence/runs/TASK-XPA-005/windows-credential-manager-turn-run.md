# TASK-XPA-005 — Credential Manager loses concurrent updates: one call at a time

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2-C. Base: protected `main`
`6b7ce952` (#2441; measured on `e903da6c`, #2432). Host: the Windows 11 x64 reference host,
non-elevated. The user has the two interactive logon sessions of a UAC administrator, and every
probe ran in the filtered one. No device was contacted. Every probe credential lived under `ArkDeck-fixture/…`; no
production or other credential was read, written or deleted. Host tests are not Windows
acceptance.

## The flake

`arkdeck-platform` `windows_credential_store::concurrent_writers_keep_each_others_credentials`
(#2354) failed in H3's run under heavy parallel load, with "lost 4 … Credential Manager did not
keep the written credential". It passed 6/6 alone. G2 had seen the same class of failure
(`windows-managed-hdc-stop-run.md`: 2 of 6), and so had the TASK-XPA-011 signing-leaves run (3
kept credentials `Absent` in the `ForeignUser` phase). C1's first hosted-runner run had a
credential that read back and then answered `Status(1168)`, with no mechanism established.

## Does Credential Manager lose writes under concurrency?

Yes. I measured it with a `ctypes` probe that calls `CredWriteW`/`CredReadW`/`CredDeleteW`
directly, outside ArkDeck. Each worker thread keeps one credential, and in each round writes,
reads back and deletes one of its own, then checks the kept one. A census after each run counts
leftovers with `CredEnumerateW` on the run's prefix, names only.

| load | written credentials lost | deleted credentials back |
| --- | ---: | ---: |
| 8 processes × 8 threads × 40 rounds, mixed kinds, 5 runs | 28, plus 4 read-back failures | 320 |
| the same, every call under one named mutex, 5 runs | 0 | 0 |
| 1 process × 8 threads × 40 rounds, short values, 3 runs | 0 | 12 and 14, in 2 of 3 runs |
| the same under the mutex, 2 runs | 0 | 0 |

- **Lost writes.** A write can succeed, read back, and then be gone. The losses fell in the
  first rounds, while other processes were writing too.
- **Revived deletes.** A delete that answered success can be undone. The credential is back
  later, enumerable and deletable.
- **Scope.** Both happen between processes, and deletes come back even between threads of one
  process. Credentials that existed before the burst were never lost.
- **Not the cause.** Neither a process's first call, a reader, an idle process, nor a single
  write after another process's call reverted anything: each of those one-step orders was
  tried 5 times with no loss.
- **Where it happens.** The mechanism is inside Credential Manager (lsass). It is not
  observable from here beyond these answers.

### A measurement error, corrected

My first probes did not check their own deletes, and their revived credentials accumulated. By
the time I noticed there were about 790 `ArkDeck-fixture/probe*` credentials, so this user held
823 credentials (~135 KB). At that size `CredWriteW` refused new credentials with error 8
(`ERROR_NOT_ENOUGH_MEMORY`), 233 into a sequential run. So two of my early "serialized" figures
were writes refused for capacity, not lost updates, and I discarded them.

I deleted only my own prefixes (`probe-`, `probe2-`, `probe3-`, `probe4-`, `cap-`): 828
credentials, every delete answered success. That left the user's 35 credentials, and I repeated
every measurement above from that clean state. On a clean store, 300 sequential credentials all
wrote and read back.

- `ArkDeck-fixture/race-*` (22) and `ArkDeck-fixture/test-*` (4) are not this slice's, and I
  left them. That 4 `test-*` credentials remain shows fixture credentials do leak here, and the
  revived deletes explain how.

## Our store: read-back and serialization

- **Read-back.** `set` read the credential back after `CredWriteW`, but nothing stopped another
  call from changing it between the write and the read-back, or after it. The flake's "did not
  keep the written credential" is that read-back, done right, meeting a real loss.
- **Serialization.** The test file serialized its tests with an in-process `Mutex`. That covered
  neither threads inside `concurrent_writers…`, nor other test binaries (other worktrees'
  `cargo test` runs on this host, which is the "heavy parallel load"), nor the daemon and the CLI
  in production.
- **Product exposure.** Two ArkDeck processes changing credentials at once can lose a
  just-written signing envelope. Worse, a `remove` that answered `true` can have its credential
  come back.

## The fix (product)

`KeychainItems` now takes this user's Credential Manager turn for every call:

- **The turn.** A named mutex in the session namespace, `Local\ArkDeck.CredentialManager.<user
  SID>`. It is created owner-only (`O:<user>D:P(A;;GA;;;<user>)(A;;GA;;;SY)`), and an existing
  object owned by anyone else refuses the call. That is the same pattern as the daemon's
  single-instance guard and starter lock.
- **Scope of each call.** `set` holds the turn from `CredWriteW` through the read-back.
  `read`/`presence`/`contains` hold it for the read, `remove` for the delete.
- **Bounds.** A turn waits at most 30 s, else `Refused("another ArkDeck process held the
  Credential Manager turn too long")`. An abandoned turn, whose holder died mid-call, is taken.
- **For direct callers.** `with_credential_manager_turn` exposes the turn to code that calls
  Credential Manager itself. The tests' foreign-credential writes and cleanup deletes use it.
- **Cost.** Serialization costs throughput: Credential Manager calls take milliseconds and
  otherwise overlap. The one-process, 8-thread probe took 2.5 s free and 32 s in turns. ArkDeck
  makes a handful of credential calls per signing operation.

**Limits.**
- Programs other than ArkDeck do not take the turn, so their concurrent changes can still undo
  an ArkDeck change. `set`'s read-back still reports a loss that happens before it.
- `Local\` is per logon session, so an ArkDeck process in another logon session of the same
  user (for example over SSH) takes a different turn. The daemon and CLI run in the user's
  interactive session.
- Delegated minor decision, pending the next rulings batch: session namespace rather than
  `Global\`, following the daemon's guard.


## Tests

- **`concurrent_writers_keep_each_others_credentials` (H3's flake).** It now also checks, after
  each phase, that every churned credential is still deleted, and it reports what `presence`
  answered. Its rounds went from 40 to 10, because its threads now take turns. That is a
  delegated minor decision, pending the next rulings batch.
- **`concurrent_processes_keep_each_others_credentials` (new, `#[ignore]`d measurement).** The
  test binary runs itself as 8 child processes of 4 threads × 10 rounds, churning through
  `KeychainItems`. Afterwards the parent checks that every kept credential is present and every
  churned one absent. It is ignored by default for the reason under "Loop under load"; run it
  with `--include-ignored`.
- **Fixture guard.** It now asks for the turn up to 10 times before giving up a delete.
- **Negative controls.** I ran them with `CredentialTurn::take` temporarily not waiting, then
  reverted:
  - the thread test failed 4 of 4, with 1–6 deleted credentials back per phase and none lost;
  - the process test failed 4 of 5, with 5–16 failures each. In the earlier 6-child layout it
    failed 2 of 3, and every failure listed was a deleted credential that came back.

## Loop under load

Each loop runs the test binary as several copies at once, repeatedly, with a census of
`ArkDeck-fixture/test-*` after each iteration.

| loop | runs | failed | fixtures left |
| --- | ---: | ---: | --- |
| final binary, default suite (thread test included, process test ignored), 4 copies × 10 iterations | 40 | **0** | 0 after every iteration |
| with the process test, 2 copies × 15 iterations | 30 | 2, both in iteration 3 | 2 from iteration 3 on |
| first attempt, with the process test, 4 copies, stopped after 4 iterations | 16 | 5 | 424 |

- **Process-test failures in the 2-copy loop.** Both copies failed in the same iteration, only in
  the process test, with churned credentials `Present` after their deletion. All were in the
  last round of several children. This is a revival under the turn. Every ArkDeck call takes the
  turn, so the overlapping change came from outside it: `git` and `gh` were active on the host.
  I could not identify the caller.
- **One-step orders do not reproduce it.** No order of one other process reading, writing,
  deleting or exiting around a delete brought the deleted credential back: 9 orders × 5
  trials. Neither did single-threaded churn, 3 × 400 rounds.
- **The first attempt.**
  - Iteration 0 had one `set` read-back miss inside the turn.
  - Iteration 3 failed all 4 runs, 2 of them on `set Status(8)`: the store had reached
    capacity with 424 fixtures left by the loop's own runs.
  - Every Credential Manager call gets slower as the store grows: the locked 8 × 8 probe took
    about 500 s per run over 400 filler credentials, against about 30 s on a clean store.
  - Likely cause: the old fixture guard skipped a delete when its turn was not taken in time. I
    did not observe a timeout directly, but the leaks, the slowdown and the capacity refusal fit
    that loop. The guard now asks again.
  - I deleted the leftovers: only `test-<pid>-…` namespaces whose process no longer ran, 437 and
    then 2 credentials, no errors.

## What is not fixed

- **Outside callers.** A program outside ArkDeck that changes credentials at the same moment can
  still make Credential Manager lose an ArkDeck change or bring back a deleted one. The turn
  cannot hold it off.
  - `set` still refuses a loss that happens before its read-back.
  - A later loss surfaces as the typed `Status(1168)` / `Absent`, never a value.
  - A revived credential is found by the next `presence`.
- **Other logon sessions.** An ArkDeck process in another logon session takes another turn.

## Local targeted checks

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-platform -p arkdeck-provider-workspace --no-fail-fast` (251 passed, 3 ignored: the new process measurement and two external inputs as on `main`) | 0 |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | 0 |
| `windows_credential_store -- --include-ignored` | 0 (7 passed) |
| macOS and Linux type/lint cross-check (`--target aarch64-apple-darwin`, `x86_64-unknown-linux-gnu`, stub toolchain) | 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 |
| `git diff --check` | 0 |

The two `SKIPPED` lines are the wildcard-listener cases that are not bound outside GitHub Actions;
their loopback cases ran. A census after the checks found this user's credentials back at the
31 that were there before the loops, none of them this slice's.

## CI

To be recorded by the follow-up.

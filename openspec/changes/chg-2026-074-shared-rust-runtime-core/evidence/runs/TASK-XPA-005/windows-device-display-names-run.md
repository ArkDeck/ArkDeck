# TASK-XPA-005 — candidate display names through the composed Target observation owner

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1 (GJ-1).

Base: the HDC lifecycle leaves layer (`windows-hdc-lifecycle-leaves-run.md`) on protected `main`
`4d163ba1b`.

Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, and nothing installed was read or written. Host tests are not Windows acceptance.

## The defect

`device display-name set|clear` could never succeed through the composed Target observation owner,
which is the development HDC on macOS and the registered tuple on Windows alike.

`Host::candidate_display_name` read only the legacy provider's retained snapshot
(`Host::observations`). When the Target observation owner observes, `device.observations` answers
through that owner and never retains the legacy snapshot. So every request answered
`resourceConflict`, "No current observation snapshot exists". The device reads layer
(`windows-device-reads-run.md`) observed this through the signed CLI.

## The fix

The lead decided this on 2026-10-05: a defect, delegated, pending the next rulings batch.

**`TargetObservations::name_candidate` (`arkdeck-hoststore`)** names a candidate in the owner's
current snapshot:
- **Identity.** It is taken from that snapshot exactly as the legacy path took it from its own:
  the active set is every observation of the snapshot at the snapshot's generation.
- **Admission.** The store's candidate name owner (`TargetStore::mutate_candidate`, unchanged)
  admits only one of those exact observations at that generation. It fails closed on a duplicate
  identity, a mixed generation, an absent reference or an adopted candidate.
- **Generation.** A written name advances the snapshot to the generation it was written at, and
  its names are read again. The next unchanged reading keeps that generation.
- **No snapshot.** With no current snapshot, the Host keeps the refusal: `resourceConflict`, "No
  current observation snapshot exists", phase `candidateDisplayNameOwner`, no new dispatch.
- **Unknown outcome.** An unknown outcome discards the snapshot, as the legacy path does.

**`Host::candidate_display_name`** uses the owner whenever the composition observes through it
(`Host::observe`). Otherwise it keeps the legacy path. Without an HDC the answer is unchanged.

No Swift oracle records these leaves. The semantics are the Runtime's candidate name owner's, as
the legacy path already served them. The macOS Rust tests that hold those semantics still pass
unchanged:
- `host_tests.rs` `candidate_name_owner_uses_only_runtime_snapshot_and_advances_cas`, over the
  legacy snapshot;
- `windows_target_owners_process.rs`, the refusal without an HDC.

No test pinned the broken path.

## Measured

`gj1_device_reads.rs` `the_real_cli_names_and_clears_a_candidate_in_the_current_observation` runs
the real signed CLI against the signed test daemon over the Target adoption oracle's board:
- `device display-name set` in the exact current observation answers
  `arkdeck.candidate-display-name/1` at the next generation. The next `device candidates` keeps
  that generation and reads the name back on the same observation.
- A stale generation is refused: `resourceConflict`, phase `candidateDisplayNameOwner`, no new
  dispatch, and the name kept.
- `device display-name clear` removes the name at the following generation.
- Once adopted, the candidate is refused: "Candidate is already adopted; use its durable target".

`device.display-name.set` and `.clear` join `WINDOWS_MEASURED_LEAVES`. The regenerated coverage
moves both to `implemented` on Windows, and nothing else changes. The census drops the row.

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/s1-remaining`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test -p arkdeck-cli -p arkdeck-agentd -p arkdeck-hoststore --no-fail-fast` | exit 0: 970 passed, 0 failed, no SKIPPED |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | exit 0 |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) clippy `-D warnings`, stub toolchain | exit 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 |
| `git diff --check origin/main...HEAD` | exit 0 |
| `arkdeck maintainer contracts check` | exit 0: 242 checked, clean |

The macOS-only `host_tests.rs` test and `target_observation_control.rs` run in CI's Swift and
Rust lanes, not on this host.

## CI

To be recorded by the next slice.

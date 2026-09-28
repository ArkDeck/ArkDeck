# Flash entry points end to end over the control socket (TASK-XPA-017, S2a)

This is final-lane §4 S2, less the recovery broker's `executePinnedRequest`.
The broker is a separate PR (S2b, `flash-recovery-broker-execute-run.md`)
stacked on this one, because it admits and runs through the admitter this
slice composes.

Base: protected `main` `f968192e6`. No contract input, Catalog, OpenSpec delta
or `tasks.md` change. No device, `arkforged`, USB host or installed Runtime is
used, and nothing here is device evidence.

## The defect: GJ-4 did not run as the runbook has it

GJ-4 runs `arkdeck agent run --operation flash.full-restore@1 …`. The Rust
`agent.run` admitted an execution's request with the plain `JobAdmitter`. That
admitter answers every Flash reference `not materialized by the Rust Runtime
yet` (`job_plan.rs` `descriptor`). Only `job.submit` went through the
`FlashAdmitter`.

Swift has one path for both: `submitForAgent` and `job.submit` are both
`submitOwned`.

Reproduced before the fix, by removing the new branch as a mutation of the
test below:

```text
{"command":"agent.run","error":{"code":"admissionDenied", …
 "message":"flash.full-restore@1 is not materialized by the Rust Runtime yet"}, …}
```

## What changed

- **`arkdeck-hoststore`.**
  - New trait `AgentAdmission` (Swift `engine.submitForAgent`).
    `AgentEngine.admitter` is now a `&dyn AgentAdmission`, and `JobAdmitter`
    keeps its behaviour through the trait.
  - `FlashAdmitter` implements the trait. A Flash reference
    (`flash.full-restore@1` or its alias `flash.dayu200`) is admitted by
    `FlashAdmitter::submit`, the path `job.submit` takes. That path covers
    DEC-016, the Runtime's own destructive capability, the `executes` guard
    and the campaign. Every other request goes to the admitter as before.
- **`arkdeck-agentd` `host.rs`.**
  - A new helper, `with_flash_admitter`, composes the `FlashAdmitter` once, for
    both `job.submit` and the Agent execution owner (`agent.run`,
    `agent.resume`, `human-action.resume`).
  - Execution needed no change: `start_agent_run` already ran an execution's
    Job through the `FlashRunner`.
- **`arkdeck-cli` `agent_executions.rs`.**
  - `agent run --operation flash.dayu200` was refused on the client with
    `operation must be an exact token published by the current Catalog`.
    `published_binding` required an `@version`.
  - Swift's `RuntimeOperationCatalog.descriptor(reference:)` accepts an
    unversioned id that names an unversioned entry. The alias is one.
  - The CLI now reads a reference the same way. The daemon already did
    (`agent_execution.rs` `descriptor`).
- **F3 (`arkdeck-provider-arkforge` `flash_session.rs`).**
  - When `arkforged` rejects a control receipt, the session now cancels the
    job at its last journal sequence. It polls once more from its cursor, so
    that whatever the rejection published is counted, and sends that
    sequence. It sends no cancel when the job is already classified. If the
    catch-up poll fails, it uses its cursor.
  - Swift's `cancelJob(jobID:)` names no sequence, and ArkForge refuses it
    with `EXPECTED_SEQUENCE_REQUIRED` (`arkforged/src/service.rs:1536-1564` at
    the pin). Under Swift the job then waited for its request's deadline.
  - This is a declared difference that makes a cancel take effect. A cancel
    ArkForge refuses (for example `STALE_JOB_SEQUENCE`) is still ignored, as
    Swift's `try?` ignores it. The drive stops with the same error either way.

## F5: not reachable in GJ-4

`rebootToNormal`'s bound-reconnect summary carries only `usbTopology` among
the facts the control port requires, so the port refuses its receipt
(`arkforge-control-performer-run.md` "Carried from Swift"). At the pin, the
only managed-control actions ArkForge's Rockchip provider writes into a plan
are `enter-updater` and `read-build-facts`:

- `arkforge-provider/src/rockchip.rs:308`;
- `arkforge-provider/src/rockchip.rs:589`.

`arkforged` asks for a control action only from a plan's private action
(`arkforged/src/jobs.rs:1891-1921`), so a DAYU200 full restore never asks for
`reboot-to-normal`. F5 is therefore left as Swift has it, and a test still
pins it. If a future pin adds that action to the Rockchip plan, this has to be
revisited before that pin is taken.

## End to end over the control socket

New `rust/crates/arkdeck-agentd/tests/spawning/flash_socket_control.rs`, five
cases. Each case runs in its own child of the test binary:

| entry point | request | outcome | asserted |
|---|---|---|---|
| `arkdeck agent run --operation flash.full-restore@1 --target … --inputs-file …` | canonical | completed | CLI exit 0; the Job is `succeeded` with `outcomeUnknown: false`; the lane prepared and performed exactly once; a second `job run` is refused and dispatches nothing |
| `arkdeck agent run --operation flash.dayu200 …` | alias | completed | as above |
| `arkdeck agent run --operation flash.full-restore@1 …` | canonical | unknown | CLI exit non-zero; the Job is `waitingForRecovery` with `outcomeUnknown: true`; one perform; `job run` is refused and nothing is replayed |
| `arkdeck flash run --target … --inputs-file …` | canonical | completed | as the first row |
| `arkdeck flash run …` | canonical | unknown | as the third row |

- **The server.** It is `arkdeck_agentd::serve_control`, the production
  binary's own serving and drain loop. It listens on a private Unix socket
  under `/private/tmp`.
- **The client.** It is the real `arkdeck` CLI binary, beside the daemon in
  the Cargo target, with `--socket`. `job status` and `job run` go through the
  same CLI.
- **The Host.** It is the one `flash_execution_control` already composes,
  factored out as `flash_host`:
  - real owners: Target, Artifact, Import, Job, capability and Agent execution;
  - the Flash planning, host facts and admission;
  - a fixture HDC and one USB census row, now also given to the Target
    observation owner, as `flash run` resolves its target through
    `device.observations`;
  - the Swift Flash run oracle's fake `FlashLane` and `RockchipHost`.

### The tradeoff (prompt §4 S2, one of two)

Neither prompt option is taken as written.

- **Option 1, a development seam** in the daemon binary that accepts a fake
  lane on an isolated root: this would put fake-lane code into the shipped
  binary behind an environment switch.
- **Option 2, a stand-in `arkforged`**: this would have to speak ArkForge's
  whole controller protocol, including inspect, import, materialize, start,
  watch, permits and control receipts, with its journal sequences.
- **Taken: a variant of option 1 with no seam in the binary.** The daemon's
  serving library and the real CLI are driven against a Host that only this
  test binary composes. No production composition can be handed a fake lane,
  and nothing in `main.rs` or `production.rs` changes.

What this does not cover:

- the lane's own ArkForge IPC, which is covered by the provider's session and
  lane tests and by SPK-9's real-daemon subset;
- the production composition's startup of the lane, covered by
  `arkforged_owner_stop` and `production_composition`;
- a real device, which is phase A's GJ-4.

## SPK-9

`spk-9-run.md` gains a closing section. Its §4 preconditions are resolved,
with the PRs that resolved them. It maps the evidence to each SPK-9 claim.
Verdict: SPK-9 passes for its device-free scope. The `available` preview
state and device execution through a real `arkforged` move to phase A's GJ-4.

## Local targeted checks

Worktree `agent-adc7ba94d908e1c5c`, `CARGO_TARGET_DIR=/private/tmp/arkdeck-lane1-target`,
`CARGO_BUILD_JOBS=2`. Logs are under `/private/tmp/arkdeck-lane1-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings` for `arkdeck-provider-arkforge`, `-hoststore`, `-agentd`, `-cli`, `-client`, `-soak` (`s2a-clippy.log`) | exit 0 |
| `cargo test --no-fail-fast` for the same six crates, after `cargo build -p arkdeck-cli -p arkdeck-agentd` (`s2a-test.log`) | exit 0: 198 test binaries, 1554 passed, 0 failed, 21 ignored |
| mutation: `FlashAdmitter::submit_for_agent` reduced to the plain admitter | the three `agent run` socket cases fail with `admissionDenied … is not materialized by the Rust Runtime yet`; the two `flash run` cases pass; restored |
| `sh scripts/check-sdd.sh` (`s2a-sdd.log`) | exit 0 |

Not run:

- `generate-contract.py --check`: no contract input changed.
- Swift: nothing of it changed.

## CI

PR #2305, head `b714dae88`, Swift CI run `36419884967`: `guard`, `plan`, the four Rust lanes,
`ds-tokens` and the `swift` aggregate green; `swift-tests`, `app-build` and `ds-interactions` were
not selected (no Swift or App change). Merged as `53b832780`. (Recorded by the RC-readiness slice,
`rc-readiness-run.md`.)

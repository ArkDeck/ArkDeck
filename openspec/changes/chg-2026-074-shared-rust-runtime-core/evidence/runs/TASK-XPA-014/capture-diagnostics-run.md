# `capture.diagnostics@1` on the isolated Rust daemon — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `11f6ec06`, which carries the process
dispatch composition this slice needs (#1933), the Rust CLI's agent leaves (#1935) and lane B's
live-mode probe and post-flash HDC observation (#1934, #1936); no stack. The
HiLog plan's 16 MiB budget needs `ProcessDispatch`. `FixtureDispatch`'s read-only runner refused any
budget over 8 MiB ("read-only process budget must be 1..60 seconds and 1..8 MiB"). Before this
slice was stacked on #1933, the agent replay's capture run lost its HiLog leg to that refusal. The
Swift oracles are #1921's (`CaptureDiagnosticsOracleContractTests`) and #1925's
(`AgentExecutionOracleContractTests`), unchanged. Nothing installed changes and no device is
reached.

## What changed

- **Typed actions** (`arkdeck-provider-hdc`): the capture legs Swift's default selects, as Swift's
  HDC provider chooses, lowers, judges and persists them. The device's free space
  (`-t <key> shell df -k /data/local/tmp`, 30 s): the fourth column of the last data line, in KiB,
  against the required bytes, `insufficientDeviceStorage` below them. The HiLog drain
  (`shell hilog -x <filters>`, a timeout of `max(45, window + 15)` s, a 16 MiB budget carried by the
  plan): truncated fails, empty is an unknown outcome, bytes that are not UTF-8 are kept. The window
  inventory (`shell hidumper -s WindowManagerService -a -a`, 30 s). Swift's request bounds with
  `HDCE0RequestError`'s spellings, and the persisted forms `hdc.observeStorage`, `hdc.captureHilog`
  and `hdc.captureUIDump`. `Action` is no longer `Copy`.
- **Engine** (`device_run.rs`): the step loop walks every catalog step, as Swift's `executeSteps`
  does. The host storage preflight asks the Artifact store for the request's
  `totalArtifactByteBudget` or the operation's 512 MiB. An optional step the request did not select,
  or whose upstream did not run, is recorded as skipped, on the timeline and in `skipReasons`, with
  every product it owned recorded missing and the reason. A device step after the preflight waits
  for the complete evidence preflight. A failed optional step is skipped as `failed("…")` and the
  Job goes on, while an unknown outcome parks the Job, optional or not. `firstEvidenceStepAtUTC`
  is set at the first device step after the preflight. Each product is checked against the job
  byte budget first: 128 MiB unless the request sets one.
- **Finalization**: as Swift's `publishFinalizeArtifacts`, every declared product that no step
  recorded is recorded missing. Then `capture.log`, `markers.json`, `artifact-index.json` and
  `capture-summary.json` are composed (`capture_documents.rs`) and published under
  `finalize-session`. If that cannot be done, the Job ends in the `artifactFinalizationFailed` lane.
- **Planner** (`job_plan.rs`): `capture.diagnostics@1` is materialized, and each selected step's
  journal arguments are in the plan digest. Those are the storage step's `requiredBytes`, the HiLog
  `byteBudget` Swift journals from `totalArtifactByteBudget` (not the lowered 16 MiB), and 8 MiB for
  the window list. A leg this Runtime does not run yet, and a ring-buffered capture, are refused as
  not materialized. A HiLog filter that Swift's request refuses is refused as Swift refuses it.
- **Reads** (`job_result.rs`): `job.result` and `job.evidence` read capture Jobs. Only the products
  the request left out (Swift `intentionallyOmittedArtifactNames`) may be missing. Ownership also
  checks the materialized revision and identity, and an index without rows reads as empty, as in
  Swift.
- **Spelling**: facts products and the capture documents are written as Swift's
  `CanonicalJSONEncoders.canonicalPretty()` writes them, with `.withoutEscapingSlashes`; before,
  a facts product holding `/` would have escaped the solidus. The spelling is pinned by a probe of
  Foundation on this host.
- **Tests and harness**: `tests/capture_diagnostics.rs` is new. The agent replay now includes its
  capture run, so the replays' helper for skipping unserved runs is gone. `check-corpus-replay.py`
  no longer skips runs of an unmaterialized operation. The planner test's not-materialized example
  is now `debug.hap@1`. README and `tasks.md` are updated.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Provider | `cargo test -p arkdeck-provider-hdc` | passed: 15 in the library (3 new: the capture lowerings and persisted forms, Swift's request bounds, the verdicts), 7 lifecycle, 5 managed server, 7 process dispatch, 11 parity |
| Capture replay | `cargo test -p arkdeck-hoststore --test capture_diagnostics` | 1 passed. All 28 exchanges match at T1, and the fake's 16 calls arrive in order. Every file and entry the four Jobs leave matches byte for byte: the Artifact indexes with their missing products, the four finalization products, the records, journals and Sessions. Then come four refused plans (crash ledger, screenshot, ring buffer, a shell filter) and a plan without the HiLog leg. |
| Agent replay | `cargo test -p arkdeck-hoststore --test agent_execution` | 1 passed. All 29 exchanges match (21 before this slice), the capture run's included; the fake's 11 calls arrive in order, and every file matches byte for byte. |
| Store library and the other replays | `cargo test -p arkdeck-hoststore` | passed: 146 in the library, the `observe.device@1` replay, the planner tests and the rest |
| Control, daemon, CLI | `cargo test -p arkdeck-agentd -p arkdeck-control -p arkdeck-cli` | passed |
| Real processes | `python3 rust/scripts/check-corpus-replay.py` on `tests/fixtures/capture-diagnostics`, `tests/fixtures/agent-execution` and `tests/fixtures/observe-device` | PASS: 28 exchanges and 57 checks; 29 exchanges and 50 checks, none skipped; 28 exchanges and 57 checks. Summaries are in `/private/tmp/xpa014-capture-harness-{capture,agent,observe}-r1.json` (SHA-256 `2a39988150305cc0146d8e2b87882e8efae941de4248d9aac43068cd68a610bb`, `f493c317b68c27e8dbbb39a320cc71703ac9210fe9595c7a0ac2700adc9913f3`, `01e80dc163d94c7f2e1109f473813f0d66798d9513322600f86bcbadef62de87`). The observe summary equals the process dispatch slice's, apart from the `skippedRuns` member the harness no longer writes. |
| Lint | `cargo fmt --all`; warnings-denied Clippy of `arkdeck-provider-hdc`, `-hoststore`, `-control`, `-agentd`, `-cli` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | passed |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` over the two commits of the stack (merge base
`3d880989`), with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual
environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `9d9ef417` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 652 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-capture-gate-20260914-r1.log`, SHA-256 `2e1794d7e11468b27fa7b50ac0e273d001388edf3bca0f7171c514aef1d8bc0b` |

The amend after r1 only fills in this row.

After #1934 and #1933 merged (#1933 as `47d6f020`), this commit was re-parented onto main with
`git rebase --onto origin/main f358d003`, without conflict. The following pass on that head:
`cargo fmt`, the provider-hdc, hoststore, agentd, control and CLI tests (including #1934's
live-mode tests), warnings-denied Clippy for macOS, Linux and Windows, and `check-corpus-replay.py`
on all three oracles. The three summaries
(`/private/tmp/xpa014-capture-harness-{capture-diagnostics,agent-execution,observe-device}-r2.json`)
are byte-identical to r1's. CI gates the rebased commit.

After #1935 and #1936 merged (main `11f6ec06`), this commit was replayed onto main again. The only
conflict was `tasks.md`, where #1935's bullet and this slice's are both kept. `README.md` and
`check-corpus-replay.py` merged cleanly with #1935's Rust CLI steps, and no reference to the
removed run skipping is left. The same checks pass on that head, and the harness now runs #1935's
CLI steps over the capture run too. The agent oracle replays 29 exchanges with 54 checks, among
them the Rust CLI reading the captured execution after the restart as the socket answers it
(`CLI agent status captured`). The capture and observe summaries are byte-identical to r1's; the
agent summary is `/private/tmp/xpa014-capture-harness-agent-execution-r3.json` (SHA-256
`9995b3e99b5f79ee7e173f6cc5da0df2844aaf687864af94d30691926050ef21`). CI gates the rebased commit.

## Differences from Swift, and what is not run

- **Legs beyond the default**: Swift would plan the advanced dump, the crash index and log, the
  liveness readback, the tree, screenshot and Trace file legs with their receives and cleanups, and
  a ring-buffered capture. This Runtime refuses them at `job.plan` as `rejected`, before anything is
  admitted. Inputs with a catalog pattern (`markers`, `bundleName`, `crashLogName`, `windowId`,
  `componentId` and the like) stay refused as before, so `markers.json` holds no manual mark yet;
  its code is Swift's all the same.
- **An optional step that fails**: no oracle records one. Before the stack, the `FixtureDispatch`
  path refused the HiLog leg's budget. The Job then succeeded without `hilog.txt`, which was
  recorded missing as `failed("dispatch refused: …")` and so named in `capture-summary.json`. The
  Manifest contract refused that Job's Session (`contractViolation`). Whether Swift's refuses the
  same Manifest is not shown by any oracle.
- **A capture through the Rust CLI**: the CLI slice (#1935) runs `observe.device@1` through
  `arkdeck agent run` on the real daemon. A capture run joins that harness step once both slices
  are on main.
- **Recovery**: the parked capture (`emptyHilog`) stays parked across a restart. Nothing resumes or
  reconciles it before the L.1 item 13 ruling.
- **No device**: DAYU200 is not attached to this host.

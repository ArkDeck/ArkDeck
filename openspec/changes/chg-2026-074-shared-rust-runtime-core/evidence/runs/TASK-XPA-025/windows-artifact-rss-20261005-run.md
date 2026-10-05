# Windows Artifact RSS collector — 2026-10-05

The Artifact reader still invoked Unix `ps` on Windows, so successful typed
reads retained only unmeasured RSS rows. `RssSampler` now uses the existing
`windows_host.process_resources` API for the daemon PID and Python client PID.
It copies `workingSetBytes` without a KiB conversion and labels Windows rows
with `residentSetSource: WorkingSetSize`. A failed read, missing/invalid counter
or PID absent from the native process snapshot leaves the complete sample
unmeasured; later successful rows cannot turn a series with a gap into a peak
summary. Error evidence retains only the exception type.

The Unix `ps` argv, timeout, KiB conversion, successful/error row shapes and RSS
summary behavior are unchanged. The 0.2-second sampling interval, Artifact
reader version, validation, timing boundary, resource/performance thresholds,
capture-only restriction and baseline rules are unchanged. Working set remains
a sampled lower bound on peak, not private bytes, copy count or publication RSS.

Delegated minor decision, pending the next rulings batch: use the existing
native process counters and require both expected PIDs for each usable Windows
Artifact RSS observation. This collector repair does not adopt a reference host,
baseline, acceptance result or task/platform status.

## Local targeted checks

Worktree `D:/src/ArkDeck-wt/artifact-rss`, branch
`agent/xpa-025-windows-artifact-rss-20261005`, based on integration head
`6df51fb094143510b73560ef3b121e9854948e86`. Logs are local under
`D:/src/ArkDeck-wt/tools/logs/`. The launcher uses the handover environment with
`CARGO_TARGET_DIR=D:/cargo-target/artifact-rss` and `CARGO_BUILD_JOBS=2`.

- `python -X utf8 -m unittest -v bench.test_artifact_rss
  bench.test_artifact.ArtifactFixtureTests bench.test_artifact.ArtifactReadLoopTests
  bench.test_artifact.ArtifactTransportTests
  bench.test_artifact.IncrementalArtifactTransportTests`, from `scripts` via
  `D:/src/ArkDeck-wt/tools/artifact_rss_checks.py`: exit 0, **28 passed, zero
  skips**; `artifact-rss-windows-native-clean.log`. Native tests sample an owned
  Python child and the client, stop the sampling thread, then prove the exited
  child leaves RSS unmeasured. A 1 MiB fixture is published by the existing
  integration soak and read through the existing signed production daemon,
  validating the full digest and usable native daemon/client RSS evidence.
- The native process check passed in the sandbox. The first broader invocation
  failed at two signed-daemon starts with development-root access denied and at
  two existing Unix/Swift-default test assumptions on Windows;
  `artifact-rss-windows.log`. The focused native invocation passed through
  controlled escalation; `artifact-rss-windows-native.log`. The final launcher
  and committed opt-in test explicitly clear inherited `ARKDECK_*` and
  `OHOS_HDC_*` settings, case-insensitively. The harness adds only the fresh
  private development root; no HDC/server is composed. The test daemon drained
  before further checks, and the temporary Artifact root was removed.
- `wsl --distribution Ubuntu-24.04 --cd
  /mnt/d/src/ArkDeck-wt/artifact-rss/scripts -- env PYTHONDONTWRITEBYTECODE=1
  python3 -m unittest -v bench.test_artifact bench.test_artifact_rss`: exit 0,
  **42 tests, 39 passed and three explicit skips**; `artifact-rss-linux.log`.
  The two native Windows cases skip on Linux; the existing real-owner opt-in
  skips because integration bins were not enabled there. All existing Artifact
  tests, including the unchanged Unix/default-context cases, and the new mock
  regressions passed. No daemon or benchmark capture ran in WSL.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `artifact-rss-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `artifact-rss-sdd.log`.
- `git diff --check`: exit 0, no output.

No Rust source or contract input changed, so no Rust build, crate test/clippy,
contract regeneration or complete unified gate was run. macOS native execution
awaits CI; portable tests pin its existing command, byte conversion and row
shapes. No quiet-host capture, target-size performance measurement, long soak,
baseline adoption, installed-state write, hardware/HDC use or hardware evidence
was produced. Debug integration binaries and the 1 MiB correctness scale do not
establish target-size performance acceptance.

## CI

Not pushed by this teammate; no PR or CI run exists for this increment yet. The
six preceding layers have been squash merged as protected main
`e957da597d23c001157a05c7ba0a8ce1b3d38d3d` (#2585). The coordinator owns this
fresh-main layer's final review and push. CI results belong in a later delivery
record without amending an already-green head.

## Fresh-main integration targeted checks

Worktree `D:/src/ArkDeck-wt/artifact-rss-layer`, branch
`agent/xpa-025-windows-artifact-rss-layer-20261005`, based on freshly fetched
`origin/main` at `e957da597d23c001157a05c7ba0a8ce1b3d38d3d`. Only increment
`2247bcbc4554626bd46c7a9d264f20addab75600` was cherry-picked; the old stack's
commit history was not replayed. Collector and test code are unchanged from the
native signed-daemon checks above. Target: `D:/cargo-target/artifact-rss-layer`.

- `python -X utf8 -m unittest -v` for `ArtifactRssRulesTests`, the owned-child
  native RSS case, and the four existing Fixture/ReadLoop/Transport/Incremental
  classes listed above, via
  `D:/src/ArkDeck-wt/tools/artifact_rss_layer_checks.py`: exit 0, **27 passed,
  zero skips**; `artifact-rss-layer-windows.log`. The launcher clears inherited
  ArkDeck/HDC settings and real-runtime opt-ins. The signed-daemon case was
  deliberately not repeated during the acceptance window.
- The exact Ubuntu harness CI lane, `python3 -m unittest discover -s bench -t .`
  from `scripts`, ran in the existing Ubuntu-24.04 WSL distribution with
  `BENCH_TEST_DAEMON`, `BENCH_TEST_SOAK` and `BENCH_TEST_ARTIFACT_SOAK` removed:
  exit 0, **277 tests, 264 passed and 13 explicit platform/opt-in skips**;
  `artifact-rss-layer-linux-harness.log`. This includes the import audit and
  Artifact, failure-evidence, comparison and baseline-rule regressions. Mocked
  temporary baseline documents are unit outputs, not live performance captures.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: the longer fresh
  worktree path hit Windows command-line error 206 before formatting;
  `artifact-rss-layer-fmt.log`. `git diff --quiet origin/main HEAD -- rust`
  returned 0, proving identical Rust files. The same read-only fmt command on
  the shorter protected-main checkout returned 0;
  `artifact-rss-layer-fmt-short.log`.
- `sh scripts/check-sdd.sh`: exit 0; `artifact-rss-layer-sdd.log`.
- `git diff --check`: exit 0, no output.

No daemon, agentd/hoststore suite, HDC/server or port-8710 check was started in
this integration slice. Existing native signed-daemon correctness evidence is
retained without reopening that process during acceptance. Inspection of the
current Windows census, Phase A runbook and Artifact reader found no further
concrete Windows Artifact harness defect: remaining reference-host, target-size,
spread, long-soak and baseline adoption work keeps its existing acceptance gate.
No shared census, contract, generator, threshold or governance file changed.

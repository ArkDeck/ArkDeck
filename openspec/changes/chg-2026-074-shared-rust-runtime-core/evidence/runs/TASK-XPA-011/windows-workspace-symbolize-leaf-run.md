# TASK-XPA-011 — `workspace symbolize` end to end through the real CLI on Windows (WM3 GJ-5)

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM3 (GJ-5).

Base: protected `main` `7133461b6` (#2578). The handed-over `fc22d2a86` was cherry-picked
onto a fresh main-based branch; no squashed integration history is replayed.

Host: the Windows 11 x64 reference host, non-elevated. No device, HDC or board was used, no `hdc`
was run, nothing listened on `127.0.0.1:8710` because of this run, and nothing installed was read
or written. Host tests are not Windows acceptance.

## What

`arkdeck-agentd/tests/spawning/workspace_symbolize_leaf.rs` runs the real signed `arkdeck.exe`
against the signed test daemon (`signed_daemon.rs`):

1. **Registration.** `workspace project register` registers an OpenHarmony project whose
   `entry/build/default/outputs/default/mapping/sourceMaps.map` is the Swift symbolizer oracle's
   `device` source map (`crash-symbolizer-oracle`). `workspace preset register --kind symbol
   --template openharmony.arkts-symbol@1 --relative-source-map …` registers its symbol preset.
2. **The crash.** It is the one the Swift oracle's device capture published
   (`workspace-test-symbolize-oracle/artifacts/job-input-crash`, a device-bound
   `capture.diagnostics` `crash-log.txt`). It is laid into the root's Artifact store, kept, before
   the daemon starts, exactly as the macOS process test (`workspace_symbolize_process.rs`) lays it.
3. **Without a symbolizer** (no `ARKDECK_ANALYZER_PATH`), `workspace symbolize --inputs-file …` is
   refused before admission: exit 65, `invalidInput`, "workspace.symbolize-crash@1 is runtime
   unavailable: workspace.symbolPresetUnavailable", `newDispatchCount` 0.
4. **With the daemon's own build as its symbolizer**, the same leaf run as a person runs it
   (`--inputs-file` naming the project, the crash's lease and the preset; no `--target`, so the
   host scope is the project) ends `succeeded`:
   - `artifact list --job` names one `symbolized-crash.txt`, `sensitive`;
   - the report is byte for byte what `arkdeck_hoststore::symbolize_crash` writes for that map and
     dump, and resolves the frame to `entry/src/main/ets/fixture/CrashProbe.ets:30`.

**Measured leaf.** `workspace.symbolize` joins `WINDOWS_MEASURED_LEAVES`. The leaf is driven
exactly as a user drives it, and its answer depends only on a published device crash Artifact, not
on how that Artifact was captured. `arkdeck maintainer contracts export` regenerated the coverage:
`workspace.symbolize-crash@1` moves to `implemented` on Windows, and nothing else changes.

## Named capture and the handover's missing-log finding

The production Catalog selects `capture-crash-log` only when `crashLogName` is present.
`crashLogs: true` selects `capture-crash-index`; its declared dump row stays `missing`, with
zero bytes and no lease. The signed-CLI regression confirms no dump read is dispatched in that
case. With the typed `jscrash-com.example.demo-20010039-20260913235959` name, the same daemon
publishes `crash-log.txt`, with a lease and digest, and `artifact read --allow-sensitive` returns
exactly the Swift read-leg oracle's bytes. This resolves the handover finding without changing
production code or the Catalog.

The symbolize test also captures that named entry and passes the daemon's own lease to
`workspace symbolize`. The read-leg oracle's text contains no Stacktrace block, so its report
truthfully has no frames; the separate Swift crash oracle proves actual source-map resolution.
Both captures are fixture tests, never device acceptance.

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/lead-symbolize`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot, `arkdeck-cli`
built first.

| command | result |
| --- | --- |
| `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0; `symbolize-build.log` |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0; `symbolize-fmt-check.log` |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-agentd -p arkdeck-hoststore --all-targets -- -D warnings` | exit 0; `symbolize-clippy-ready.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-agentd -p arkdeck-hoststore --no-fail-fast`, with verified C: 8.3 `TEMP`/`TMP` | initial exit 101: 965 passed, 10 failed, 10 ignored; `symbolize-short-tests.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test spawning workspace_symbolize_leaf -- --nocapture`, with the same short-path environment | exit 0: 2 passed, no skipped paths; `symbolize-crash-tests.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test windows_signing_leaves -- --nocapture`, short-path environment | exit 0: 8 passed; `symbolize-path-tests.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test windows_tool_list_identity -- --nocapture`, short-path environment | exit 0: 1 passed; `symbolize-tool-list-tests.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --lib windows_registration_tests -- --nocapture`, short-path environment | exit 0: 6 passed, 1 opt-in live test ignored; `symbolize-deveco-profile-tests.log` |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0; `symbolize-sdd-final.log` |
| `git diff --check origin/main` | exit 0 |
| `arkdeck maintainer contracts check --contracts-directory openspec/contracts --fixtures-directory Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI` | exit 0, 242 checked, clean; `symbolize-contracts.log` |

Logs are retained locally under `D:/src/ArkDeck-wt/tools/logs/`; they are not committed because
native signing diagnostics include account paths. The full short-path run exposed fixture
assumptions about the packaged parent's LocalAppData virtualization. Signing and tool-list
fixtures now resolve their newly created private directory to its physical path. The DevEco
fixture uses the token's profile to avoid container ancestry and still resolves its created
directory. These edits are test-only; production path spelling, ancestor ACL and Authenticode
checks are unchanged. All ten initially failed cases pass in the targeted reruns above; the
full suite was not repeated after those fixture fixes. Ignored live tests remain opt-in; no
fixture result is a hardware verdict.

## CI

To be recorded by the next slice.

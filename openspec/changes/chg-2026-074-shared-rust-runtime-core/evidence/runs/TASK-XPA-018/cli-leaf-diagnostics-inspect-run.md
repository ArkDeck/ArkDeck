# TASK-XPA-018 — `diagnostics inspect|preview` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `1dbe5acd0` (#2218). Per the
coordinator's ruling of 2026-09-26, this PR adds no `tasks.md` line. The rest of slice C7 after
`diagnostics export` (#2210). Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001).
No control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or constitution
change. Host evidence only: a fake Runtime answering what Swift's scripted peer answered.

## What changes

- **`arkdeck diagnostics inspect --job <id> [--timeout <duration>]`** and **`arkdeck diagnostics
  preview --job <id> --artifact <id> [--max-characters <n>] [--allow-sensitive] [--timeout
  <duration>]`** are Swift's `runDiagnosticsResource` over the shared offline parser
  (`DiagnosticSessionOfflineInspector`, `DiagnosticSessionReading`,
  `DiagnosticArtifactTextPreview`), in `rust/crates/arkdeck-cli/src/diagnostics_resources.rs`:
  - the Job's whole Artifact inventory, one snapshot, paged and bounded (`artifact.list`);
  - for `inspect`, the Job's own typed request (`job.show`), then `artifact-index.json`,
    `capture-summary.json` and `markers.json` read whole (`artifact.read`), each range held to
    Swift's `ArtifactReadProjection` and the bytes to the inventory's digest;
  - the derivation: index and summary agreeing with each other and with the inventory, the
    products the capture's typed inputs asked for and which are missing, the marks (all
    `notCaptured`: a capture's reading has no screenshot timing), `notDerived`, the ring's held
    anchor (Foundation's `as? Bool`), and the alignment Swift reports (`cannotAlign`);
  - for `preview`, the one selected Artifact read whole (the explicit `--allow-sensitive` is the
    only grant a sensitive one gets), then Swift's text preview: strict UTF-8 for JSON, lossy and
    disclosed for plain text, clipped by grapheme clusters;
  - every answer says `offlineDerived` and names the parser, its version and each source's digest.
  Each request proves the contract on its own connection and both frames carry identities of the
  client's own (`client_frame_id`), as Swift's `AgentClient` names them; the leaf's one deadline
  bounds them all.
- `CLIDomainExecutorOracleContractTests`' `ScriptedRuntime` and `CountingClock` become
  file-internal so this oracle can script the same peer.

## Oracle and tests

- `CLIDiagnosticsInspectOracleContractTests` (Swift) runs the real `arkdeck` process against the
  scripted peer, the Job being Swift's recorded diagnostics Job (`Fixtures/ControlFrames`), and
  records 15 runs to `rust/tests/fixtures/diagnostics-inspect`: a complete inspection (machine and
  human), one without markers, a disagreeing index and summary, bytes served that are not the
  Artifact's, an empty inventory, an unknown marker kind, and previews of text, clipped text, a
  sensitive log refused and allowed, malformed JSON, an image, an unknown Artifact and the human
  rendering.
- `tests/diagnostics_inspect.rs` replays all 15 through the CLI: the same frames over as many
  connections, the whole script used, and the same exit status, stdout and stderr byte for byte in
  the machine mode. The human rendering is Swift's key-value outline and this CLI's pretty JSON
  (T2); it is held to the exit status and stderr.
- Unit tests pin the grapheme clipping, the disclosed replacement of invalid UTF-8, and Swift's
  ISO 8601 instants.
- `argv_fixtures.rs` replays Swift's argv fixtures for both leaves (zero deviations).

The first recording held an oracle defect of its own (a `missing` row carrying a lease, which
Swift's `ArtifactResourceProjection` refuses); it was corrected and re-recorded before any
replay was taken as evidence.

## Declared differences

- The Job request is checked as far as this leaf reads it (the closed envelope, its operation,
  target and typed inputs); the Runtime decoded the whole request when it admitted the Job.
- An index whose products fail two checks at once names the failure of the first product in
  name order; Swift's dictionary order is unspecified.
- `serde_json` refuses a tree nested more than 128 levels, where Foundation's parser goes deeper.

## Counts

- Rust CLI leaves answered: 186/209 → 188/209, of which 176 → 178 ported and 10 answered by
  name (`blockedByProductDefect`, #2211).
- `cli-parity-audit.py` on this build, registry leaves not served: category 2 (leaf missing,
  daemon routed) 10 → 8, category 3 7, category 4 6.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D
  warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and `--target
  x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-diag-final-test.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  CLIDiagnosticsInspectOracleContractTests` — exit 0 (recording, in the hub's Swift window;
  `/private/tmp/arkdeck-cli-lane-swift-diag2.log`). The comparison run against the checked-in
  oracle is left to CI's Swift lane.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.

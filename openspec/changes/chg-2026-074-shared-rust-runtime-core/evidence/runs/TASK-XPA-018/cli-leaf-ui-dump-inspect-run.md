# TASK-XPA-018 — `ui-dump inspect|hit-test` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `dc709dc3e` (#2224, `diagnostics
inspect|preview`, whose range check this reuses). This PR adds no `tasks.md` line (the
coordinator's ruling of 2026-09-26). The last
leaves of slice C7. Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No control
schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or constitution change. Host
evidence only: a fake Runtime answering what Swift's scripted peer answered.

## What changes

- **`arkdeck ui-dump inspect --job <id>`** and **`arkdeck ui-dump hit-test --job <id> --x <n>
  --y <n> [--root <identity>]`** are Swift's `emitUIDumpDerivation` over the shared offline parser
  (`UIDumpOfflineInspector`, `ViewerCaptureParser`, `ViewerHitTesting`,
  `ViewerScreenshotMapping`) and its projection (`CLIOfflineDerivation`), in
  `rust/crates/arkdeck-cli/src/ui_dump.rs`:
  - the Job's whole Artifact inventory, one snapshot; the one published, sensitive
    `ui-tree.json`, `screenshot.png` and optional `ui-dump.json`, each read whole (the leaf is the
    opt-in to read this exact capture) with every range held to Swift's `ArtifactReadProjection`
    (the one check `diagnostics inspect` already ports) and the bytes to the inventory's digest;
  - the parse: the PNG's IHDR size, the display envelope stepped past to the real window roots,
    each component's identity (`device:<id>` when unique, else `path:<i.j…>`), type, text,
    inspector identity, bounds (an object of `x`/`left` and a size or far corner, four numbers, or
    a corner string), flags, clipping, hit-test behaviour and z-order, with Foundation's bridging
    of numbers and booleans to text, and whether the coordinates are the screenshot's;
  - the hit test: the frontmost painted branch's deepest visible node under the point, within the
    clipping of every ancestor that clips, passing through transparent overlays, under an optional
    root; refused (`factsDrifted`) when the coordinates were never verified.
  Every answer says `offlineDerived` and names the parser, its version, the capture's observation
  window and each source's digest. Each request proves the contract on its own connection with
  client-assigned frame identities.
- `ScriptedRuntime` is scripted as in the `diagnostics inspect` oracle.

## Oracle and tests

- `CLIUIDumpInspectOracleContractTests` (Swift) runs the real `arkdeck` process against the
  scripted peer over an inventory built from Swift's recorded Artifact row, and records 19 runs to
  `rust/tests/fixtures/ui-dump-inspect`: a tree inside a display envelope with identities, types,
  flags, bounds and z-order spelled every way the parser reads them; hit tests inside a clip,
  clipped away, a button over a floating view, the status bar, under a root, under an unknown root
  and off screen; an unverified capture inspected and refused a hit test; and the refusals — no
  tree, no screenshot, a tree of the wrong privacy, a duplicate tree, a screenshot that is not a
  PNG, tree bytes that are not the Artifact's and an empty inventory.
- `tests/ui_dump.rs` replays all 19 through the CLI: the same frames over as many connections, the
  whole script used, and the same exit status, stdout and stderr byte for byte in the machine
  mode; the human rendering (Swift's outline, this CLI's pretty JSON, T2) is held to the exit
  status and stderr.
- Unit tests pin the envelope, identities, clipping and pass-through, the path fallback for a
  duplicate device identity, the named parse failures, and Foundation's scalar bridging.
- `argv_fixtures.rs` replays Swift's argv fixtures for both leaves (zero deviations).

## Declared differences

- A string holding a number with non-ASCII digits is parsed from its ASCII digits; Swift's
  regular expression takes the whole run and then drops it.
- `serde_json` refuses a tree nested more than 128 levels, where Foundation's parser goes deeper.

## Counts

- Rust CLI leaves answered: 188/209 → 190/209, of which 178 → 180 ported and 10 answered by name
  (`blockedByProductDefect`, #2211).
- `cli-parity-audit.py` on this build, registry leaves not served: category 2 (leaf missing,
  daemon routed) 8 → 6, category 3 7, category 4 6.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D
  warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and `--target
  x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-uidump-final-test.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLIUIDumpInspectOracleContractTests`
  — exit 0 (recording, in the hub's Swift window; `/private/tmp/arkdeck-cli-lane-swift-uidump.log`).
  The comparison run against the checked-in oracle is left to CI's Swift lane.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.

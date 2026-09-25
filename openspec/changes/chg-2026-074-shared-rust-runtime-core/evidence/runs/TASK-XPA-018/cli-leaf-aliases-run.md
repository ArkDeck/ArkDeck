# TASK-XPA-018 — the compatibility aliases `device list|show` and `agentd …` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `1bfa52054` (#2202); no stack. The first slice
(C0) of the CLI remaining-leaves lane. Nothing here is device evidence (POL-VERIFY-001,
POL-MODE-001). No Swift source or test, control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change. Host evidence only: temporary homes, recording launchd
stand-ins and a fake Runtime; nothing installed, loaded, restarted or booted out, no installed
service touched.

## What changes

- **`arkdeck device list` and `arkdeck device show`** (registry `legacy`, replaced by
  `arkdeck target list` and `arkdeck target show --target <id>`) send one parameterless
  `target.list` and emit its answer, as Swift's `runDevice` does for both verbs. They take only the
  client options the registry declares (`--output`, `--json`, `--control-request-id`, `--socket`);
  `--timeout` and `--target` are refused as Swift's registry pass refuses them. The machine answer
  names the leaf the caller typed and carries `meta.lifecycle`
  (`{"status":"legacy","replacementArgvPattern":…,"removalVersion":null}`); the human rendering
  writes Swift's `warnIfLegacy` line to stderr first. The target-presentation check the `target …`
  leaves apply is now keyed on the leaf, not on the wire method: Swift's `runDevice` emits the
  `target.list` reply as the Runtime answered it, without `runTarget`'s validator.
- **`arkdeck agentd install|update|restart|status|verify|uninstall`** (registry `deprecated`,
  replaced by `arkdeck runtime service …`) reach the same LaunchAgent handler as the current
  spelling, as Swift's `runAgentDaemon(spelledAs: "agentd")` does:
  - the answer names `agentd.<verb>`; `--output json` adds `meta.lifecycle`, the human rendering
    writes the deprecation warning to stderr before anything runs, the legacy `--json` warns
    nowhere. `serve_runtime_service` now applies both, so the current spelling is unchanged (its
    registry status is `current`, which adds nothing);
  - every diagnostic is written in the spelling the caller typed (`ServiceHost::spelling`), as
    Swift's `spelling` does;
  - `agentd update` keeps the installed legacy workspace pair (`workspaceProjectPath`,
    `devecoSDKPath`) when the caller omits it (`preservesLegacyWorkspace`); the current spelling
    still drops it;
  - `agentd install` is Swift's compatibility install from path inputs, never the typed bootstrap:
    it takes `update`'s options (`agentdInstallOptions`), and — Swift's `subcommand == "update"`
    branches — reads nothing of an installed service: `--hdc` is required (no status read, so
    launchd is asked nothing before the refusal), and an omitted ArkTrace descriptor or ArkForge lane
    is none. It installs through the same `install` as `update` (cutover preflight, analyzer gate,
    signing-receipt refusal of ruling 3), so the typed `runtime service install` refusal does not
    apply to it.

## Declared differences from Swift

- **Human-mode failure prefix.** Swift writes `arkdeck <root>: <message>` (`dispatch`'s
  `path[0]`, e.g. `arkdeck agentd: …`); the Rust LaunchAgent leaves keep their existing
  `arkdeck <command>: <message>` (`arkdeck agentd.install: …`). Stderr prose is T2; the exit status
  and the empty stdout are Swift's.
- **The signing-preset refusal (ruling 3) applies to both `agentd install` and `agentd update`**,
  as it applies to `runtime service update`: Swift passes the same `refreshSigningAccessIfInstalled`
  to both spellings, and this CLI still has no signing-credential owner (Q8). The coordinator's
  follow-up replaces the refusal with the re-record once the signing leaves land.

## Tests

- `read_leaves.rs::both_legacy_device_spellings_read_the_target_list`: both verbs against a fake
  Runtime serving Swift's recorded `target.list` answer (`ControlFrames/target.list.jsonl`): one
  `target.list` with no parameters, the envelope's command and lifecycle, and the human warning on
  stderr before the answer on stdout.
- `runtime_service.rs::agentd_update_keeps_the_legacy_workspace_pair_and_agentd_install_carries_nothing_over`:
  three temporary homes installed with the closed demo workspace pair, an ArkForge release unit and
  a pinned ArkTrace descriptor. `runtime service update` drops the pair; `agentd update` without
  `--hdc` or the pair keeps the HDC, the pair, the lane and the descriptor; `agentd install` without
  `--hdc` is refused with launchd never asked and the home unchanged, and with it installs no pair,
  no lane and no descriptor.
- `runtime_service.rs::agentd_diagnostics_name_the_agentd_spelling`: `update`, `verify --job` and
  `restart` refusals name `agentd`.
- `runtime_service.rs::the_cli_answers_the_agentd_spelling_as_deprecated`: the process over a
  relocated home (no launchd reached): envelope command and lifecycle, the current spelling without
  one, the human warning, the bare legacy document, `agentd install` refusing a missing `--hdc` and
  `update`-foreign options, and all six listed by `commands`.
- `argv_fixtures.rs` replays Swift's argv fixtures for the eight newly served leaves with the rest
  (zero deviations).

Mutation check, against a passing baseline, each reverted after (script
`/private/tmp/arkdeck-cli-lane-mut.py`): reading the installed status for `install` too; preserving
the ArkTrace descriptor, or the ArkForge lane, for `install` too; preserving the workspace pair for
every spelling, or for none; keeping the target-presentation check keyed on the wire method. Each
of the six fails a named test above (the first five
`agentd_update_keeps_the_legacy_workspace_pair_and_agentd_install_carries_nothing_over`, the last
`both_legacy_device_spellings_read_the_target_list`).

## Counts

- Rust CLI served leaves: 137/209 → 145/209 (`arkdeck commands --output json`).
- `cli-parity-audit.py` on this build, registry leaves not served: category 2 (leaf missing, daemon
  routed) 41, category 3 (daemon or host owner missing) 15, category 4 (tombstone per §12) 8.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` —
  exit 0; also with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` —
  exit 0 each.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-aliases-test-all.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.

## CI

Pending; recorded by the next slice.

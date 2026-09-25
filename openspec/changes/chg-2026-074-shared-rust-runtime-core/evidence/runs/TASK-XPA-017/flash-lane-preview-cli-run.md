# `flash lane-preview` on the Rust CLI (TASK-XPA-017, M4-3a)

`flash lane-preview` is the last Flash observation leaf of Swift's CLI that
the Rust CLI did not serve. It is one request: Swift's `runFlashObservation`
sends `flash.lanePlanPreview`, the 1.x wire spelling CLI spec §12 freezes,
with the Target, the profile under the Runtime's `profileReference` and the
imported archive's digest, and prints the Runtime's answer.

The Rust CLI now serves it as Swift's CLI does:

- The parse follows Swift's registry. The three options are required, in the
  registry's order, and the digest must be 64 lowercase hex digits
  (`hexDigest(length: 64)`). Anything else is refused at parse with
  `invalidOption` (exit 64) and never reaches the Runtime. Swift's daemon is
  more lenient and takes any case, but its parser refuses first.
- The request goes out as `flash.lanePlanPreview` with `targetId`,
  `profileReference` and `archiveSha256`. The answer is printed as the
  Runtime gives it, whether a preview state or a refusal.

Against Swift's daemon the leaf prints the preview. Against the Rust daemon,
which does not route `flash.lanePlanPreview` yet (it waits for the upstream
ArkForge client change), it prints that daemon's refusal: `rejected`, "this
method is unavailable in the read-only Rust foundation", shown as
`operationFailed`.

| Already on `main` | This change | Still remaining (M4 CLI) |
|---|---|---|
| `flash device-access`, `bootloader-status`, `prerequisites`, `reconcile-alias`, `bind-loader`; `recovery flash-invocation list\|status\|start\|evaluate` and the legacy `debug` spellings | `flash lane-preview`; the digest grammar of `recovery flash-invocation evaluate` | `flash run`, a domain leaf (below); `flash install-binding`, a legacy in-process leaf that Q8 decides |

## Found while porting

**`recovery flash-invocation evaluate` skipped its digest grammar (#2166).**
Swift's registry declares `--source-sha256` and `--build-sha256` as
`hexDigest(length: 64)` on the current spelling, so its parser refuses an
uppercase or short digest (`invalidOption`, 64) before it reads the action
document. The Rust leaf sent both to the Runtime, which refused them there
(`rejected`, `invalidProvenance(...)`).

The leaf now refuses them at parse, naming the leaf and the option, as
Swift's parser does. The legacy `debug evaluate` declares both options
`opaque` in Swift's registry. It still sends them, and the Runtime's refusal
is the one Swift's oracle recorded. The test drives both halves from the
oracle's two provenance exchanges.

**A duplicated M4-4b3 bullet in `tasks.md`.** `openspec/changes/*/tasks.md`
merges with `merge=union`. When #2162 was rebased, the union kept both the
pre-rebase bullet ("Routed methods stay 101/105") and the rebased one
("102/105 with #2163"), and both reached `main`. The stale one is deleted.
`scripts/check_union_merge.py` did not catch it because it refuses only
identical bullets, and these two differ by one clause.

## Differences from Swift

- **Wording of a missing option.** Swift's registry parser answers first:
  "\`flash lane-preview\` requires --target target-id", with `details`
  naming the command and option. This CLI answers with the wording of its
  other Flash leaves, which is Swift's handler wording: "flash lane-preview
  requires --target". The code and exit status are the same.
  - The registry's wording and details for every leaf are queued as CLI item
    a3 (TASK-XPA-018).
  - The digest refusal already uses the registry parser's own words.
- **Fullwidth digests are refused at parse.** Swift's `Character.isHexDigit`
  also accepts the fullwidth digits and letters, so Swift's parser passes a
  64-character fullwidth lowercase digest on to the Runtime. On both leaves
  this CLI refuses such a digest at parse instead, as it does for its other
  `hexDigest` options, and sends nothing. The difference fails closed: a
  request Swift's CLI would send is not sent, and no request is sent that
  Swift's CLI would refuse.

## Not in this slice

- **`flash run`** is a Swift domain leaf. It builds its request through
  `runDomainOperation` and `AgentRuntimeExecutor`, the machinery shared by
  every domain leaf (`debug hap`, `screen capture`, `input tap`, …). The Rust
  CLI has none of that machinery yet, and the Rust daemon admits no Flash
  yet.
- **`flash install-binding`** is a legacy in-process leaf. Ruling Q8 decides
  whether it is ported or tombstoned.

Nothing else changes:

- No daemon change: routed methods stay 104/105.
- No contract input changes.
- `openspec/contracts/cli-feature-coverage.json` is the Swift CLI's export
  and is unchanged.

## Tests

| Test | What it holds |
| --- | --- |
| `argv_fixtures.rs` `every_copied_swift_argv_fixture_replays_but_the_known_deviations` | Swift's `flash.lane-preview.json`, copied byte for byte: its seven cases replay (dispatch, help, unknown, duplicate and missing options, `jsonl` refused, `--socket`) with no new deviation |
| `argv_fixtures.rs` `help_and_completion_render_the_registry_this_cli_serves` | Every shell's completion names `flash lane-preview`. The example of a leaf this CLI refuses is now `flash install-binding` |
| `flash_host_facts.rs` `lane_preview_sends_its_three_parameters_under_the_1x_method` | Exactly one `flash.lanePlanPreview` request with the three parameters under the Runtime's names. Each of the three states in Swift's committed control frames is printed as answered, and the `notFound` refusal reaches the caller as `resourceNotFound` with the Runtime's words |
| `flash_host_facts.rs` `lane_preview_refuses_at_parse_what_swifts_registry_refuses` | Each missing option in the registry's order, then an uppercase and a 63-digit digest: `invalidOption`, exit 64, no connection |
| `flash_invocation_broker.rs` `a_pinned_digest_outside_the_current_grammar_is_refused_at_parse` | The oracle's `evaluate.provenance.uppercase` and `.short` digests: the current spelling refuses them at parse, naming the option, before reading the action; the legacy spelling sends them and prints Swift's `invalidProvenance` refusal |

## Local targeted checks

Run on this branch, at base `c6f38e7e`. Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-m4-lane-preview-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-m4-lane-preview-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0; 258 passed (`arkdeck-m4-lane-preview-cli-test.log`) |
| Mutations | four, one at a time: drop the wire mapping; drop the digest grammar; apply the evaluate grammar to the legacy spelling too; send `deviceProfile` unrenamed | each fails its test; sources restored by digest, and the three touched test binaries rerun green (`arkdeck-m4-lane-preview-rerun.log`) |
| Contract drift | `generate-contract.py --check` (validation venv); no contract input changed, run as a confirmation | exit 0; 105 methods, 1009 shapes (`arkdeck-m4-lane-preview-contract.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`arkdeck-m4-lane-preview-sdd.log`) |

The following were not run, because this change touches no input they read:

- the Swift tests (no Swift source changed);
- the other crates (`arkdeck-cli` has no dependents).

## CI

- This change: pending.
- #2166 (M4-5, head `14a85016`): guard run 36089656984 and swift run
  36089657061, both succeeded. Merged as `c6f38e7e`.

Host-process evidence only. The Runtime is a fake that answers Swift's
recorded answers. No device was used, and no installed service was touched.

# TASK-XPA-018 — `trace probe` on the Rust CLI (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is the first leaf of CLI batch 1's
slice 15, as the hub split it. Base: `main` `4137506c3` (#2177), independent
of the continuation stack (#2178, #2179).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). Only
`arkdeck-cli` changes. No Runtime, control schema, corpus, Catalog, Swift,
`openspec/contracts`, `openspec/specs` or constitution change. The Rust
daemon already routes `trace.probe`.

## What changes

Swift's handler for `trace probe --target <id>` sends one `trace.probe` with
the target as given, and emits the answer as the Runtime gave it; it checks
nothing beyond the client's own contract checks. This CLI now does the same
through its one-method request path:

- the path, its `--target` and the parameters;
- the legacy `--json` flag. Swift's registry declares it for this leaf, and
  this CLI prints the raw answer for it as it does for `debug probe`. It
  still excludes `--output`.

Swift's argv fixture for the leaf (seven cases) is copied unchanged into
`rust/tests/fixtures/current-cli-argv`, so `arkdeck commands` lists the leaf.

## Found in passing, not changed here

- **Legacy `--json`**: Swift's registry declares it on 189 of its 200
  executable leaves. This CLI accepts it on `debug probe`, `trace probe` and
  the service leaves only, and refuses it everywhere else. Swift's argv
  corpus has no `--json` case, so the replay cannot see it.
- **Legacy `--json` output**: Swift prints the raw answer through
  `CanonicalJSONEncoders.canonicalPretty()` (`legacyDocument`). This CLI
  writes compact canonical JSON; `debug probe`'s test only parses it.

Both are reported to the hub as one slice of their own.

## Tests

| Test | What it holds |
| --- | --- |
| `trace_probe.rs::the_probe_takes_its_target_and_the_legacy_raw_document` | The path, method and parameters; `--json` accepted and still exclusive with `--output`; the missing target refused in Swift's registry words, naming the leaf |
| `trace_probe.rs::runtime::the_probe_sends_its_target_and_emits_the_runtimes_answer` (macOS) | Against a fake Runtime serving Swift's daemon's recorded `trace.probe` answer: exactly one request for the target; the envelope's result, and the human rendering, are that answer |
| `trace_probe.rs::runtime::a_refusal_is_the_runtimes_own` (macOS) | A `notFound` refusal is `resourceNotFound` (65) with the Runtime's words |
| `argv_fixtures.rs` | The seven copied cases replay with no new deviation |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-tp-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-tp-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 279 passed, none failed (`arkdeck-tp-test.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | exit 0 (`arkdeck-tp-readonly.log`) |
| Audit | `cli-parity-audit.py <this build>` | 171 / 56 / 14 / 15; 131 of 209 leaves served (`arkdeck-tp-audit.md`). The last main figures recorded were 169 / 58 / 14 / 15 and 130, with #2171 and #2172; #2173 and #2177 add no leaf |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-tp-sdd.log`) |

Not run, because no input they read changed: `generate-contract.py --check`
and the Swift tests.

## CI

Pending.

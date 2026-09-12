# Import upload on current main — 2026-09-12

Base: `1fd85b931fdef1416d41baebfe8bad0cf8d32b5e` (published Target #1870 and Job events included). This is the independently deliverable upload phase of TASK-XPA-013. It does not complete Artifact publication, reference/release ownership, installed-owner cutover or hardware/GJ acceptance.

## Delivered scope and branch value

The isolated Rust daemon now owns begin, append, progress inspect and abort of current durable Import uploads. Typed CLI commands can create a new bounded upload through the actual Target owner, rediscover an existing Swift-written upload, continue exactly at its committed prefix, and persist an abort tombstone. A lost append reply triggers bounded same-request inspection/resume; unknown commit is inspected once and never replayed. The native fixture/process tests exercise real RPC and CLI paths, not an unconnected library prototype.

New begin resolves `TargetStore::resolve_import_binding` under the existing Target owner locks and strict document decoder. It checks exact revision and stores the kind-specific snapshot: omitted identity/revision for workspace patches, physical identity for Flash, and the actual adopted connect-key digest for HAP/native libraries without a canonical alias. HDC imports with a canonical alias remain unavailable pending the real live route owner. Caller JSON cannot inject a binding, route, App provenance or validation facts.

Commit, release and Job-reference inspection remain explicitly unavailable. Consequently the current upload CLI reports the unavailable commit phase after successfully staging all bytes; the same request can be rediscovered or aborted. `artifact import inspect` remains the published reference-inspection method, `artifact.import.inspection`; it does not fall through to ordinary `artifact.inspect`. No receipt is fabricated and no device dispatch is reachable through this slice.

The prior HAP publication work at `708dab9a` requires new native publication/readback evidence, its commit schema and complete Artifact writer coordination. Those files, tests and routing were excluded from this PR, together with the old Export ancestry. The complete work is preserved in `/private/tmp/xpa013-import-hap-checkpoint-708dab9a.bundle`, verified by `git bundle verify`; SHA-256 `8e870196e1d144138efa3f3791808ed4a8da2ffa6547958cffe35f826fdb97f3`. The bundle records HEAD `708dab9adb800a3c217241193eca740ab70a9f5e` and requires published base `0dad7599e1d164ca7584ae8fdff65865a0961035`. The parent also retained a broader branch preservation bundle. No new dependencies were added.

## Verification on this extracted implementation

The targeted batch completed with exit 0, tool session `2069`. Commands ran in the isolated worktree's `rust` directory with `CARGO_BUILD_JOBS=2`:

```sh
cargo test -p arkdeck-hoststore --test import_target --test import_upload
cargo test -p arkdeck-contract --test imports
cargo test -p arkdeck-cli
cargo test -p arkdeck-control --test read_only
cargo clippy --workspace --all-targets -- -D warnings
cargo build --workspace --bins
python3 scripts/check-import-upload-owner.py
cargo fmt --all --check
python3 scripts/generate-contract.py --check
```

- Target/native binding integration: 4 passed; exact snapshots for all four kinds, stale/missing/injected authority refusal, canonical-alias route unavailability, and corrupted/linked Target document refusal.
- Import upload owner: 13 passed and one ignored helper entry point that is invoked by its parent test. Five actual SIGKILL windows asserted signal 9 and recovered only durable checkpoints.
- Import contracts: 5 passed. CLI crate: 82 passed, including 8 Import tests with the retained 41 native argv vectors and the existing Target/events suites. Control integration: 15 passed. Total: 119 passed.
- Workspace all-target Clippy with warnings denied and all binaries passed.
- Actual daemon/CLI harness passed native upload parity, new upload through actual direct Target binding, different physical/route digests, dropped successful append reply, bounded inspect/resume, restart, source identity changes, abort tombstones, missing Target and canonical-alias refusal, and explicit unavailable publication/reference seams. The proxy observed one append send for the lost-reply scenario and retained the exact request/import identity.
- Formatting and generator check passed: 105 methods, 598 recorded shapes. The v2 checkout manifest was regenerated with `python3 rust/scripts/generate-contract.py --write`, without a baseline-revision override.

Raw batch log: `import-upload-current-main-rust.log`; SHA-256 `e07354a4127d3b801e6cfb4e04d4f854ff928b16c8f1f29947c09de154add10c`. An initial new Target test vector used fewer than the existing native-library minimum of 64 bytes; the vector was corrected, keeping the contract unchanged, before this successful batch. The excluded HAP prototype's previously failing vectors are not claimed as validated by this PR.

## Reused native evidence

No new Swift producer or App build was run in this subtask; the parent controls that validation window. The original upload producer evidence remains separately identified in `import-upload-run.md` and `native-import-producer-macos-20260912`. Seven retained upload files and the source-manifest SHA-256 were rechecked against that original provenance. All 46 retained frames for the six Import schemas were independently validated with Draft 2020-12 jsonschema.

Four actual Swift Target producer files from `/private/tmp/xpa-target-native-r1` and `/private/tmp/xpa-target-alias-native-r1` were copied without byte changes to `rust/tests/fixtures/import-target-current`; each source/path/hash is recorded in its provenance. The real process harness copies them into disposable private state before exercising the existing owner. They are host-test fixtures and establish no current hardware authority or acceptance.

## Final integration gate

The current scope requires seven exact extensions: six `spec/control/methods/artifact.import.{begin,append,abort,inspect,inspection,release}.json` paths plus `spec/baselines/swift-single-v1.json`. The Task declaration and final commit trailers use these exact paths, with no inherited Export extension or broad pattern. Scope preflight runs after the final local commit. The parent owns the final unified Swift/App/Rust gate and push/PR creation; this targeted report does not claim those checks have already run.

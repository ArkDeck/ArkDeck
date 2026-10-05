# TASK-XPA-011: Windows retained tool identity at the mutation boundary

A real Windows `debug.hap@1` smoke reached successful target/model/firmware
readbacks, then failed before its first mutation with
`authorizationRequired: fresh tool identity cannot be proved`. The retained
result was known failed, with no outstanding residue and no produced Artifacts.
These sanitized diagnostic facts motivate this repair; this run note creates no
hardware evidence and claims no Journey pass.

`ProcessDispatch` implemented `HdcDispatch::mutation_identity_current` only on
macOS. Windows therefore inherited the trait's unconditional `false`, even
though its existing `VerifiedTool::launch_identity` already revalidates the
retained file handle, metadata, pinned SHA-256 and current path/file identity.
The same override now compiles on Windows. The default trait refusal, managed
server's exact process/listener identity check, registered Windows HDC tuples,
Catalog, RuntimeCapability consumption and write-ahead intent boundaries remain
unchanged. This fixes implementation reachability without changing trust policy.

The Windows regression uses an actual copy of its own executable. It proves
fresh identity without dispatch, verifies retained data/name replacement is
denied, then changes only the fixture's last-write timestamp through an
attribute-only handle and requires both tool and mutation identity checks to
refuse with zero subprocess calls. An unknown dispatcher still returns false.
The existing argv test now expects fresh tool proof; it explicitly grants no
mutation authority. No real HDC, device, Runtime or account state is accessed.

## Local targeted checks

All Rust checks use `CARGO_BUILD_JOBS=2`, isolated target
`D:/cargo-target/windows-mutation-tool-identity`, and the shared slot runner for
heavy checks. Logs are in the operator workspace and are not committed.

- Before the cfg repair, the focused retained-file regression failed at its
  fresh-identity assertion, with zero dispatch: exit 1;
  `tools/logs/windows-mutation-identity-regression-red.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `tools/logs/windows-mutation-identity-fmt-final.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-provider-hdc --all-targets -- -D warnings`:
  exit 0; `tools/logs/windows-mutation-identity-provider-clippy.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-hdc`: exit 0,
  201 tests passed, no ignored or skipped tests;
  `tools/logs/windows-mutation-identity-provider-test.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; `tools/logs/windows-mutation-identity-dependent-clippy.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-hdc --test windows_managed_hdc mutation_identity`
  with a verified actual 8.3 TEMP/TMP alias: exit 0, both focused tests passed;
  `tools/logs/windows-mutation-identity-short-temp.log`.
- `sh scripts/check-sdd.sh` through the installed Git shell: exit 0;
  `tools/logs/windows-mutation-identity-sdd-final.log`.
- `git diff --check`: exit 0.

macOS execution and the protected-main live retry belong to CI and the
integration owner's fresh RC. The failed Job is retained; it is not replayed
by these tests.

Direct-consumer execution tests are deferred while the installed account Runtime
and its owned HDC endpoint remain live. The integration owner will run the
necessary targeted checks once that window is closed. Direct-consumer Clippy
above performs no Runtime or device operation.

## CI

Not pushed. The integration owner reviews and publishes this increment; required
`guard` and `swift` checks must pass on its final pushed head before merge.

# Rust workspace

The runtime, CLI, and providers are the crates in this directory. Build and
test them from the repository root:

```sh
python3 rust/scripts/run-cargo.py fmt --all --check
python3 rust/scripts/run-cargo.py clippy -p <crate> --all-targets -- -D warnings
python3 rust/scripts/run-cargo.py test -p <crate>
python3 rust/scripts/check-arkforge-pin.py
```

The root [justfile](../justfile) wraps the same entry points (`just build-rust`,
`just test-rust`, `just lint`, `just pin`). Contributor setup is in
[CONTRIBUTING.md](../CONTRIBUTING.md). Crate membership and the ArkForge pin
are in [Cargo.toml](Cargo.toml).

The previous append-only development log is
[docs/rust/development-log.md](../docs/rust/development-log.md).

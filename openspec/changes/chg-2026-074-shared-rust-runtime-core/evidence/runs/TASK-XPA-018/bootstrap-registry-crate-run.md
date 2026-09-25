# TASK-XPA-018 — the Bootstrap registry's bundle and HDC tool owners as their own crate (`arkdeck-bootstrap`)

Cutover blocker ③, first of two PRs. The typed `runtime service install`
(`--bundle/--bundle-generation/--tool/--tool-generation`) and `runtime service
uninstall` must hold and release the Bootstrap registry's `installation`
reference as Swift's CLI does (`BootstrapBundleRegistry.acquire/retainOnly/
releaseAll`, `BootstrapToolRegistry.initializeServiceSelection`). The CLI and
the Runtime then both write `…/ArkDeck/Bootstrap/v1/bundles.json` and
`tools.json`, so the coordinator ruled (协调会话 2026-09-26): one
implementation and one lock protocol for both, extracted into a narrow crate
that `arkdeck-hoststore` and `arkdeck-cli` depend on; no `arkdeck-cli →
arkdeck-hoststore` edge (the CLI must not link capability, trusted-fact or
reservation stores).

This PR is the extraction alone, with no behavior change. The next PR wires
the CLI's typed install and uninstall to it.

Branch `agent/xpa-018-bootstrap-registry-crate`. Developed and fully tested
on protected main `546654b74` (#2212); before the push it was rebased onto
`da76e3e8e` (#2210, #2214, #2215: the CLI's diagnostics export, the isolated
agentd's start admission and the workspace project projection — none touches a
moved file), and the checks that intersect those were run again (below).

## What moved

`rust/crates/arkdeck-bootstrap` (new; depends on `arkdeck-contract` and
`arkdeck-platform` only, unsafe forbidden like every crate but the platform):

- the frozen index codecs `decode_bundles`, `decode_tools`,
  `decode_tool_identity` (`registry.rs`), with the frozen-document codec the
  host store's other decoders share (`DecodeError`, `DecodedStore`,
  `roundtrip`, moved out of `arkdeck-hoststore/src/lib.rs`);
- the bundle owner `BundleRegistryReadStore` (open, list, inspect, content
  verification, registration, retirement) and `bundle_content`;
- the HDC tool owner `ToolRegistryStore` (open, `open_or_create`, list,
  inspect, registration, retirement) with `tool_content` and `tool_macho`;
- the HDC selection ledger (`tool_selection_ledger.rs`: the initial service
  selection, the selection WAL, `startup_selection`,
  `cutover_pending_selection`) and its Swift oracle replay
  (`tool_selection_ledger_tests.rs`, `rust/tests/fixtures/tool-selection-registry`);
- `RetirementRoot`/`IndexSnapshot`, the retirement's lock-and-index binding,
  which the DevEco registry's retirement uses too.

Every file moved with `git mv`; the only edits inside them are visibility
(`root()`/`path()` accessors, `verify_record`, `verify_index`,
`validate_index`, `row` and `cutover_pending_selection` public for the
Runtime's composition below), the moved `ToolRegistryStore::open_or_create`,
and the split of `tool_retirement.rs` (HDC half here, DevEco half in the host
store).

`arkdeck-hoststore` keeps, over those owners:

- the paged inventories `runtime.bundle.list` and `runtime.tool.list`, which
  publish through the Session snapshot pager: now `BootstrapListPage::
  list_page` (`bundle_list_owner.rs`, `tool_list_owner.rs`), since an inherent
  method cannot be added to another crate's type;
- the DevEco toolchain registry (register, pins, retirement through
  `arkdeck_bootstrap::RetirementRoot`);
- `pub use` of every moved public name, so `arkdeck_hoststore::…` paths are
  unchanged for `arkdeck-agentd`, `arkdeck-soak`, the examples, the
  integration tests and the differential harness binary.

`arkdeck-agentd`'s `BootstrapReaders` imports the one new trait; nothing else
outside these crates changed.

Also: `rust/Cargo.toml` (workspace member path), `rust/deny.toml` (the
first-party crate allowlist), `rust/scripts/check-readonly.py` (the new crate
and the `arkdeck-hoststore → arkdeck-bootstrap` edge in `assert_boundaries()`,
with the reason), `rust/scripts/hoststore-shadow.py` (the moved codec's path in
its hashed inputs) and `rust/README.md` (the crate's paragraph).

## Why this cut

The CLI needs the bundle index (for the installation reference) and the tool
index with its ledger (for the initial selection). Both are inherent methods of
the two store types, and Rust allows inherent methods only in the defining
crate, so the store types move with every operation that needs nothing but
the platform and the contract crates: registration, bundle and HDC retirement,
and the ledger all write these two indexes, so they belong to the one
implementation. What stays in the host store needs the host store: the
snapshot pager (a Runtime-wide primitive) and the DevEco registry (its pins
resolve workspace toolchains). DevEco's own owner and its initialization of an
absent `bundles.json` therefore stay in the host store; they take the same
`.lock` through the same platform primitive (`HostDirectory::lock_document`,
`LOCK_EX|LOCK_NB`, as Swift's `BootstrapBundleRegistry.locked`).

## Behavior

None changed. Every moved test moved with its module and runs in the new
crate: 26 (25 run, the one native Swift-receipt test still ignored) — the
bundle registration 3, bundle retirement 5, tool content 2, tool registration
6, tool registry 1, HDC retirement 5 and the ledger's 4, among them
`every_swift_timeline_plays_again_byte_for_byte` over the recorded Swift
timelines. The host store keeps the DevEco retirement 2, the bundle list 8 and
the tool list 6.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s31-*.log`. Changed crates: `arkdeck-bootstrap` (new),
`arkdeck-hoststore`, `arkdeck-agentd`; direct dependents of the host store:
`arkdeck-agentd`, `arkdeck-soak`.

On `546654b74`:

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `arkdeck-s31-fmt.log` |
| `cargo clippy --all-targets -- -D warnings`, `-p arkdeck-bootstrap -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak` | 0 | `arkdeck-s31-clippy1.log` |
| the same for `arkdeck-bootstrap` and `arkdeck-hoststore` with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` | 0, 0 | `arkdeck-s31-clippy-x86_64-*.log` |
| `cargo test -p arkdeck-bootstrap` | 0: 25 passed, 1 existing ignored | `arkdeck-s31-test-bootstrap.log` |
| `cargo test -p arkdeck-hoststore --no-fail-fast` | 0: 85 result lines, 625 passed, 0 failed, 13 existing ignored | `arkdeck-s31-test-hoststore.log` |
| `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test -p arkdeck-agentd -p arkdeck-soak --no-fail-fast` | 0: 24 result lines, 176 passed, 0 failed | `arkdeck-s31-test-agentd.log` |
| `python rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv; the new crate and edge in `assert_boundaries()`) | 0, `PASS` | `arkdeck-s31-readonly.log` |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) | `arkdeck-s31-sdd.log` |

After the rebase onto `da76e3e8e`:

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `arkdeck-s31-fmt-r.log` |
| `cargo clippy --all-targets -- -D warnings` for the same four crates | 0 | `arkdeck-s31-clippy-r.log` |
| `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test -p arkdeck-bootstrap -p arkdeck-hoststore -p arkdeck-agentd --no-fail-fast --lib` with `bundle_registry_read`, `bootstrap_missing_lock`, `deveco_registry_read`, `tool_list_native`, `tool_retirement_native`, `tool_macho`, `workspace_availability_oracle`, `cutover_preflight`, `production_composition` and `managed_hdc_process` | 0: 12 result lines, 386 passed, 0 failed, 9 existing ignored | `arkdeck-s31-test-r.log` |

The readonly check's recording directory was removed afterwards; no test
process or temporary store was left.

Not run: `generate-contract.py --check` (no contract input changed), Swift or
App tests (no Swift or App file changed), the hoststore shadow slow lane (a
Swift build; its inputs only follow the moved codec file), the full suites
again after the rebase (the three commits it brought in touch no moved file;
CI runs them).

## CI

Pending; recorded by the next slice.

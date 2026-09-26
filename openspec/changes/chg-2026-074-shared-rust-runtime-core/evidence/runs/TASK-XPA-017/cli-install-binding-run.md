# `flash install-binding` on the Rust CLI, over the Rockchip binding's own crate (TASK-XPA-017, M4-3c)

`flash install-binding [--rebind]` is the one way the product creates the
DAYU200's first durable cross-mode binding. The Runtime's
`flash.bind-current-loader` moves an existing binding along a Loader's
lineage, but refuses when none is installed ("durable Rockchip binding is not
installed", Swift `RockchipBootloaderStatus.swift` `loadExisting()`). Once the
Swift CLI retires at the cutover, a new board could not be bound without this
leaf.

Swift runs it in the CLI's own process (`RockchipDeviceBindingInstallation`):

1. It reads the host's I/O Registry once and requires exactly one DAYU200 in
   a registered personality, HDC-normal or Loader.
2. It adopts that identity into the binding store of the account's
   Application Support root (`ArkDeck/rockchip-binding.json`).
3. Nothing is dispatched to the board.

The Rust CLI now does the same.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| Every other Flash leaf of the CLI, `flash run` (#2235) | `flash install-binding`; the binding store and the DAYU200 personalities in their own crate | The production lane and the Rockchip host (F6) |

## The crate (the coordinating session's ruling of 2026-09-26)

The CLI links no Runtime store: `check-readonly.py`'s edge table and the
coordinating session's ruling of the same day. The binding store lived in
`arkdeck-hoststore`, and the DAYU200 personalities in
`arkdeck-provider-hdc`, neither of which the CLI may link. The binding holds
a device's durable identity, which the Runtime makes the premise of every
Flash admission, so it is not a Bootstrap registry either:
`arkdeck-bootstrap` holds content and references only, and grants no device
or Runtime authority.

The new `arkdeck-rockchip-binding` holds the store's file layer and the
personalities. One implementation and one lock serve the Runtime and the
CLI, as #2216 did for the Bootstrap registry:

- the root owner-only;
- the binding's lock;
- the strict read and its refusals;
- Swift's `install`, which refuses to clobber a binding published outside
  the lock unless it is a rebind;
- the Loader binding owner's two compare-and-swap writes that need no
  evidence rules;
- the document's encoding and validation;
- `RockchipProductBindingBootstrap.installCurrentTarget` over one census;
- the DAYU200 personalities (`isHDCNormal`, `isLoader`,
  `registeredDAYU200Identities`).

It depends on `arkdeck-contract` and `arkdeck-platform` alone.

What a binding's evidence means stays the Runtime's, in
`arkdeck-hoststore`: its lineage edge, a reactivation, its HDC-normal alias,
whether it covers a Target, and the one write that needs them (the switch to
an advanced Target). They are functions over the snapshot now (the
`BindingEvidence` trait). `arkdeck-provider-hdc` re-exports the
personalities from the new crate; nothing is copied.

New edges in `check-readonly.py`:

- `arkdeck-cli`, `arkdeck-hoststore` and `arkdeck-provider-hdc` each gain
  `arkdeck-rockchip-binding`;
- `arkdeck-rockchip-binding` itself depends on the contract and platform
  crates only.

Each edge cites the ruling. `rust/deny.toml` allows the new workspace crate
by name, as every workspace crate is (CI's first run of this PR stopped at
cargo-deny's `bans` without it), and `rust/README.md`'s crate map names it.

## The leaf

The Rust CLI answers `flash install-binding [--rebind]` as Swift's
`runInstallBinding` does:

- its parse follows Swift's registry (Swift's argv fixture replays);
- the census is the host's I/O Registry
  (`arkdeck_platform::usb_host_devices`);
- the root is the account's `…/Library/Application Support/ArkDeck`, with the
  home resolved as Swift resolves it (`CFFIXED_USER_HOME`, else the password
  database);
- the receipt is Swift's: `created`, `bindingRevision` and `usbTopology` in
  the envelope, whose `meta.lifecycle` says `legacy`; or the human lines
  (installed or unchanged, the revision, the topology, the serial's digest,
  and `device mutation dispatch: 0`);
- a refusal escapes Swift's handler as its description: `arkdeck flash:
  <error>` on stderr and exit 1, in every output mode, as in Swift;
- like Swift's handler, it does not warn that the leaf is legacy.

Off macOS it answers `unsupportedOnPlatform`.

One fix found by the oracle: a lock that cannot be opened (a link in its
place) was reported as "binding lock cannot be acquired"; Swift's wording is
"binding lock cannot be opened", which the Loader binding owner's writes now
share.

## The oracle

`RockchipBindingInstallOracleContractTests` records Swift's
`installCurrentTarget(rebind:)` over scripted I/O Registry identities and one
root (`/private/tmp/arkdeck-binding-install-oracle`, serialized with the
Rust replay by one `flock`). It never runs the CLI's own entry point, which
reads the real registry and the account's Application Support.

35 steps:

- the probe's refusals: a registry that cannot be read, no device, only
  other devices, two boards, an empty or non-decimal topology, an empty
  serial;
- installs, repeats and `--rebind`s: to the Loader personality, to another
  port, and with nothing installed;
- the store's refusals of what it cannot own: a binding that is not
  owner-only, hard-linked, empty, oversized, not an object, with an extra
  member, of the wrong types, with its serial in its evidence, of revision
  0, a directory or a link; a lock not owner-only or a link; a root that is
  a link;
- the root made again.

Each step records its answer, then every entry below the root with every
file's bytes.

A binding document that is not JSON at all escapes Swift's store as
Foundation's own parse error, whose words are the host's. That case is not
recorded; this Runtime refuses it as undecodable.

## Tests

| Test | What it holds |
| --- | --- |
| `arkdeck-rockchip-binding` `install_binding.rs` `every_install_step_is_swifts` | The 35 steps byte for byte: answers, entries and files |
| `arkdeck-cli` `argv_fixtures.rs` | Swift's argv fixture for `flash.install-binding` replays (dispatch, help, an unknown option, `jsonl` and `--endpoint` refused); every shell's completion names the leaf, and no leaf this CLI still refuses (found from the registry, as #2212 finds the refused nodes, rather than naming one) |
| `arkdeck-cli` `flash_leaves` (unit) | The receipt's envelope result and human lines, and the refusal line, over an injected census and a temporary root |
| hoststore `loader_binding_jobs.rs`, `rockchip_startup.rs`, `flash_host_facts.rs`, `post_flash_alias.rs` | Unchanged answers after the move |

Served leaves: 200/209 to 201/209 (`arkdeck commands --output json`); the
eight left are the `runtime signing` and `signing` install, SDK-release,
DevEco migration and removal leaves.

Mutation check, baseline passing, each restored and checked by digest after
(`/private/tmp/arkdeck-m4-f8b-mutations.log`):

- a lock that cannot be opened reported as not acquired;
- a differing binding replaced without `--rebind`;
- a non-decimal topology adopted;
- a rebind without the operator's selection: each fails
  `every_install_step_is_swifts`;
- the human receipt without its dispatch count: fails
  `an_install_renders_as_swifts_handler_renders_it`.

## Local targeted checks

On `main` `eec3df485`, `CARGO_TARGET_DIR=/private/tmp/arkdeck-m4-rust-target
CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`, logs `/private/tmp/arkdeck-m4-f8b-*.log`:

| Check | Result |
| --- | --- |
| Swift: `ARKDECK_RUST_BINDING_INSTALL_RECORD=<fresh> run-swiftpm.sh test --filter RockchipBindingInstallOracleContractTests`, then without the variable | exit 0, exit 0 (`arkdeck-m4-f8b-swift-record.log`, `…-swift-compare.log`) |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -D warnings` for `arkdeck-rockchip-binding`, `-provider-hdc`, `-hoststore`, `-agentd`, `-soak`, `-cli`: macOS, `x86_64-pc-windows-msvc`, `x86_64-unknown-linux-gnu` (their own target directories) | exit 0 each |
| `cargo test` for each of those six crates (after `cargo build -p arkdeck-cli -p arkdeck-agentd`) | exit 0 each (cli 60 test binaries, agentd 21) |
| `python rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv) | exit 0, `PASS` |
| `sh scripts/check-sdd.sh` | exit 0 |
| `cargo deny --locked check`, `cargo vet --locked --no-registry-suggestions` (in `rust/`, after the allowlist entry) | exit 0 (`advisories ok, bans ok, licenses ok, sources ok`), exit 0 (`Vetting Succeeded (36 fully audited)`) |

## CI

The first run (head `fb39014f3`) failed the host-independent job's
dependency policy step: `error[not-allowed]: crate 'arkdeck-rockchip-binding
= 0.1.0' is not explicitly allowed`. The allowlist entry above answers it;
the rerun is recorded by the next change.

Host-process evidence only: scripted I/O Registry identities, temporary
roots; no device, no installed service, and no account's Application Support
was written.

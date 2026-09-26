# The ArkForge lane's managed-control receipts and authority-support seal (TASK-XPA-017, F6 S2)

This slice ports two parts of Swift's production ArkForge lane to
`arkdeck-provider-arkforge`:

- how this authority answers `arkforged`'s managed-control requests (the
  receipt);
- the key that binds this authority build to an executable plan (the
  authority-support seal).

Both are pure: no socket, process or file. Nothing calls them yet. The Flash
session (S3) and the lane host (S4) will. The ArkForge pin stays at `eee5787`:
the messages used here exist there.

Developed and checked on protected `main` `c2b474136` (#2247), then rebased
onto `8bddca654` (#2249, which changes none of this slice's files); the build
and the read-only host check were run again after the rebase. No contract
input, Catalog or `tasks.md` changes. No device, and nothing here is device evidence.

## What is ported

### `managed_control` (Swift `ArkForgeManagedControlPort.swift`)

- **`provider_actions`** lowers each semantic action to its provider actions,
  in order:
  - `enterUpdater` is five observations: `observeHDCNormalUSB`,
    `enterLoader`, `waitForHDCDisconnect`, `waitForLoader`, `rebindLoader`.
  - `rebootToNormal` is `waitForBoundHDCReconnect`.
  - Both fact reads are `verifyBoundBuild`.
- **`expected_receipt_facts`** lists the facts a successful receipt must
  carry: mode, stable identity and topology for the two mode changes, and
  the one property each read names.
- **`receipt`** builds ArkForge's own `SubmitManagedControlReceiptRequest`,
  or refuses with Swift's words:
  - A forbidden key refuses the whole receipt. So does a forbidden name
    inside a value.
  - An accepted receipt without its facts is refused.
  - An accepted `enterUpdater` without both the disconnect and the unique
    Loader rebind is refused.
  - The facts go out in key order. An accepted receipt's evidence is the
    canonical digest of its own facts, which the daemon recomputes. A refusal
    carries no evidence.
- **The forbidden list is ArkForge's own constant**
  (`FORBIDDEN_CONTROL_RECEIPT_FACTS`), so the two cannot drift.
- **One spelling difference, not observable in practice.** Swift's facts are
  a dictionary, so with two forbidden keys it names one in no fixed order.
  This port names the first in key order, and within a value the first in
  ArkForge's list.
- **No `unspecified` action.** ArkForge's Rust enum has no such case: a
  control action this build does not know fails to decode at all. It is never
  mapped to a default sequence.

### `authority_support` (Swift `ArkForgeAuthoritySupport.swift`)

- **`Key::digest_bytes`** is SHA-256 over `arkdeck.authority-support-key/v1`
  plus a newline, then each field as `name=value` plus a newline, in the byte
  order of the names.
  - Five axes must be exact lowercase SHA-256 text.
  - Three identifiers must be non-empty, one line, and free of `=`.
  - Each failure is refused with Swift's text.
- **`Configuration`** lowercases its two digests, as Swift does. Its `key`
  hashes the two closed protocol texts exactly as Swift's multi-line literals
  read: lines joined by newlines, none after the last.
- **`seal`**:
  - With no campaign, the seal is `hardwareGated` with Swift's detail, and
    cannot execute.
  - With a campaign, it is `hardwareCampaign`, and a campaign spanning two
    lines is refused.
  - `permits_execution` is true for `productionVerified` or
    `hardwareCampaign`.
- **The pending seal** is the SHA-256 of
  `arkdeck.authority-support-pending/v1`, with Swift's detail.
- **`host_platform`** is `<os>/<arch>` in Swift's spelling (`macos/arm64`).

### Dependency edge

`arkdeck-provider-arkforge` now depends on `arkforge-ipc` directly. That
crate holds the messages `arkforge-client`'s controller surface takes and
returns, and the client does not re-export them. `check-readonly.py`'s
ArkForge table records the edge. The crate was already locked and allowed as
the client's dependency, so `deny.toml` and cargo-vet need no change.

## Tests

- **All of `ArkForgeManagedControlPortContractTests`,** case for case,
  including the golden facts digest `68c995f4…` that `arkforged`'s own tests
  mirror.
- **The receipt round-trips through ArkForge's codec** unchanged.
- **Every action on ArkForge's wire is bound** to at least one provider
  action and at least one expected fact.
- **All of `ArkForgeAuthoritySupportContractTests`.** A campaign seal and a
  `productionVerified` seal are also covered.
- **Goldens Swift does not pin.** Each was computed independently from
  Swift's literals, in Python:

  | text | SHA-256 |
  |---|---|
  | the control-mapping text | `cc7cd19d…0d94` |
  | the permit-codec text | `4ee06e55…4bab` |
  | the key of Swift's test axes | `80cde5b2…1a43` |

  A Swift-side pin of the same values can come with the next Swift window.

## Verification

**Local targeted checks.** Main worktree, target
`/private/tmp/arkdeck-m4-rust-target` (`-win` and `-linux` for the cross
checks), `CARGO_BUILD_JOBS=2`. Logs are under the session's scratchpad
`s2-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings`, host: `arkdeck-provider-arkforge` and its dependents `-hoststore`, `-agentd`, `-cli`, `-soak` | exit 0 |
| the same for Windows and Linux: `arkdeck-provider-arkforge` | exit 0 each |
| `cargo test -p arkdeck-provider-arkforge` | exit 0: 30 unit tests (20 new), the lane, device access and permit vector binaries |
| `rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv), after `cargo build -p arkdeck-cli -p arkdeck-agentd` | exit 0 |
| `cargo deny --locked check`, `cargo vet --locked --no-registry-suggestions` | exit 0 each |
| `sh scripts/check-sdd.sh` | exit 0 |

Not run:

- Tests of the dependents: nothing of theirs changed or calls the new
  modules. Their clippy above compiles them.
- Swift: nothing of it changed.
- `generate-contract.py --check`: no contract input changed.

**CI.** Pending.

The CI of #2247 (F6a) was green before it merged as `c2b474136`.

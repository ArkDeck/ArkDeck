# Rust read-only foundation

TASK-XPA-002 supplies a separate development daemon and the `doctor`,
`operation list` and `device candidates` CLI leaves. It consumes the current
protected-main Swift contract pinned in
[`spec/baselines/swift-single-v1.json`](../spec/baselines/swift-single-v1.json).
This pin is a development baseline. SVC release acceptance, Windows platform
acceptance and production Runtime migration remain separate requirements.

## Build and check

From `rust/`, rustup selects the committed Rust 1.98.0 toolchain:

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build --workspace --bins --locked
python scripts/generate-contract.py --check
python scripts/check-readonly.py
```

The Python checks require Python 3.11+ with `PyYAML==6.0.3` and
`jsonschema==4.26.0`. The repository's unified planner also runs these checks,
`cargo deny` and `cargo vet`; see [dependency policy](supply-chain/README.md).
The committed audit policy currently fails for nine dependencies and contains no
publisher trust or exemptions. A passing source/license/advisory check is not a
passing audit gate.

The black-box check starts only its own daemon with a unique endpoint and HDC
configuration removed. It saves the actual outputs under `target/readonly-check/`
and validates schemas after all commands finish and the daemon exits. On Unix it
records every current method, malformed frames and the three CLI leaves. On
Windows an unsigned build must refuse the actual daemon identity before sending
frames. Positive installed-daemon authentication and DAYU200 acceptance require
the [Windows SPK-3 harness](scripts/windows-spk3.ps1) and its real host conditions.

## Try the current host path

Run `cargo run -p arkdeck-agentd` from `rust/`, then in a second terminal:

```sh
cargo run -p arkdeck-cli -- --output json doctor
cargo run -p arkdeck-cli -- --output json operation list
cargo run -p arkdeck-cli -- --output json device candidates
```

The CLI verifies health on the authenticated connection before the business
request. It never starts a daemon or reconnects/replays a lost request. A normal
`doctor` returns its report even when readiness is false; `--require-healthy`
returns exit 69 for that report. All 30 Catalog operations are unavailable
because this phase has no operation execution provider. Without a usable HDC
observation provider, candidates returns a structured refusal, not an empty
successful snapshot. The wire method is `device.observations`.

The Unix default endpoint is a private development socket under the temporary
directory, separate from the published Swift socket. Windows uses a local
logon-scoped named pipe and requires an installed daemon identity. Development
composition accepts these process-environment inputs:

| Input | Meaning |
| --- | --- |
| `ARKDECK_ENDPOINT` | Absolute physical Unix socket path in a `0700` parent, or local `\\.\pipe\arkdeck-*` name. |
| `ARKDECK_DAEMON_PATH` | Expected installed daemon executable; defaults to the CLI's sibling daemon. |
| `ARKDECK_DAEMON_SIGNER_SHA256` | Windows trusted signing-certificate SHA-256, configured from installation evidence. |
| `ARKDECK_DAEMON_PACKAGE_FAMILY` | Alternative exact Windows installed MSIX package family. |
| `ARKDECK_HDC_PATH` / `ARKDECK_HDC_SHA256` | Exact existing tool selection; both are required and the platform tuple must already be registered. |

These are local host configuration, never control request fields or capability
authority. An arbitrary configured hash cannot register a Windows HDC tool.
The current published HDC tuples are macOS-only. The macOS commandless server
lease is also unavailable in this phase, so both paths refuse HDC dispatch.
Registering Windows requires actual Windows tool/output provenance and a
separately scoped integration change; see the
[delivery record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/xpa-002-readonly-foundation.md).

## Contract and ownership boundaries

`arkdeck-contract` contains generated schemas, strict framing, canonical encoders
and digest functions. `arkdeck-control` has transport-free read-only handlers.
`arkdeck-platform` owns the unsafe OS boundary; all other crates forbid unsafe
code. `arkdeck-provider-hdc` lowers one fixed observation argv through that
boundary. `arkdeck-client` owns same-connection health and refusal handling;
`arkdeck-cli` presents the current CLI envelope; `arkdeck-agentd` composes them.
The black-box check also verifies these dependency edges.

The full 96-method contract remains the current single-v1 registry; the other
92 methods are structurally understood and refused before a host handler.
There is no Runtime capability owner, recovery, journal, durable target store,
device mutation, flash lowering, Swift replacement or production cutover here.
Unknown or incomplete outcomes never acquire invented zero-dispatch evidence.

Catalog generation preserves the same canonical source bytes and SHA-256 as
Swift. The CLI canonical encoder preserves the current Swift vectors, including
its existing binary64 spelling below `1e-4` and above the Int64 fast path. Swift
currently emits `1e-6` and `1e+20` where RFC 8785 would use decimal notation.
Native Swift boundary vectors pin that known difference; this phase does not
claim universal RFC 8785 conformity or change Swift semantics independently.
The generated baseline records every schema, corpus, source and fixture digest.
Regenerating a pin requires an explicit protected-main revision and matching
working inputs; generator checks are separate from actual output validation.

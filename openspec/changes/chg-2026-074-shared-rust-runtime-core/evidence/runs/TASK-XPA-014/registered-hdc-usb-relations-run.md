# TASK-XPA-014 — development USB relations beside the isolated owner's managed registered HDC (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `74c3b2b1` (#2016; first written on
`9c58e484`, rebased without conflict); no stack. Host-only
change: no device, real HDC, installed state or Swift daemon was used, and nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift source, control schema, corpus, Catalog,
entitlement, `openspec/specs` or constitution change.

## Why

The GJ-1 preflight on the pure Rust daemon (`gj1-pure-rust-preflight-20260919.md`, #1994) left three
blockers. The first, the refused registered HDC, was lifted by the managed development HDC server
(#2004, `ARKDECK_DEVELOPMENT_HDC_SERVER=managed`). The second (no trusted USB relation source, so
`target adopt` is always `admissionDenied`) and the third (which daemon setup may count before M5)
were decided by the maintainer on 2026-09-19 as **option A**: in the isolated development root, the
development USB relation source of #1988 (`ARKDECK_DEVELOPMENT_USB_RELATIONS`) may stand beside the
registered HDC the owner starts as its managed server, and GJ-1 is run on the real DAYU200 that way.
What that run proves is recorded as development-root real-device evidence: it is not
`REAL_DEVICE_PASS`, and the dashboard's "GJ on Rust" stays 0/5.

Until this change, `development_hdc()` refused that very composition at startup ("development USB
relations are configured only beside a fixture HDC"), since for a real HDC a caller-written file is a
trusted fact about a real device that no physical relation proved.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| The development relation source and its refusals (#1988); the managed development HDC server with its identity proof (#2004); the refusal of relations beside a registered HDC | An explicit, separate opt-in that admits the relation file beside a registered HDC only in the one composition the decision names; the refusal without it, unchanged | The GJ-1 run on the real DAYU200 in that composition (the next PR); the trusted production USB reader (ArkForge lane); §2.1 restart carry-over (design §L.1 item 13) |

## What changes

- **The opt-in.** `ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC=acknowledged`. Its one value
  is `acknowledged`; any other value fails startup (exit 69,
  "… accepts only acknowledged"). It admits `ARKDECK_DEVELOPMENT_USB_RELATIONS` beside a registered
  HDC only when all of these hold, and is refused in every other composition, so it never stands
  unused in a configuration:
  - an isolated development root (`ARKDECK_DEVELOPMENT_STATE_ROOT`);
  - a registered HDC named by `ARKDECK_DEVELOPMENT_HDC_PATH`, started by the owner as its managed
    server (`ARKDECK_DEVELOPMENT_HDC_SERVER=managed`), which binds the endpoint's listener to that
    launch;
  - a relation file named.
- **Unchanged without it.** A registered HDC with a relation file keeps its refusal and its message;
  a fixture HDC with a relation file stays allowed without any acknowledgment.
- **Never outside an isolated root.** The standalone daemon and the facade refuse the opt-in at
  startup ("development USB relations beside a registered HDC are acknowledged only for an isolated
  development root"), before anything is bound.
- **Decided before any server starts.** The decision (`development_usb::admit`) runs before the
  managed server is launched, so a refused composition leaves nothing on the endpoint.
- **README**: the managed-server sentence of "HDC runtime status" and the relation sentence of
  "Target presentation owner", in place.

## Tests

- `development_usb::tests::relations_beside_a_registered_hdc_need_the_acknowledgment_and_the_managed_server`:
  the decision over 11 compositions of (registered, managed, relations, acknowledged), including
  the registered ones no process test can reach, since a test HDC never has a registered digest.
- `development_usb::tests::the_acknowledgment_has_one_value`.
- `tests/managed_hdc_process.rs`
  `development_usb_relations_beside_a_registered_hdc_are_acknowledged_only_as_named` (real daemon,
  fake HDC compiled from C): an unknown value; the acknowledgment beside the fixture as a managed
  server, beside the fixture not started by the owner, without a relation file, without a
  development HDC, and outside an isolated root. Each fails startup with exit 69 and its message,
  writes nothing to stdout and leaves nothing listening on the endpoint.

The existing refusals and their tests are unchanged (`managed_hdc_process.rs` and the four refused
startups of `check-corpus-replay.py`).

## Local targeted checks

On head `c783ba7f` (base `74c3b2b1`), as `AGENTS.md` prescribes since #2015. Logs are under this
session's scratchpad `logs/`.

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `e3b0c442…` (empty) |
| `CARGO_BUILD_JOBS=2 cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets --locked -- -D warnings` | 0 | `2e38c8a9…` |
| `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --locked`: 32 unit + 1 + 1 + 1 + 4 process tests | 0 | `34f8633e…` |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

No crate depends on `arkdeck-agentd`. Before the rebase, `cargo clippy --workspace --all-targets --locked
-- -D warnings` was also clean for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and
`x86_64-pc-windows-msvc`.

One full local run of the unified gate was made on the pre-rebase head `fe0472df` (base `9c58e484`),
before #2015 changed the rule. It started at 20:37 CST and ran beside the real-device window of the next
PR (load 20–33). It exited 1 in the Rust lane on `arkdeck-platform` `tests/verified_process.rs`
`output_overflow_kills_and_reaps_the_child`, whose `< 2 s` wall-clock assertion failed. All four
invalid-run criteria hold. The test is outside this diff, and it is a known load-sensitive test. It
passed alone four times in a row (1.2–1.4 s). Nothing in this change touches process spawning. The
full gate was not rerun locally, since CI is now the unified gate.

## CI

Recorded after the PR's CI reports (`guard` + `swift`).

## Not run

Any device, real HDC, installed Runtime or Swift daemon. The composition this change admits is
exercised on the real DAYU200 by the next PR's run record
(`gj1-rust-development-root-real-device-20260919.md`).

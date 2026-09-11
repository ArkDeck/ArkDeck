# Isolated Rust Session cleanup preview owner

The isolated Rust daemon now serves `session.cleanup.preview` from its own
Session configuration and retention catalog. The current Rust and Swift CLI
consumers read the response. The apply path is not implemented or activated;
TASK-XPA-012 and the full macOS migration remain incomplete.

Preview holds the configuration lock, reconciles the existing catalog, and
reads a fresh complete census under the catalog lock. It refuses unknown,
duplicated or inconsistent content. The retention plan preserves pinned and
active Sessions and reclaims only under quota pressure. Artifact references
come from the validated manifest, retain their source records internally, and
are projected in ID order without paths. The canonical preview digest binds
Session/Artifact references, policy/catalog generations, totals and disposition.

The composition root enables these owners only in an explicit isolated
development directory. This daemon has no Job dispatch, so its active Session
inventory is empty. Installed activation must use the actual Job owner's
inventory and detach the Swift consumers; this work does not claim that step.

The private `session-cleanup-previews` store uses the existing Swift record
format and configuration lock. It preserves ready/applying/applied state,
rejects stale transitions, reads publication back, retains applying records
regardless of expiry, and bounds storage to 64 records of at most 16 MiB each.
No code in this implementation currently invokes Session deletion.

Bounded development validation on macOS:

- Twelve host-store cleanup tests passed: planning and protected Sessions,
  preview digest/reference changes, durable owner preview, lock/unknown-content
  refusals, record restart/state handling, expiry, capacity and unsafe files.
- Two Rust CLI tests passed: digest corruption and signed but inconsistent or
  unsafe previews are refused. The CLI checks canonical identifiers, dates,
  counters, strict ordering, protected dispositions and Artifact privacy.
- `check-session-cleanup.py` passed with the Rust CLI and again with the current
  Swift CLI against the Rust daemon. Each run recorded ten real control
  exchanges plus the CLI preview request. It checked pin protection, a real
  fixture payload's digest/reference, exact ready-record persistence, restart,
  lock contention, closed parameters and unknown content. No apply call occurs.
- Clippy passed for the host-store, daemon and CLI targets; the protocol
  generator's check and `git diff --check` passed.
- `SessionCleanupContractTests.testCurrentSwiftOwnerReadsActualRustCleanupPreviewRecord`
  passed. Its fixture was copied directly from the Rust daemon's ready record
  by `--record-store-copy`; the current Swift owner decoded it and reproduced
  exactly the same canonical bytes, including the final newline.

The current preview schema/corpus combines existing Swift frames with actual
Rust responses. The request remains closed and parameterless; malformed-request
recordings do not broaden the accepted request schema. Its owner failure
vocabulary is explicit. The shared candidate contract runner now includes the
preview process check. Published-input pins are unchanged.

Reproduce from the repository root after building the Rust binaries:

```sh
python3 rust/scripts/check-session-cleanup.py
python3 rust/scripts/check-session-cleanup.py --cli-path Packages/ArkDeckKit/.build/debug/arkdeck
```

All payloads and manifests used here are newly created simulated host fixtures,
not hardware evidence. Cleanup apply, installed-owner acceptance and the remaining
migration deliverables are still required before completion.

## Mainline integration — 2026-09-11

The existing implementation was rebased without conflicts onto approved main
`f9f38a2473308195978fc536f5b83efc9d47f5b3` after PR #1844. The rebuilt Rust
daemon again passed this preview process check with both Rust and current Swift
CLI consumers. The shared host-store and CLI tests also passed.

PR #1846 merged as `b3fe9a7bfbfb9a4ef211f4c642bd6f96b3553da5`; this slice was
rebased onto it. The final unified CI plan passed with the complete worktree diff:
common checks, all Swift lanes, Rust formatting/Clippy/tests, published and
candidate contract checks, real daemon owner/CLI checks, cargo deny and cargo vet
(26 fully audited). No cleanup apply, installed activation or hardware acceptance
is claimed.

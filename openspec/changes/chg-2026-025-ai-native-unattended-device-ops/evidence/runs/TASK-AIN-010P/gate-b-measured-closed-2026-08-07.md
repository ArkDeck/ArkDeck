# TASK-AIN-010P gate B, measured rather than inferred (2026-08-07)

r3 concluded that production selection is not blocked and that the product's own override selects
the real toolchain. The first half was measured; the second was **two measurements joined by an
inference** — the override mechanism proved against a copied fixture, and the DevEco HDC hashed
separately. Nothing had run the two together.

This closes that. Host-only: discovery executes nothing, so no HDC server can be started, adopted
or contacted. HDC command dispatch: 0. Device command dispatch: 0.

## What was run

`HDCSupervisorContractTests.testConfiguredOverrideSelectsTheRealToolchainWithoutABookmark`, gated
on the product's own override key, which is also its input:

```
ARKDECK_HDC_USER_CONFIGURED_PATH=<system DevEco toolchain hdc> swift test --filter …
```

Ungated, it skips (measured separately). Pointed at the real executable, it passed in 0.020s.

## What it asserts, starting from an unconfigured process

The discovery request is built by production code (`discoveryRequest`) against an **empty**
preferences suite — no persisted path, no bookmark, no App run — which is the state a package
executable such as the registrar starts from:

- `userConfiguredPaths` is exactly the override path, resolved and standardized;
- `securityScopedBookmarks` is empty, and `devecoSDKPaths` / `openHarmonySDKPaths` are empty, so
  the override is demonstrably the only source in play;
- `HDCExternalFirstDiscovery.discover` returns **one** candidate with **no** issues, at that
  path, from `.userConfigured`, carrying **no** security-scoped bookmark;
- the candidate's `sha256` equals the file's hash re-read inside the test — not trusted from the
  report — and `HDCCandidateIdentityVerifier.matches` passes.

The last point is the one that was missing: identity is now established in the same run that
performed the selection.

On this host the executable that resolves to is the DevEco toolchain HDC whose bytes hash to
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` — the tuple r1 registered for
`3.2.0f`, re-verified in r2 and unchanged. The test does not hard-code that digest: pinning a
specific vendor build belongs to a readiness window, not to a mechanism test that would then rot
on the next DevEco update.

## Gate status

**Gate B is closed by measurement.** Production selection needs no picker, no bookmark, no code
change and no host preference write — an absolute path through the documented override is
sufficient, and it yields a verified candidate.

Nothing here writes host state. The audits in this series have deliberately left the host's
preferences untouched, and configuring the registrar's environment is a readiness-window action
that belongs with the other pins.

One gate remains, unchanged and unchangeable from a blocked task: a fresh `3.2.0f` machine
confirmation of device presence, serial digest, binding revision and build, which requires a
registered `list targets -v`.

# Signed update feed dependency review

Current disposition (2026-09-27): the user approved the bounded publisher-trust
proposal for the four exact releases below. See the authorization follow-up at
the end. The initial investigation below is retained as historical evidence.

The Rust CLI needs Ed25519 verification to preserve Swift `UpdateFeedCodec`.
The implementation pins `ed25519-dalek =2.2.0`, defaults disabled, `fast`
enabled. It uses `VerifyingKey::verify_strict`; no production signing key,
key-generation API, PKCS8, PEM, batch, or legacy-compatibility feature is used.
Fixture tests sign with a public, deterministic test seed. The 2.x line shares
the workspace's SHA-2/digest versions; 3.x would introduce a different digest
family. This choice still requires dependency review.

`Cargo.lock` records eight new exact versions/checksums. `deny.toml` lists those
versions explicitly. Neither file establishes source-audit coverage or approval.
No `trusted`, exemption, local audit certification, or imported-source rule was
added. The existing five audit imports were refreshed with `cargo vet regenerate
imports`; the 131-line addition is limited to the new graph's imported audits.

Four dependencies have complete imported `safe-to-deploy` chains:

- `fiat-crypto 0.2.9`: ISRG full audit at 0.1.17 and deltas through 0.2.9.
- `rustc_version 0.4.1`: Mozilla full 0.4.0 and Bytecode Alliance delta.
- `semver 1.0.28`: Bytecode Alliance full 1.0.17 and imported deltas through 1.0.28.
- `signature 2.2.0`: Zcash full 2.1.0 and delta.

The refreshed locked `cargo vet --locked --no-registry-suggestions` exits 255
with exactly these four missing `safe-to-deploy` dependencies:

| Exact package | Publisher ID / login | UTC publication date | License |
| --- | --- | --- | --- |
| curve25519-dalek 4.1.3 | 6979 / rozbb | 2024-06-18 | BSD-3-Clause |
| curve25519-dalek-derive 0.1.1 | 6979 / rozbb | 2023-10-31 | MIT/Apache-2.0 |
| ed25519 2.2.3 | 267 / tarcieri | 2023-10-15 | Apache-2.0 OR MIT |
| ed25519-dalek 2.2.0 | 6979 / rozbb | 2025-07-09 | BSD-3-Clause |

The public crates.io version APIs were checked on 2026-09-26. All four were
not yanked; checksums match `Cargo.lock`. Exact URLs, timestamps and checksums
are in `update-feed-dependency-facts.json`. Publisher identity and release dates
are provenance, not source audits and not authorization to trust those releases.
The missing packages implement curve/signature validation and compile-time
dispatch; bugs or compromised releases can invalidate update-feed authenticity.

The dependency gate remains **failing**. Closing it requires an adequate source
audit chain or an explicitly reviewed trust-policy decision. This implementation
does not make that decision. Local fixture results do not replace the gate.

## Local targeted checks

- Initial locked vet: exit 255, eight missing dependencies,
  `/private/tmp/arkdeck-update-feed-vet.log`.
- Existing-source import refresh: exit 0,
  `/private/tmp/arkdeck-update-feed-vet-refresh.log`.
- Refreshed locked vet: exit 255, four missing dependencies,
  `/private/tmp/arkdeck-update-feed-vet-after-refresh.log`.

## CI

No remote branch or PR for this local change. The active thread's remote push
authorization is still pending after automatic approval review rejected the push.
No CI result or maintainer approval is claimed.

## Authorized bounded trust follow-up — 2026-09-27

After the remaining CI failure was identified as four missing audit chains,
registry discovery again found no complete imported coverage. The user was
shown the exact four-release, single-publication-day proposal and replied
"同意，推送". This authorizes those trust rules and pushing them to PR #2272;
it does not certify a source audit or approve release/device acceptance.

| Package | Publisher | UTC trust interval `[start, end)` |
| --- | --- | --- |
| curve25519-dalek 4.1.3 | rozbb / 6979 | 2024-06-18 → 2024-06-19 |
| curve25519-dalek-derive 0.1.1 | rozbb / 6979 | 2023-10-31 → 2023-11-01 |
| ed25519 2.2.3 | tarcieri / 267 | 2023-10-15 → 2023-10-16 |
| ed25519-dalek 2.2.0 | rozbb / 6979 | 2025-07-09 → 2025-07-10 |

Registry checks reconfirmed all four checksums against Cargo.lock, numeric
publishers and non-yanked status. Raw checks are retained at
`/private/tmp/arkdeck-pr2272-bounded-trust/checked-facts.json`. The proposal
adds four trust entries and four matching publisher records only. Existing
trusts, imported audits, source URLs, dependency versions and checksums stay
unchanged. There are no exemptions, locally certified audits, future windows
or automatic renewals. A compromised publisher or defective release remains a
risk that this policy check cannot exclude.

### Local targeted checks

On the applied repository policy, `cargo vet --locked --no-registry-suggestions`
and `cargo deny --locked check` both exit 0; logs are
`/private/tmp/arkdeck-pr2272-authorized-vet.log` and
`/private/tmp/arkdeck-pr2272-authorized-deny.log`. A structured before/after
comparison confirms only the four authorized trust/publisher entries changed.
`sh scripts/check-sdd.sh` and `git diff --check` exit 0; logs are
`/private/tmp/arkdeck-pr2272-authorized-sdd.log` and
`/private/tmp/arkdeck-pr2272-authorized-diff.log`. Vet success means the configured
policy is satisfied, not that all source was audited. No production code or
dependency version changed, so runtime tests were not repeated.

### CI

PR #2272 head `361f2a6b` passed full Swift and all three Rust platform lanes;
run `36282047104` failed only at cargo-vet for these four missing policies.
The policy follow-up requires its own pushed-head CI result.

# TASK-XPA-012 Target presentation owner — isolated implementation

Date: 2026-09-12. All fixtures are synthetic host-test data, not hardware evidence.
The phase does not establish a binding, alias, fresh trusted fact, capability or
execution route. No installed state is selected.

## Scope and behavior

- A Rust owner reads the current Swift `targets.json` shape, validates bounded
  records and complete alias proof/hash chains, and preserves binding bytes.
  `target.list` selects active canonical records; `target.show` keeps the explicit
  absent warm/confirmed observation sources null.
- `target.display-name.set|clear` publishes only the existing separate name file,
  with exact generation CAS, private anchored locks, atomic publication and
  tombstones. Candidate writes require references from the Host's actual retained
  provider snapshot; caller fields cannot supply active references or facts.
  Snapshot refresh/restart expires candidate names, and publication uncertainty
  invalidates the retained snapshot. These names never select execution routes.
- Typed CLI leaves check identities, generation spelling, exact receipt identity,
  next generation and requested name/clear result. Lost/invalid write replies are
  outcomeUnknown and are never retried. Adoption remains unavailable because
  independent USB attachment proof and typed identity readback are absent.
- A DEBUG-only Swift construction seam acts immediately before the real save
  openat/renameat. Tests change fixture directory permissions/destination kind;
  the original syscall guards and catch path produce ioFailure/outcomeUnknown.
  Valid bounded input fixtures exercise count/byte quota errors. Production
  construction and release builds have no injection hook.

## Local checks completed

- Rust Target owner/alias tests: concurrent one-winner CAS, restart tombstone,
  current/unknown/adopted candidate rejection, global candidate generation,
  unsafe/duplicate document refusal, and alias hash/identity corruption refusal.
- CLI targeted tests: six command leaves, strict options, exact response binding,
  and lost response non-retryable classification.
- Host test: explicit simulated in-memory snapshot, stale/forged references and
  restart refusal with no reachable transport.
- Clippy for hoststore/agentd/CLI all targets, Rust formatting, Python harness
  compile, Swift frontend syntax parse and diff whitespace checks passed.
- `Fixtures/TargetNames/rust-display-names.json` was copied from the actual Rust
  owner test output; the Swift reader regression consumes these bytes directly.

## Native and process integration checks

The implementation now uses protected main `84d7107f`, preserving merged
Job/Artifact reads, Bundle registration and the checkout manifest v2 generator.
Target timeout options use main's shared CLI duration parser. The original
independent validation view used `a3b384d3`.

The seven Target/name Swift tests and the alias reconciliation producer passed
in the serialized native validation view. The actual Rust-produced tombstone was
read and advanced by Swift without rewriting its original bytes. Rust read both
Swift-created Target exports, including the complete alias proof chain, without
changing `targets.json`. Logs: `/private/tmp/xpa-native-union-swift-r1.log`,
`/private/tmp/xpa012-target-swift-store-r1.log` and
`/private/tmp/xpa012-target-swift-alias-r1.log`.

The process checker passed with both the actual Rust CLI and current Swift CLI
against the actual Rust daemon. Both runs verify exact generation receipts,
stale set/clear refusal, forged fields, unknown target/candidate refusal, restart
persistence, clear tombstones and unchanged binding bytes. Logs:
`/private/tmp/xpa012-target-rust-cli-r2.log` and
`/private/tmp/xpa012-target-swift-cli-r2.log`.

The first process run exposed an unrecorded existing Swift stale-set refusal:
`target.display-name.set` lacked `resourceConflict` in its method schema. The
native CAS test now records that actual response as well as stale clear; its
rerun passed (`/private/tmp/xpa012-target-stale-set-swift-r1.log`). The four name
method schemas are regenerated from existing corpus plus unchanged native
producer frames, including actual quota and save-syscall failures. No synthetic
Rust response substitutes for a native producer response.

Raw recordings and source hashes are retained under
`target-producer-frames-macos-20260912/`. One valid raw JSON frame contains a
Unicode line separator in an invalid name; the schema generator uses Unicode
`splitlines`, so that frame is retained in raw evidence but excluded from the
selected derivation input. Other native cases cover the same `invalidInput` code.
After integrating #1863, the checkout manifest describes 105 methods and 580 shapes. The published
contract view remains the verified protected-main merge base under merged #1866.

The current Task already lists the method-schema and checkout-manifest paths;
this phase records existing native display-name behavior within the host-store
migration scope and adds no Allowed-path pattern.

## Final gate

The initial full Swift lane hit an unchanged 400 ms admission/wait timing test:
under concurrent load its mutation response had not arrived before the deadline,
so the CLI correctly reported `outcomeUnknown` rather than the test's expected
post-admission `clientTimeout`. The same build and unchanged test passed alone
in 0.842 seconds. The final gate is repeated with four Swift workers, preserving
the complete suite and the test's own concurrent Job-run assertion. Logs:
`/private/tmp/xpa012-target-main-unified-gate-r1.log` and
`/private/tmp/xpa012-target-timeout-isolated-r1.log`.

The complete four-worker unified gate passed on the independent `a3b384d3`
view: common checks, 83 design-system tests, 2,632 Swift tests plus the serial
identity and five viewer-scale tests, App build-for-testing, Rust workspace and
both contract views, deny and vet. Log:
`/private/tmp/xpa012-target-main-unified-gate-r2.log`. Main then incorporated
#1863 at `f92acd36`; integration is complete and all affected Rust targets compile.
Installed activation, target adoption and independent USB identity proof, warm presentation
and confirmed Job observation sources remain in the migration's later slices.

The additional #1868 ArkForge pin update rebased without conflicts. The `f92acd36`
gate r3 was intentionally stopped before completion. The complete gate on
`0dad7599` then passed: common checks, 83 design-system tests, 2,635 Swift tests
plus identity and five serial viewer checks, App build-for-testing, Rust workspace,
both contract views and process checks, deny and vet. Log:
`/private/tmp/xpa012-target-main-unified-gate-r4.log`.

The #1867 stable-toolchain rebase changes no compiled Swift/Rust crate source,
lock, dependency policy or contract bytes relative to the fully tested Target
head. Stable remains Rust 1.98.1. Generator and final Task012 preflight are checked
after the final commit; latest-head CI validates the submitted rebase.

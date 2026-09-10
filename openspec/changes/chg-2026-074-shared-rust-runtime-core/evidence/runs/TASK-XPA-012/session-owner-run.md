# Isolated Rust Session configuration owner

PR #1841 was approved and merged as `ee60e686`; this continuation starts from that
published tree. The development Runtime now handles `runtime.storage.status`,
`runtime.storage.policy`, and `runtime.storage.root` directly, with the current
CLI leaves and parameters. No Swift child or HDC provider is configured in this
mode. Installed Runtime activation and full TASK-XPA-012 acceptance remain pending.

The Session owner locks the configuration, enforces canonical positive generation
CAS, validates its private/disjoint root, and reconciles the actual Session tree
before atomically publishing configuration. Catalog initialization is sealed on
the permanent lock inode. A lost initialized or corrupt catalog remains an
incomplete measurement, with null catalog generation; it is never reconstructed
as an empty successful inventory. Policy reconciliation preserves pin state and
updates retention dates and catalog generations. Custom development roots remain
inside the explicitly isolated root and cannot overlap Artifact or owner state.

The aggregate first reads actual Artifact indexes and verifies published payload
size, digest and retained file identity with bounded memory. A failed Artifact
measurement prevents Session configuration publication. This is an inventory
reader, not Artifact import/publication/lease/GC ownership. Session resource
pagination, pin commands, export and cleanup remain to be connected to Rust.

`rust/scripts/check-session-owner.py` exercised 21 actual local socket exchanges
plus CLI calls, kill/restart read-back, stale CAS, external lock contention,
nonempty simulated Session registration, date and pin retention, real byte census,
root isolation, missing catalog preservation, and corrupt Artifact bytes before a
policy write. The fixtures are explicitly simulated host data; no hardware result,
capability, real intent/outcome or protected Runtime record was produced or changed.
The method corpus contains selected actual responses. Schema changes describe the
existing owner error vocabulary and nullable corrupt-catalog generation; the
published Swift consumer input pin is unchanged.

Development checks: the eight new Session owner/catalog tests passed, as did current
History tests and host filesystem tests. Unix transport tests initially hit the
sandbox's EPERM on bind; the same six tests passed with controlled host execution.
Workspace Clippy passed. CLI error-scope and lost-reply checks passed, including
storage mutation replies that must remain outcomeUnknown without invented zero
execution proof. Native date tests cover negative Foundation time, nanosecond
rounding carry and the actual retention date used by the nonempty census check.

The existing 1,412-case/31-test shadow regression passed; its immutable source
fingerprints and digest-only results are preserved in
`local-session-owner-shadow-20260910.json`. No legacy cases were added.

The first unified gate completed all public checks and the full Swift test lane,
then correctly refused the published consumer pin because #1841 changed six
History inputs on main. The independent TASK-XPA-002 single-file re-pin is PR
#1842, backed by a passing unified local gate. The Session branch does not modify
the baseline path. PR #1842 was subsequently approved and merged as `dc4b623e`; this branch was
rebased onto it without changing the baseline. The complete Rust lane from the
unified entry then passed: pin verification, format, locked fetch, workspace
Clippy, workspace/candidate selection, 25 checker tests, published/candidate
workspace and protocol replay, the 21-exchange Session and 18-exchange History
checks, cargo deny and cargo vet (26 fully audited dependencies). Each protocol
view recorded 112 control responses and seven CLI envelopes. The already passing
Swift checks were unaffected by this single-file pin update and were not repeated.

A follow-up regression reproduced acceptance of an already initialized `0500`
custom root and an incorrect configuration-generation advance. The owner now
checks private read/write/search bits and performs the same bounded create/remove
probe as the current Swift owner, after CAS. The reproduction now passes and the
actual socket check confirms refusal without a configuration write. Development
Runtime directory ownership is acquired before any store creation or probe, so a
rejected second daemon cannot perturb the running owner's census. The updated
21-exchange Session check, 18-exchange History check and workspace Clippy passed.

The isolated published/candidate contract checker also passed before this root
permission fix, including the 20-exchange Session check, 18-exchange History
check and 112 control responses plus seven CLI envelopes per view. This is not a
claim that the pending published pin has been approved or that the complete
migration has passed final acceptance.

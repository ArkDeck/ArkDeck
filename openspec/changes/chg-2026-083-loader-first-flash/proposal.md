---
id: CHG-2026-083-loader-first-flash
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# Flash a board first attached in Loader mode

A board already in Loader is a Flash acceptance target. Requiring an earlier
Normal adoption or an earlier HDC alias makes that supported starting state
unreachable. Runtime must support first adoption from its own fresh, exact
Loader observation and verify the same hardware after the image boots.

The existing `flash.bind-current-loader` method gains an exclusive
`adoptCurrentLoader: true` request (`arkdeck flash bind-loader --adopt`). It
accepts no caller identity, topology, proof or capability. Host USB and ArkForge
must agree on one registered Loader throughout adoption. Runtime persists a
revision-1 Target and its Loader binding without inventing an HDC personality.
An unresolved Flash obligation anywhere in the adoption census blocks creating
a different Target: first adoption cannot erase an unknown physical association.

The full-restore plan pins the Loader serial digest and physical connector for
postflight. A returning HDC route is usable only after a fresh, bounded kernel
hardware-serial read matches that Loader and the connector remains unchanged.
The expected build and model must also match. Only then may Runtime publish the
first HDC alias and capture diagnostics on that verified route. Missing evidence,
another board, ambiguous USB, stale adoption, alias conflict or an unconfirmed
write fails closed. A Loader-first alias explicitly records hardware proof;
there is no fabricated previous HDC identity.

Existing unknown intents, history, capabilities and budgets remain immutable.
This does not provide an override, reset operation or exception to
POL-RECOVERY-001. In particular, an older Normal-only unknown cannot be attached
to the current Loader merely because it is the only board on the host.

Compatibility: existing Normal/known-alias requests and persisted actions retain
their encodings. This scoped integration change accompanies implementation for
maintainer review; synthetic tests are not hardware acceptance or approval.

# Rockchip Integration Boundary

> Current product route: native ArkForge (`arkforged-native-rockusb`)
> Provider: `rockchip`
> Catalog operation: `flash.dayu200`

ArkDeck's supported Loader-mode Rockchip product path is implemented by the protected
Runtime through ArkForge's native RockUSB backend. Runtime availability and dispatch
are bound to the measured `arkforged` daemon and publish `rockusbBackend: native`.
There is no external Rockchip executable selection, security-scoped executable
bookmark, PATH lookup, caller-provided argv, or external child process in this path.

The published `flash.dayu200` operation materializes the exact typed plan. HDC may
perform the catalogued `enterUpdater` step for a durably bound target; Loader
observation and all RockUSB reads, writes, reset, rebind, and postflight proof use the
native ArkForge route. Destructive execution remains gated by the protected Runtime's
exact `RuntimeCapability`, fresh target/binding/tool facts, artifact lease, durable
reservation, and complete-overwrite/recovery rules.

## Retired external-tool profiles

The former RockUSB discovery registry and HDC-to-Loader characterization registry
were experimental external-tool profiles. They are retired and are not members of
`INTEGRATION-PROFILES.lock.yaml`. Their registries are intentionally absent: they
grant no current discovery, transition, dispatch, or fallback authority. Historical
changes, receipts, and legacy session decoders may retain their identifiers solely
to explain or decode old records.

## Maskrom rescue distribution

`bundled-component/1.0.0/` is retained only as the source, build, license, SBOM, and
notice record for the separately shipped, operator-invoked Maskrom rescue utility.
It is not a Runtime Provider, Loader-mode backend, discovery fallback, or ArkForge
dependency. Its exact operational boundary is documented in
`docs/release/rockchip-component-packaging.md` and
`docs/release/rockchip-component-distribution.md`.

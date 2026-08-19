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

## Maskrom rescue distribution — retired (CHG-2026-065, 2026-08-19)

The `bundled-component/1.0.0/` record and the rescue utility it described are no
longer built or distributed; the registry directory was removed with the embed
phases, the component CI workflow, and the build pipeline. The Maskrom scenario
the rescue copy hedged was disproven on the DAYU200 bench (July 2026: `db` never
connected; the working recovery channel is Loader-mode rewrite, owned by the
native ArkForge route above). The accepted source/build/license/SBOM/notice
history remains in `docs/release/rockchip-component-packaging.md`,
`docs/release/rockchip-component-distribution.md`, and git history;
reintroduction would be a new change with its own evidence.

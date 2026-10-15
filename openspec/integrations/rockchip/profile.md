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

Before Normal-to-Loader admission, Runtime reads the exact USB-bound HDC target's
`/proc/cpuinfo` through the measured HDC provider. Exactly one canonical, nonzero
16-digit lowercase hexadecimal `Serial` must hash to the already bound Loader
identity. Normal USB serial, model/build and connector location alone are not
cross-mode hardware proof. Unsupported kernels, vendor Loader serials that do not
match this source and Normal-only CID bindings remain blocked.

Runtime persists an owner-only, content-addressed observation with target/revision,
provider digest, Normal USB and hardware serial digests, connector digest and source
output digest/count. It reads back the canonical record before reporting readiness.
The transition repeats this capture and durable readback in its action directory,
then checks the 30-second freshness bound, exact Normal attachment and current tool
before `reboot loader`. Loader confirmation requires the same serial digest and
physical connector. CPU output and raw serials are not copied into receipts.

This producer guard does not backfill earlier Jobs or rebind an unknown target.
An old unknown intent remains immutable and cannot be replayed. A recovery still
requires all `POL-RECOVERY-001` proofs; new observations alone cannot establish
historical lineage or reset its automation budget. See
[CHG-2026-082](../../changes/chg-2026-082-normal-loader-hardware-proof/proposal.md).

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

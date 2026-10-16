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
16-digit lowercase hexadecimal `Serial` is retained as the CPU fact. If it hashes
to the already bound Loader identity, the existing single-read path applies.
Factory-SN boards instead require the registered DAYU200 compatibility, exact
Normal eMMC CID, boot device-tree serial and the current validated Rockchip eMMC
vendor SN_ID=1 to agree with the bound Loader. The fixed reader reads only public
vendor metadata and SN_ID, checks all bounds and ambiguity, repeats source and
CPU/connector observations, and stays within 30 seconds. CPU and factory serial
digests remain distinct; a factory SN is not an immutable CPU identity. Normal
USB serial, model/build, device-tree serial or connector alone cannot prove the
transition. Missing or changed proof and Normal-only CID bindings remain blocked.

Runtime persists an owner-only, content-addressed observation with target/revision,
provider digest, Normal USB and hardware serial digests, connector digest and source
output digest/count; the factory route adds its own Loader/source digests and byte
count. It reads back the canonical record before reporting readiness.
The transition repeats this capture and durable readback in its action directory,
then checks the 30-second freshness bound, exact Normal attachment and current tool
before `reboot loader`. Loader confirmation requires the same serial digest and
physical connector. CPU output and raw serials are not copied into receipts.

This producer guard does not backfill earlier Jobs or rebind an unknown target.
An old unknown intent remains immutable and cannot be replayed. A recovery still
requires all `POL-RECOVERY-001` proofs; new observations alone cannot establish
historical lineage or reset its automation budget. See
[CHG-2026-082](../../changes/chg-2026-082-normal-loader-hardware-proof/proposal.md).

A board first attached in Loader can be adopted with `arkdeck flash bind-loader
--adopt`. Runtime requires one fresh registered Loader, the supported hardware
serial format and agreement between host USB and ArkForge; no caller supplies an
identity, connector or proof. The resulting revision-1 Target records Loader as
its initial mode and has no invented Normal identity. Before adopting, Runtime
checks all retained Flash obligations: an unsettled or unknown previous Flash
blocks a new Target when its physical association cannot be proved.

The initial full-restore plan pins that Loader identity and connector. After the
native ArkForge plan boots the image, Runtime finds one HDC candidate on that
connector, obtains the same fixed CPU or factory-SN cross-mode proof, and requires
it to match the initial Loader. Exact artifact build and
product-model readback are also required before publishing the first HDC alias.
Its schema `2.0.0` records the immutable hardware observation and connector digest
instead of a previous HDC identity. Repeated callbacks of that same Job preserve
the first alias; another Job, Target, route or connector cannot replace it through
initial publication. Diagnostics use only the verified route for that Job and
repeat the hardware check. Existing schema `1.0.0` aliases retain their encoding.
See [CHG-2026-083](../../changes/chg-2026-083-loader-first-flash/proposal.md).

An expired unknown Flash may use the existing Job archive preview/commit flow to
end as `interrupted` with `archivedWithHazards`. Its outcome remains unknown, all
resource/risk holds remain, and its original recovery clock is unchanged. The
Session identifies the original unresolved obligation without inventing current
device/tool proof. Retained unknowns still participate in the Flash, rebinding
and new Loader adoption censuses. Archive does not enable a new destructive epoch.
See [CHG-2026-084](../../changes/chg-2026-084-vendor-sn-retained-archive/proposal.md).

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

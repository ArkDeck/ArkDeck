# Rockchip Integration Profile

> ID: `ROCKCHIP-ROCKUSB-DISCOVERY`
> Version: `1.0.0`
> Platform: macOS
> Registered by: CHG-2026-026 / TASK-RKFUI-001

This profile registers one E0/read-only discovery operation for the user-selected,
hash-pinned `rkdeveloptool` build. It grants no generic Rockchip command authority.

- Executable source: explicit user selection plus app-scoped security-scoped bookmark.
- Tool identity: `rkdeveloptool ver 1.32`, SHA-256
  `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`, upstream
  commit `304f073752fd25c854e1bcf05d8e7f925b1f4e14`.
- Exact argv: `ld`.
- Effect: read-only observation.
- `maximumOutputBytes` is the combined limit for stdout and stderr.
- Unknown output, unknown mode, duplicate device number/location, stderr, identity drift,
  stale bookmark, rejected platform trust, timeout, or cancellation fails closed.
- `Loader` and `Maskrom` are the only registered mode tokens. Only
  `0x2207:0x350a + Loader` is applicable to the existing Provider; Maskrom and similar
  device families remain visible as typed blocked observations.
- `sudo`, shell, helper/driver installation, ACL/group/system-rule mutation, HDC mode
  switching, `ppt`, `wlx`, `rd`, and every destructive operation are outside this profile.

The canonical machine-readable registry is
`rockusb-discovery/1.0.0/registry.yaml`; fixture byte identities are pinned by
`rockusb-discovery/1.0.0/resources.json`.

## DAYU200 HDC → Loader characterization

CHG-2026-026/TASK-RKFUI-001A separately registers one exact, one-run E1 characterization for
DAYU200/OpenHarmony 7.0.0.33 over USB. It does not broaden the E0 discovery profile or the
destructive Provider identity.

- The only possible mutation argv is
  `hdc -t <durable-connect-key> shell reboot loader`, materialized from a durable revision-1
  binding after impact confirmation and a durable `enterUpdater` intent.
- Success requires HDC disconnect plus one semantic `0x2207:0x350a + Loader` observation from the
  clean E0 tool; HDC exit `0` alone is insufficient.
- The run remains non-destructive: HDC server lifecycle mutation, default target, caller argv,
  host shell, `sudo`, `ppt`, `wlx`, `rd`, Flash/erase/format/unlock/update and retry are forbidden.
- Capability support and Core auto-rebind eligibility are separate verdicts. A supported mode
  transition does not authorize automatic rebind when cross-mode identity/topology evidence is
  insufficient.

The canonical machine-readable registry is
`loader-transition/1.0.0/registry.yaml`.

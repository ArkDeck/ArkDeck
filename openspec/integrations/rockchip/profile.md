# Rockchip Integration Profile

> ID: `ROCKCHIP-ROCKUSB-DISCOVERY`
> Version: `1.0.0`
> Platform: macOS
> Registered by: CHG-2026-026 / TASK-RKFUI-001

This profile registers one E0/read-only discovery operation for the user-selected,
hash-pinned `rkdeveloptool` build. It grants no generic Rockchip command authority.

- Executable source: explicit user selection plus app-scoped security-scoped bookmark.
- Tool identity: `rkdeveloptool ver 1.32`, SHA-256
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`, upstream
  commit `304f073752fd25c854e1bcf05d8e7f925b1f4e14`.
- Exact argv: `ld`.
- Effect: read-only observation.
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

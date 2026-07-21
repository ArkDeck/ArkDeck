# DAYU200 pinned-image partition decode summary

**Verification status: BLOCKED / partition acceptance not satisfied.**
Reaching `parameter.txt` in the single gzip/tar stream consumed seven
non-target member bodies. The accepted AC requires zero reads of other member
contents. In addition, path-based `lstat` then `open` cannot exclude a device
replacement race before `fstat`; absolute zero device access is not statically
proven. Changing either boundary requires separately approved governance. The
mapping below is failure evidence, not a passing acceptance claim.

Non-authoritative evidence valid only for the pinned archive identity
`fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`. The original `parameter.txt` text and archive
locator are omitted. Encoded offsets are decoded table fields only: no flash
address, protocol, compatibility, executable profile or hardware support is
derived or claimed.

| Evidence file | SHA-256 |
| --- | --- |
| `partition-mapping.json` | `965e3bf3bd926c76a646a1bc02ce1f3f4ba855b4e09a7e61b48872195c131347` |
| `member-reconciliation.json` | `55c3515667ff6b1bd8cc922721b0c46a649eee9203a6f8a40c23397765b2d4ad` |
| `process-audit.json` | `c1a84bfddb51267186f3e88a2f60766f9a0899daa6b0704ca663049f285c0db1` |

## Decoded mapping

| Partition | Size token | Offset token | Attribute |
| --- | ---: | ---: | --- |
| `uboot` | `0x00002000` | `0x00002000` | `none` |
| `misc` | `0x00002000` | `0x00004000` | `none` |
| `bootctrl` | `0x00001000` | `0x00006000` | `none` |
| `resource` | `0x00003000` | `0x00007000` | `none` |
| `boot_linux` | `0x00030000` | `0x0000A000` | `bootable` |
| `ramdisk` | `0x00002000` | `0x0003A000` | `none` |
| `system` | `0x00400000` | `0x0003C000` | `none` |
| `vendor` | `0x00200000` | `0x0043C000` | `none` |
| `sys-prod` | `0x00019000` | `0x0063C000` | `none` |
| `chip-prod` | `0x00019000` | `0x00655000` | `none` |
| `updater` | `0x00010000` | `0x0066E000` | `none` |
| `eng_system` | `0x00008000` | `0x0067E000` | `none` |
| `eng_chipset` | `0x00008000` | `0x00686000` | `none` |
| `chip_ckm` | `0x00020000` | `0x0069E000` | `none` |
| `userdata` | `-` | `0x01308000` | `grow` |

## Image-member reconciliation

- Inventory members reviewed: 17.
- `.img` members: 11; mapped by exact stem: 9; explicit image orphans: 2.
- Explicit partitions without an exact image member: 6.
- Match rule is deliberately exact and case-sensitive; punctuation aliases and
  similarity guesses are not promoted to facts.

| Image member | Result | Partition |
| --- | --- | --- |
| `boot_linux.img` | `mapped` | `boot_linux` |
| `chip_ckm.img` | `mapped` | `chip_ckm` |
| `chip_prod.img` | `orphan` | `—` |
| `ramdisk.img` | `mapped` | `ramdisk` |
| `resource.img` | `mapped` | `resource` |
| `sys_prod.img` | `orphan` | `—` |
| `system.img` | `mapped` | `system` |
| `uboot.img` | `mapped` | `uboot` |
| `updater.img` | `mapped` | `updater` |
| `userdata.img` | `mapped` | `userdata` |
| `vendor.img` | `mapped` | `vendor` |

## S2 citations

Source-selection policy: `openspec/changes/chg-2026-007-dayu200-flash-route-planning/evidence/route-b-plan.md#gap-dayu200-partition-semantics分区表语义`.

- [Linux kernel command-line partition parser](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/mtd/parsers/cmdlinepart.c) — mtdparts size/offset/name grammar background.
- [Rockchip official rkbin repository](https://github.com/rockchip-linux/rkbin) — Rockchip image-package and parameter context.
- [Rockchip official rkdeveloptool repository](https://github.com/rockchip-linux/rkdeveloptool) — Rockchip partition/tooling context; no write behavior inferred.
- [OpenHarmony official device-development documentation repository](https://gitcode.com/openharmony/docs) — DAYU200/OpenHarmony device-porting context.

All S2 citations are contextual; decoded values come only from the pinned member.

# DAYU200 pinned-image partition decode r3 summary

**Fresh r3 platform result: PASS.**

The separately built and verified App Sandbox broker is bound by CDHash,
signed bundle manifest, reviewed-source hashes and a runtime receipt to
these exact core outputs. No real device node was opened.

The application-visible discard loop releases each non-target output chunk
before requesting the next codec read. The process audit separately records
the exact gzip-DEFLATE configuration, opaque 32768-byte history bound,
compressed-remainder runtime maximum and finally-driven destruction. Missing,
contradictory, over-cap or incomplete-cleanup receipt fields fail closed.

This is non-authoritative evidence valid only for pinned archive identity
`fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`. The original `parameter.txt` text and archive
locator are omitted. Encoded offsets are decoded table fields only: no flash
address, protocol, compatibility, executable profile or hardware support is
derived or claimed.

| Evidence file | SHA-256 |
| --- | --- |
| `partition-mapping.json` | `965e3bf3bd926c76a646a1bc02ce1f3f4ba855b4e09a7e61b48872195c131347` |
| `member-reconciliation.json` | `55c3515667ff6b1bd8cc922721b0c46a649eee9203a6f8a40c23397765b2d4ad` |
| `process-audit.json` | `aa0606b30f3d91fbef957129faafa0ffd570f7ba209352b9c5016a14989d43d2` |
| `broker-runtime-receipt.json` | `6784abe5bce6e319d876e4c0109382ecd21e37bc99e7abe885107e5638c58aee` |
| `broker-platform-evidence.json` | `fedf601515cdddc59a5cb59722f7987cde3f098ff4825ddaa253856f70753cf2` |

## Acceptance conclusions

| Test ID | Conclusion |
| --- | --- |
| `TEST-DECODE-DAYU200-PARTITION-001` | PASS — r3 codec receipt and bounded stream-discard validated against the pinned archive |
| `TEST-DECODE-DAYU200-INPUT-BOUNDARY-001` | PASS — fresh signed broker/platform/runtime binding validated |
| `TEST-DECODE-DAYU200-RECONCILE-001` | PASS — every inventory member and partition accounted for by exact-name rules |

## Acceptance metrics

- Identity pass bytes: 732948803; gzip pass bytes: 17956864.
- Tar headers: 8; preceding bodies: 7; discarded body bytes: 178168731.
- Maximum application-visible chunk: 1048576 bytes; application reference retained into next read: 0 bytes.
- DEFLATE internal history: RFC 1951 codec-owned opaque state; inaccessible to application; upper bound 32768 bytes.
- Compressed remainder observed maximum: 65536 bytes; after close: 0 bytes; live non-target plaintext after close: 0 bytes.
- Parameter raw text persisted: no; archive locator persisted: no; member extraction: none.
- Production decoder subprocess/network/device-mutation dispatch counters: all zero.
- Broker: `io.arkdeck.partition-decode-broker`; CDHash `9a86497889efda13167cf6dfb9f7585c57c46265`; bundle tree SHA-256 `8eaf2e0c21f6317aef20ab782d789671514adb6ebf7f07192608524c90d622d4`.
- Embedded Python: `3.14.6` from `sys.version_info in verified embedded CPython child`.

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

- Inventory members: 17; `.img` members: 11.
- Exact-stem mapped: 9; image orphans: 2; partition orphans: 6.
- Exact case-sensitive matching only; aliases and address inference are forbidden.

## S2 citations

Source-selection policy: `openspec/changes/chg-2026-007-dayu200-flash-route-planning/evidence/route-b-plan.md#gap-dayu200-partition-semantics分区表语义`.

- [Linux kernel command-line partition parser](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/mtd/parsers/cmdlinepart.c) — mtdparts size/offset/name grammar background.
- [Rockchip official rkbin repository](https://github.com/rockchip-linux/rkbin) — Rockchip image-package and parameter context.
- [Rockchip official rkdeveloptool repository](https://github.com/rockchip-linux/rkdeveloptool) — Rockchip partition/tooling context; no write behavior inferred.
- [OpenHarmony official device-development documentation repository](https://gitcode.com/openharmony/docs) — DAYU200/OpenHarmony device-porting context.

All S2 citations are contextual; decoded values come only from the pinned member.

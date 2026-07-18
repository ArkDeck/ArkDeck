# DAYU200 archive characterization summary

Non-authoritative, fixed-archive-only characterization evidence
(CHG-2026-003 / TASK-DAYU200-CHAR-001). `unknown` axes are expected
outputs, not defects. This summary derives from the four JSON results:

| Evidence file | SHA-256 |
| --- | --- |
| `archive-identity.json` | `7ea6a1bcf0ac9a39bf53fb215facddd925e845aadb086c2c1c07e085e5577e53` |
| `member-inventory.json` | `429763e6fabcaaa2f7323eab862fdb8c65d63ecc88afb441a36073ee5c35818c` |
| `package-classification.json` | `a91c232ed9e74b6173054820532cfbd364aaa6bcde216b3d9b02ea785697b0b1` |
| `process-audit.json` | `b406792b291f9854c0e3c4de33cc7742073adba385f8b201480573d67f2f9a19` |

- imagePackageFamily: `rockchipRawImageSet`
- deviceFlashProvider: `unknown`; targetCompatibility: `unknown`;
  imageProfileReadiness: `candidateNonExecutable`;
  executableProfile: `false`; hardwareSupportClaim: `false`.

## Gaps feeding DEC-002 and the Route-B CLI plan-only work

- `GAP-DAYU200-PARTITION-SEMANTICS` (partition semantics): parameter.txt partition table semantics are not interpreted; member bytes are hashed but never decoded.
- `GAP-DAYU200-FLASH-ADDRESSES` (flash addresses): no flash offset/address mapping is derived from any member.
- `GAP-DAYU200-FLASH-PROTOCOL` (flash protocol): no flashd/rockusb/USB/UART/TCP protocol fact is established.
- `GAP-DAYU200-RECOVERY-PATH` (recovery path): no recovery/rescue path for an interrupted flash is established.

## Non-authoritative follow-up recommendations

- Resolve the four gaps above via the later Integration change before
  any Flash Provider decision (DEC-002); this evidence cannot satisfy it.
- Keep the raw archive outside the repository; only size/SHA-256 and
  member hashes are recorded here.
- Any executable-profile or hardware claim requires separate M0B work;
  nothing in this run supports one.

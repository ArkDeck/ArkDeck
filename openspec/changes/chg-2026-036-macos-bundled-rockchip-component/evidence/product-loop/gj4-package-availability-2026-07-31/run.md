# GJ-4 product package availability run — 2026-07-31

## Product result

The GJ-4 release package is materializable and locally production-available
from final base `32c0466f`. The package pipeline returned `PASS`, Apple notarization
returned `Accepted` with zero issues, the stapled DMG and contained App passed
independent Gatekeeper checks, and `flash.dayu200@1` returned `available` after
the daemon bound its complete fixed product dependencies.

This closes the package-availability product defect only. No Flash was
dispatched, so GJ-4 is not a real-device pass.

## Root cause and fix

`arkdeck-code-sign-enable` is an arm64 OpenHarmony device helper that the host
transfers as data and changes to mode `0700` through its typed remote plan. Its
repository executable bit made Xcode classify the foreign ELF resource as
nested macOS code, so the fixed package inventory rejected the archive before
DMG creation.

The host resource is now stored without executable bits, while the existing
typed plan remains responsible for the remote `chmod 700`. Contract tests pin
both sides of that boundary. The packager also accepts an explicit absolute
local Keychain file for `notarytool`; it validates the file, uses it for every
notary request, and redacts both the profile and Keychain path from failures and
receipts.

## Accepted package tuple

| Field | Value |
| --- | --- |
| Package | `arkdeck-rockchip-component-package@1.0.0` |
| Apple submission | `69651406-8b1d-4a52-bb01-94b0e3158f03` |
| Notary result | `Accepted`, issue count `0` |
| App | `com.arkdeck.desktop` `0.1.0` (`1`) |
| App tree SHA-256 | `c9e535909285df4567a3e9767781a6d3e2f58ceec9556b4f1deff562cce3308b` |
| Signed component SHA-256 | `0a46cb69ec86fe5ae4d077fe58838e9ac85b66a147e7be6e443c25cbb0799ee3` |
| Stapled DMG SHA-256 | `bfcbbef2d02f7da1e14ea41a5fb2630312b7793ae0c06bce0433350abd78aaa3` |
| Tuple SHA-256 | `fd97447a0f66b6f2369ac01fb44d6be0469decce6c21f7279b7dc39de5cc0e7e` |

The DMG and sanitized receipts were persisted under the versioned user-level
ArkDeck release directory. The App was installed into the product resolver's
fixed user Applications location. Neither location is committed to Git.

Earlier packages from pre-rebase bases `f72b1681` and `37bfce74` were accepted
by Apple, then excluded from final evidence when `origin/main` advanced. The
final tuple above was rebuilt from the rebased delivery head; no superseded
hash is used as a product result.

## Independent checks

| Check | Result |
| --- | --- |
| `stapler validate` | PASS |
| DMG Gatekeeper | accepted, `Notarized Developer ID` |
| `hdiutil verify` | valid checksum |
| mounted App strict/deep signature | valid; child prepared and validated |
| mounted App Gatekeeper | accepted, `Notarized Developer ID` |
| installed App strict/deep signature | valid; child prepared and validated |
| installed App Gatekeeper | accepted, `Notarized Developer ID` |
| installed component SHA-256 | exact receipt value |
| receipt/profile privacy check | no notary profile or Keychain path persisted |

The signed App check was repeated outside the filesystem sandbox because the
sandboxed macOS Security service returned a false `code or signature have been
modified` result for the read-only mount. The same bytes passed strict/deep
`codesign` and Gatekeeper outside the sandbox before installation and again
after installation.

## Runtime availability

The local daemon used a fresh owner-private state directory. With no HDC
executable bound, `operation.list` correctly returned
`flash.dayu200@1 = unavailable` because the complete descriptor-bound host could
not materialize. After binding the fixed installed HDC executable
(`sha256:05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`)
without executing it, the same call returned:

```json
{
  "availability": "available",
  "reasons": [],
  "reference": "flash.dayu200@1"
}
```

Both daemon instances shut down normally. No App, component, HDC command, USB
operation, device operation, Runtime job, capability consumption, E1, E2,
device mutation, or destructive action occurred. The post-package local App
installation was operator-authorized host-side setup and is outside the
packager receipt's zero-effect counters.

## Repository verification

| Command | Result |
| --- | --- |
| `python3 -B scripts/rockchip_component/test_rockchip_component_package.py -v` | 26 passed |
| `swift test --package-path Packages/ArkDeckKit` | complete suite, 1 skipped, 0 failures |
| `sh ./scripts/check-sdd.sh` | 0 errors, 0 warnings, 114 existing acceptance IDs |
| canonical receipt/log byte comparison | exact product output |
| profile, Keychain, and user-path scan | no local value persisted |
| `git diff --check` | PASS |

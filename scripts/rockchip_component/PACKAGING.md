# ArkDeck macOS release packaging

`rockchip_component_package.py` is the only repository-owned entry point for
TASK-BRC-003. It consumes one explicit unsigned `rkdeveloptool` file and creates
one independently verified, Developer ID-signed, notarized, and stapled DMG.

The tool does not download or rebuild the component. It does not search `PATH`,
read a component path from the caller environment, use Homebrew/cache fallback,
install or launch the App/component, publish a release/feed, or access HDC, USB,
or a device.

## Preconditions

- Run on the maintainer-controlled release environment accepted by the current
  TASK-BRC-003 readiness record.
- Materialize GitHub Actions artifact ID `8640763234` from workflow run
  `30233237693` into a fresh temporary directory. The packager independently
  requires the registered regular-file, no-symlink, size, SHA-256, Mach-O,
  architecture, minimum-OS, load-command, dependency, unsigned-signature, and
  static-version facts before any archive/sign/notary action.
- Keep the Keychain notary profile opaque. Never place its name, account,
  password, token, private key, or path in the repository, command logs, or
  evidence.
- Pass a fresh output path outside the repository. Existing output is never
  overwritten.

Example, with local values supplied only by the release operator:

```sh
python3 -B scripts/rockchip_component/rockchip_component_package.py \
  --component /private/tmp/<fresh-artifact-root>/rkdeveloptool \
  --notary-profile '<opaque-keychain-profile>' \
  --output /private/tmp/<fresh-release-output>
```

The command uses absolute system/Xcode executables and argument arrays. It
performs this fixed sequence:

1. inspect the exact unsigned input and revalidate Developer ID/notary access;
2. copy into fresh staging and apply only the required ad-hoc ingest signature;
3. run an arm64 macOS 14.0 Release archive through Xcode Code Sign On Copy;
4. independently verify child then App signature, designated requirement,
   entitlements, Team/certificate, Hardened Runtime, timestamp, architecture,
   minimum OS, bundle metadata, and nested-code inventory;
5. create and sign one fixed-layout DMG;
6. submit that outermost DMG, require `Accepted`, and retrieve a sanitized log;
7. staple/validate, assess the DMG with Gatekeeper, mount it read-only, and
   assess the contained App;
8. emit an immutable atomic tuple receipt.

On any mismatch, unknown state, non-zero command, rejection, missing log,
staple/Gatekeeper failure, or timeout, the fresh staging and candidate output
are deleted. A failure never falls back to another component, identity, team,
architecture, location, or distribution path.

## Outputs

The fresh output directory contains:

- `ArkDeck-0.1.0-arm64.dmg`
- `package-receipt.json`
- `notary-log.json`

The DMG, App, component, artifact archive, and temporary certificate extracts
must remain outside Git. Only the two sanitized JSON records may be copied into
the task evidence directory after independent review.

## Offline tests

```sh
python3 -B scripts/rockchip_component/test_rockchip_component_package.py -v
```

The mutation matrix covers input identity/type, binary shape, nested location,
App/child signature and entitlement facts, metadata and extra nested code, DMG
shape/signature, notary/log state, staple/Gatekeeper, and the final atomic tuple.
These tests do not sign, notarize, launch, install, or access devices.

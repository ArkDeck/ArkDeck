# Security policy

ArkDeck drives real devices, including install, cleanup, and flash paths. A
report that describes an authorization bypass, a trusted-fact forgery, a
capability that can be minted outside the runtime, or a flash aimed at the
wrong device is in scope.

## Reporting

Please report a vulnerability privately. Do not open a public GitHub issue,
pull request, or discussion for it.

Use GitHub private vulnerability reporting:

<https://github.com/ArkDeck/ArkDeck/security/advisories/new>

If that page is unavailable, contact the maintainer listed in
[`.github/CODEOWNERS`](.github/CODEOWNERS) directly and wait for a private
channel. There is no public security mailing list.

## What to include

- affected component (macOS app, Windows client, `arkdeck` CLI, `arkdeck-agentd`,
  a provider, the catalog, or a contract)
- the version or full git commit you ran
- the impact you can already demonstrate, at a high level
- whether a device, credential, or local artifact store was involved

Do not include device serial numbers, HDC connect keys, account names, machine
names, home-directory paths, signing keys, or raw artifacts. Redact logs before
you send them.

## What happens next

The maintainer acknowledges a report that reaches the private channel and
agrees on a fix and a disclosure window before any public write-up. This
repository does not publish git tags or GitHub releases for security fixes;
the fix lands on `main` through a reviewed pull request.

There is no bug bounty.

## Supported versions

| Version | Supported |
| --- | --- |
| `main` (0.1.0 preview) | yes |
| older untagged history | no |

Only the `main` branch is supported. Preview interfaces can change before the
first stable release.

## Out of scope

- a missing hardware feature or a product request with no security impact
- a vulnerability in an OpenHarmony image, `hdc`, or another third-party tool
  that ArkDeck does not ship, except where ArkDeck fails to contain it
- social-engineering attacks against a maintainer account

# macOS RC3 host verification — 2026-10-04

Scope: release provenance, signature/notarization, read-only cutover preflight and pre-cutover version-mismatch UX. The five real-device Golden Journeys are excluded. No installed helper was replaced and no device operation was dispatched.

Release workflow [37075826611, attempt 4](https://github.com/ArkDeck/ArkDeck/actions/runs/37075826611) succeeded after the Apple agreement was accepted. Source is `3efba88c18adbc28be7fb9ef0e495195aaec39c0`; artifact is `arkdeck-rc-0.1.0-3`, ID `11291674407`. The trusted workflow summary pins DMG SHA-256 `3e7815e7ca5f38a9e58a65f68eeff1a35cd5541396f3cf5cf1d8b8b92e28e7c6`. The downloaded receipt and executable digests match. App notarization `282a5ed7-a3a6-4114-bc84-c3cad24d17d8` and DMG notarization `c0b93475-3597-4e31-abac-62955e70decc` are Accepted.

## Local targeted checks

- Release verifier with trusted source/SHA, `codesign --verify --deep --strict` and exact Team/identifier requirements for App, CLI and daemon: exit 0. ArkForge's two executable members are signed and verified individually; its manifest-only container is not an executable bundle. App/DMG stapler validation and Gatekeeper assessment: accepted.
- Released daemon `--cutover-preflight`, production composition, without `--hold-instance-lock`: exit 0; `clear:false`, `instanceLockHeld:false`. Its released source was checked to confirm this early path does not start the Runtime or rewrite records. The census reports 67 Jobs, 61 Agent executions and 29 capability uses. The remaining blocker is one retained historical Rockchip Session with a missing Manifest. Its preserved journal contains an enter-loader intent followed by waiting-for-recovery, without an outcome. It is not an empty directory and was not deleted or reconstructed. Matching Session/Job filenames were not found in the installation backup directories.
- Corrected `installed_spk8_negatives.py version-mismatch` from PR [#2455](https://github.com/ArkDeck/ArkDeck/pull/2455), against RC3 and the unchanged installed legacy facade: exit 0, two refresh/remedy/exit cycles. Scope is `pre-cutover-legacy-facade`; this is not the installed pure-Rust positive case or GJ acceptance. Both readonly DMG mounts were detached afterward.
- Logs and exact receipts remain locally under `/private/tmp/arkdeck-macos-closeout-20261004/`: `rc3-verify.log`, `rc3-signature-checks.log`, `rc3-preflight-20261004.json`, `rc3-version-mismatch.log`, and `rc3-version-mismatch/result.json`. Earlier failed legal-agreement attempts and the corrected signature-command invocation remain in their logs.

The preserved unknown Session blocks installation continuity. Installed pure-Rust positive SPK8, foreign-client checks, SDK build/sign through that installation and quiet-host measurements remain unexecuted. User confirmation cannot replace the required continuity/recovery proof.

## CI

RC3 workflow attempt 4: success. PR #2455 Swift CI `37173196591` and SDD Guard `37173196455`: success; maintenance review remains required. Device preview/keyboard-pointer PR #2458 was corrected to use the shared font role; Swift CI `37174732112` and SDD Guard `37174731930`: success. These CI results establish host checks, not hardware acceptance or maintainer approval.

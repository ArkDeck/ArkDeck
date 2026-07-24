# TASK-AU-002 implementation run — 2026-07-24

## Scope and classification

- Change/task: `CHG-2026-023` / `TASK-AU-002`
- Execution class: host-only implementation + offline contract
- Readiness merge/start base:
  `b8a6656ad2d04ead59443053cd646e31907c873c` (PR #447)
- After review remediation the implementation branch was rebased on protected `main`
  `60ea5266e506f88b81c0ef8a2c6744c770b5b3d5`. Changes since the prior base belong to
  CHG-2026-030/033 and TASK-RKFUI-001A; the AU-002 change, App/package/CLI/logger/test inputs and
  all declared AU-002 allowed paths have zero overlap/drift.
- Real update-feed/artifact network requests: 0
- Release/upload/publish operations: 0
- Production private-key access/probe/sign operation: 0
- Real DMG mount/open/install/App replacement: 0
- Device/HDC/external destructive dispatch: 0
- Finder/`NSWorkspace` production handoff during tests: 0

Contract fixtures use process-memory ephemeral Ed25519 test keys, URLProtocol request capture,
temporary owner-only files, injected artifact-signature results and a counted fake Finder
revealer. They are `contractFake`, not release, notarization, real Team identity or real-hardware
evidence.

## Delivered implementation

- Pinned single-key Ed25519 envelope, domain-separated signature input, canonical payload,
  strict schema/base64/size/timestamp/version/architecture/URL checks and durable
  `(sequence,payloadSHA256,version)` replay protection.
- Cookie/credential/cache-free `URLSession` requests with the exact product query allowlist,
  fixed privacy-neutral headers, HTTPS host allowlist, product-query stripping on redirects and a
  five-hop ceiling.
- User-started bounded streaming download into random no-follow `.part` files; signed length and
  SHA-256 are checked before owner-read-only same-volume rename. Failure/cancel/orphan partials
  are removed and no installed-App path exists in the workflow. Service cancellation directly
  cancels the active download task/stream; operation-ID ownership prevents a late completion from
  clearing or overwriting a successor operation.
- `SecStaticCodeCreateWithPath` strict/all-architectures/nested validation plus a same-Team
  requirement derived from the running App. File identity, length, digest, static validity and
  Team identity are repeated after final consent and before the App-level Finder reveal.
- Default-on, user-disableable launch check with a 24-hour attempt interval; check, download and
  final Finder reveal remain separate transitions. App copy states that installation/mount/
  replacement is manual and that there is no update-on-quit or automatic rollback. An incomplete
  automatic check uses a neutral retry status rather than claiming that the App is current, and
  the final-consent state retains the signed release-note summary instead of showing a cache UUID.
- Redacted closed SystemLogger update events; no URL, version, path, Team, request or error text
  enters diagnostics.
- `arkdeck update-feed prepare|assemble` deterministic public-material pipeline. It has no
  private-key option/path; `prepare` validates every static signed-payload field before the
  isolated signing step, and `assemble` proceeds only after pinned-public-key and full payload
  self-verification.
- Maintainer release order and interactive OpenSSL Ed25519 signing procedure in
  `docs/release/macos-auto-update.md`; feed is published last. The procedure explicitly records
  the approved v1 freshness contract: a feed is valid for at most 30 days, same-version renewal is
  rejected, and a higher stable patch/version must be published before expiry.

External package/XPC/helper/entitlement additions are all 0. The App entitlement file remains the
exact ADR-0002 six-key set.

## Contract results

`TEST-AU-CONTRACT-001` covers:

- production public-key/key-ID/SPKI hash pins and valid signature;
- broken, missing, wrong-signer and wrong-key feed signatures;
- unknown/duplicate/noncanonical envelope and signed payload members;
- downgrade, lower sequence, same-sequence conflict, non-increasing release, idempotent replay,
  expired/future feed and invalid artifact URLs;
- overflow, truncate, digest mismatch, interruption and cancellation cleanup;
- active download-stream termination on service cancellation and late-catch/successor-operation
  isolation;
- unsigned/different-Team result, verify-after-download replacement, missing final consent and
  unchanged installed-byte sentinel;
- default-on/rate-limited check, zero automatic artifact request, two user actions before the one
  counted handoff, neutral automatic-failure status and signed release-note retention;
- pre-signing version/timestamp/validity/URL rejection, two-part installed-App version
  normalization and a strict three-part product marketing-version guard;
- exact six entitlements, zero external package/project reference, product-source private-key
  marker exclusion and closed public SystemLogger events.

`TEST-AU-PRIVACY-001` captures actual URLSession requests through URLProtocol for feed, artifact
and redirect. It asserts exact initial product query names, signed artifact URL preservation,
redirect removal of `appVersion`/`osVersion`/`arch`, only fixed `Accept`/`User-Agent` request
headers, and zero body/cookie/Authorization.

## Commands and results

| Command | Result |
| --- | --- |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter AutoUpdateContractTests` | PASS; 14 tests, 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS; 397 tests, 0 failures, 1 pre-existing manual sleep/wake skip |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO -quiet` | PASS |
| `ARKDECK_PYTHON=/opt/homebrew/anaconda3/bin/python3 ./scripts/check-sdd.sh` | PASS; 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | PASS |
| `jq empty ArkDeckApp/Resources/Localizable.xcstrings` | PASS |
| entitlement `plutil`/`jq` exact-set check | PASS; six true keys, no diff |
| external dependency/project-reference/`Package.resolved` guards | PASS; 0 |
| product update-source private-key material marker guard | PASS; 0 |

## Review remediation conclusion

- Same-version feed renewal was not enabled: the approved readiness contract requires every higher
  sequence to carry a strictly higher stable version. The 30-day maintenance-release obligation is
  now explicit in the release procedure rather than silently implied by code.
- Automatic failure copy, operation ownership, active stream cancellation and signed release-note
  presentation were corrected and are covered by the 14-test updater contract.
- The feed/artifact host allowlist now has one source; the unused internal-state failure code was
  removed; two-part installed versions are normalized; prepare performs static payload preflight;
  Foundation/write-zero error paths no longer report a stale process-global `errno`.
- The Security.framework negative matrix remains typed-seam `contractFake`. No Developer
  ID-signed/notarized DMG was introduced, so the release procedure's real manual check remains a
  mandatory non-automated gate.

## AC conclusion and residual boundary

- `TEST-AU-CONTRACT-001`: **PASS (candidate contract evidence)**.
- `TEST-AU-PRIVACY-001`: **PASS (candidate contract evidence)**.

The production Security.framework path is compiled by both SwiftPM and Xcode; the offline
negative Team/unsigned matrix is exercised at its typed validation seam because this run has no
Developer ID-signed/notarized fixture and does not perform a release. This evidence therefore
does not claim a production release, notarization, real Team-signed DMG acceptance, task `done`,
change `verified`, or ADR-0002 release-gate completion. Those remain subject to maintainer PR
review/merge and the separate governance transitions.

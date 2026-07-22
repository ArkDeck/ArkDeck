# CHG-2026-015 Verification Plan

> Change:CHG-2026-015-hdc-readonly-probe-registration@r3
> Status:passed;maintainer confirmation 见 proposal.md Verification closure(2026-07-21)
> Core baseline:CORE-2.0.0
> Integration input:OPENHARMONY-TOOLS@0.2.0 / INTEGRATION-PROFILES-0.3.0

## Environment

- Registration verification is headless and uses only repository fixtures, maintainer-approved
  controlled input/receipt bytes, local files and Swift contract tests.
- Agent/CI installed-real-HDC, real-device, non-loopback network, server lifecycle/subserver/device
  migration and destructive dispatch are prohibited.
- macOS unlock, Developer Mode and XCUITest are not required and produce no evidence for this
  change.

## Acceptance matrix

### I15-HDC-SERVER-IDENTITY-001

Method:registry-schema review + controlled platform receipt + substitution/adversarial contract.

Expected:the entry binds an already-existing server process/start identity, executable identity and
exact endpoint; same recipe supports post-dispatch observation. PID shape, endpoint reuse,
`checkserver`, caller generation, path/inode replacement and absent-server states cannot establish
identity/ownership/generation, and command/server-start dispatch is 0 when the precondition fails.

### I15-HDC-AUTH-BINDING-001

Method:exact argv/raw-family provenance review + stale/mismatch/ambiguous binding vectors.

Expected:only a registered selected-device observation is classified; it must match the already
durable identity and binding revision. The probe cannot choose a default target, mint/revise a
binding or infer channel protection. Unknown, denied, stale, mismatch, timeout and cancellation
remain typed fail-closed results with lifecycle/device mutation dispatch 0.

### I15-HDC-KEY-ACCESS-001

Method:platform file-access receipt review + synthetic missing/denied/readable-public/private-denied
vectors + privacy scan.

Expected:the entry uses only a configured/user-approved locator and emits bounded diagnostics plus
an optional public-key fingerprint. Private-key read/hash/copy/delete/chmod/upload count and raw
key/path logging count are 0; missing authority or access returns unavailable/denied without server
mutation.

### I15-HDC-SUBSERVER-001

Method:exact argv/raw-family/effect provenance review + unknown/version-only/mutation-name vectors.

Expected:only a client-local help/capability family with proven zero server lifecycle and device-
migration effect may be supported. `spawn-sub`, `killall-sub`, mutation aliases, version-only
inference and unregistered output remain unsupported; all mutation counters are 0.

### I15-HDC-PROVENANCE-001

Method:source lineage, evidence-class, privacy and immutable-hash review.

Expected:every supported production family points to authoritative documentation or a maintainer-
approved controlled-human capture/receipt with exact tool/command/platform context and hash. Fake
inputs are labelled control-only; no device identifier, private key, user path, secret or raw
sensitive artifact enters the repository.

### I15-HDC-REGISTRY-001

Method:YAML/resource/schema contract + independent profile/registry/lock/fixture SHA-256 closure.

Expected:all four families have a supported or unsupported entry; IDs, versions, paths, effect,
fixture/receipt IDs and hashes agree across resource registry, OpenHarmony profile, structured
registry and Integration lock. Unknown/partial/duplicate entries fail parsing and old 0.2.0
consumers do not acquire new authority.

### I15-HDC-NODISPATCH-001

Method:command log, process/network/device static audit and instrumented test counters.

Expected:TASK-I15-001 executes no installed HDC, real device, non-loopback network, server
lifecycle, subserver, device migration or destructive action. All such counters are 0; registration
does not stop, restart, adopt or reconfigure a pre-existing HDC server and does not change
TASK-M1-006 or claim any source AC/conformance/support/release result.

## Negative and recovery gates

- candidate command with unknown server-start behavior => unsupported or existing-server-only;
- raw family/version/stream/exit mismatch => unknown, never nearest-family classification;
- receipt produced by untrusted executable/endpoint or after identity change => invalid;
- cancellation-ignoring command contract without owned-resource termination receipt => unsupported;
- one missing family/provenance/hash => whole registration task remains incomplete;
- revert of the registration PR restores 0.2.0 inputs without deleting old evidence.

## Archive relocation gate (r3)

The later archive PR must satisfy all of the following without rerunning or rewriting the historical
TASK-I15-001 evidence:

- move this change exactly to
  `openspec/changes/archive/2026-07-22-chg-2026-015-hdc-readonly-probe-registration/`;
- replace only the four production `provenance.sourcePath` active-root values in the living
  registry and its fixture mirror, while source bytes/SHA-256, `acceptedBy`, recipe, effect,
  precondition, authority, versions and family closure remain unchanged;
- independently recompute all four receipt hashes/sizes, the mirrored registry hash/size and
  `resources.json` hash/size, then re-pin only the exact living consumers named by Decision 6;
- prove the living registry and fixture registry are byte-identical and every resource hash/size
  resolves to the bytes at its declared path;
- normalized before/after comparison reports no semantic delta beyond the four path replacements
  and their derivative hash/size closure; archived evidence and prior run hashes remain unchanged;
- repository search finds no production provenance reference to the old active change root, while
  historical archive-local records remain truthful; `HDCProbeRegistryContractTests`, the full Swift
  suite, `scripts/check-sdd.sh` and `git diff --check` all pass.

Failure of any item blocks the archive move. Passing this gate authorizes no HDC/device/network or
mutation dispatch and changes no prior acceptance result.

## Result gate

- All seven change-local Test IDs need same-revision reviewable evidence before TASK-I15-001 can
  be marked done and the change can later be proposed verified.
- Passing this change only establishes integration inputs. M1-006 must separately adopt them and
  still complete signed Sandbox/XCUITest platform evidence.
- The r3 archive-only gate preserves the existing passed result; it does not require or permit
  reclassification of the seven historical acceptance results.

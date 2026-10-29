# Tasks — CHG-2026-088

## TASK-ATN-001 — Prepare the macOS SDK consumer

- Status:in-progress; implementation and local checks complete; PR CI and protected-main approval remain pending.
- Objective:consume the shared native runtime with ArkDeck's fixed product
  profile, source revision and matching staged SDK.
- Scope:package/Xcode source pins, adapter, App startup/Quit, fixed bundled
  resources, targeted build runners, affected tests and this change.
- Allowed paths:apple/Packages/ArkDeckKit/**, apple/ArkDeck.xcodeproj/**, apple/ArkDeckApp/**,
  hack/ci/**, hack/release/**, .github/workflows/{swift-ci,swift-slow-lanes,release-rc}.yml and this change.
- Dependencies:ArkTrace ABI-2 SDK and pinned source revision from the proposal.
- Verification:focused adapter and source-pin contract tests; compile both
  default and explicitly staged native dependency graphs.
- Stop conditions:incompatible SDK/source generation, publisher drift, or
  inability to verify the chosen consumer inputs. Do not substitute the
  standalone ArkTrace profile or claim App/daemon cutover from adapter tests.

Future format-4 cutover must verify signed App startup/shutdown and
helper resources, then replace the reviewed analyzer distribution/schema contract and
prove daemon purge cannot delete active format-4 entries. Actual Artifact and
GUI checks, selected PR CI and maintainer review are still required.

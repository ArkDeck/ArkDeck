---
id: CHG-2026-086-expired-unknown-recommission
revision: 2
status: proposed
class: core
core_change_level: major
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# Controlled recommissioning of an expired, archived unknown board

Revision 2 implements the maintainer's explicit 2026-10-18 request for one
controlled retry after the failed first recommissioning. The original unknowns,
capability consumption and allocation remain immutable. Runtime must account for
both the archived source and the failed recovery, prove both writers quiescent,
and cover every old and new uncertain effect before reserving one additional
1,800-second allocation. Explicitly naming the failed Job is only a reference;
it is not authority or a supplied proof. A third allocation remains forbidden.

The first real execution also demonstrated that Loader readback cannot verify
seven ranges outside its read window. The retry therefore requires a complete
pre-materialized verification path, including pre-mount userdata measurement and
full original-ramdisk restoration. Earlier typed skips remain skips. The scoped
delta, implementation and checks are delivered together before device dispatch;
the user's authorization includes completing the PR, CI and protected-main merge.
This does not claim hardware acceptance or mark this change verified.

GJ-4 currently leaves an expired unknown Flash blocked even after its retained-risk
archive has completed. A revision-1 Normal-only adoption also cannot identify its
Loader using the historical CID. Ordinary complete-overwrite recovery must retain
both refusals. This proposal adds `flash.recommission@1` for this exact case.

The protected-main Runtime proves the published retained archive, the unchanged
historical binding and all outstanding effects. A fresh CPU/CID/factory-SN/USB
chain connects that binding to the actual Loader before writing. One separately
recorded recovery allocation permits one serial complete overwrite within 1,800
seconds. It cannot renew the original budget or be reallocated merely by changing
a request ID, restarting, abandoning or archiving the new recovery. Only the
explicitly scoped controlled retry above may append a second allocation; another
unknown retains all uncertainty and cannot obtain a third.

Every mapped partition, immutable Artifact, Provider coverage declaration,
readback, reboot, rebind and postflight proof remains mandatory. Only a verified
recovery epoch may supersede the old intent and publish the new binding lineage.
Historical outcomes, budgets, records and bindings remain byte-for-byte unchanged.

The initial production path is Windows, whose existing verified HDC child runner
provides kernel kill-on-close containment. The exact archived Provider Job must
also be observed terminal with no other live Provider work. macOS stays blocked
until equivalent historical child-lifetime proof is available; its required
identity, coverage and process gates are not waived.

This is a proposed narrow exception to POL-AGENT-002's expired-invocation rule,
not an interpretation that the current rule already permits a reset. The
[scoped delta](spec-delta.md), implementation and validation require maintainer
review before protected-main publication. No Agent approval, ratification or
hardware acceptance is claimed. Device execution waits for that publication.

---
id: CHG-2026-084-vendor-sn-retained-archive
revision: 1
status: proposed
class: core
core_change_level: minor
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# Verify factory-serial boards and archive expired unknown Flash jobs with risks retained

Some DAYU200 boards expose an OTP-derived CPU serial in Linux, a factory SN in
Loader and an eMMC CID in Normal USB. Requiring those distinct namespaces to be
equal prevents the supported mode transition. Separately, an expired unknown
Flash currently cannot leave `waitingForRecovery`, because the archive writer
supports only confirmed, quiescent jobs whose resources may be released.

This GJ-4 increment adds a bounded Runtime-owned factory-SN proof and a terminal
archive that retains uncertainty. It travels with implementation and tests for
maintainer review. No operation, provider, profile, capability-admin surface or
caller-supplied identity is added. Existing CPU-serial boards keep their path.

The factory route requires an exact USB-bound Normal target, the registered
DAYU200 device-tree compatibility, matching eMMC CID, the boot device-tree SN,
SN_ID=1 from the current validated Rockchip vendor slot, the already bound Loader
digest, and repeated CPU/attachment observations. The CPU and factory serial
remain separate facts. Only public vendor metadata and SN_ID are read. A mutable
factory serial is never relabeled as an immutable CPU identity. Missing evidence,
duplicate/overlapping metadata, ambiguity, changed sources or timeout blocks the
transition. Original unknown Jobs and incomplete bindings are never backfilled.

An expired unknown full-restore Job can archive as `interrupted` through the
existing review-hash and user-decision API. A new `archivedWithHazards` journal
outcome has `releaseAuthorized: false`; its Session remains `outcomeUnknown` and
lists all device and process uncertainty. Original timestamps, intents, outcomes,
capabilities, recovery epochs and budgets remain intact. Archive does not stop an
unproved process, release a device/resource hold, or enable another Flash.
The existing App archive review and receipt expose the retained hazards and
refuse a response that clears uncertainty or claims resource release.

The additive Journal outcome is the scoped Core MINOR delta in
[spec-delta.md](spec-delta.md). Existing states and records remain valid. This PR
does not ratify a new Core baseline, mark a platform verified, or claim hardware
acceptance. Both declared platforms receive the same decoder, replay and Runtime
semantics; selected cross-platform CI is required. POL-RECOVERY-001 and
POL-AGENT-002 remain the authority for every later destructive dispatch. The
legacy user-override text in AC-JOB-007-02 supplies no such authority.

The previously diagnosed Normal-only unknown remains blocked even after this
delivery: current observations cannot establish its missing historical lineage,
and archival cannot reset its expired recovery budget.

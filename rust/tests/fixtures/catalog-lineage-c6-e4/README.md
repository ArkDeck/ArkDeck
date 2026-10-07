# Exact unchanged-operation expectation lineage

This is a test-only versioned source packet. Its historical 32 descriptors come
from `fc3630ea2240497f35061858a17381ea653beccb`; its current descriptors come from
the CHG-2026-081 working source. The official Catalog serialization reproduces
the exact c6 and e4 digests. All 31 non-Native descriptors are equal as complete
JSON values. Native differs by the three reviewed observation steps and is
explicitly refused by this packet's unchanged-operation plan adapter.

`catalogs.json` is whole-SHA-pinned by `tests/support/catalog_lineage.rs`. It is
not a new published Catalog, fixture approval, Runtime authority migration or
hardware result. All pre-existing oracle bytes and provenance pins remain intact.

The only wired consumer is `tests/job_plan.rs`: four successful plan-only
analyzer answers. It reconstructs the complete crash-signature materialization
from the fixed original request, exact pinned analyzer SHA, lease payload path,
invocation, timeout and complete current descriptor. Restoring only the plan's
top-level Catalog must reproduce the frozen historical materialized-plan SHA.
The new actual SHA must then equal the hash of that complete current plan.
Only these two answer fields are projected for the original whole-frame
comparison. Additional fields, step/source/target drift and refusals remain
subject to the original assertions. No Job, capability or Provider is started
by the new portable proof target.

Seed/output classification is mandatory for later consumers. `debug_hap::rebuild`
starts empty Job/capability/Session roots and copies original target adoption plus
`job-input-*` Artifact sources. Those copied bytes remain historical inputs.
The replay's new Job records, WAL, audit, capability receipts, manifest/proposal,
seal and index hashes are outputs. Other recovery fixtures contain retained Job
and authority seeds: they must be distinguished by their producer and copied
without Catalog translation. Equality of an operation descriptor never permits
an old c6 authority to authorize a new e4 plan.

Shared HDC/recovery integration remains with its assigned owner. The integration
API is `Lineage::current_digest(complete_current_plan, frozen_old_sha)` and
`Lineage::historical_answer(actual_plan_answer, frozen_answer, complete_plan)`.
It is not a recursive field replacement or a learned-digest table. Complete
authority/manifest/hash-chain projections need their own exact derivation and
old serialized hash proofs before the existing whole-store comparisons can be
used; this packet does not erase or migrate those fields.

Prepared portable negatives cover unknown Catalog/operation, Native scope,
descriptor mutation/duplicates, full plan arguments/executable/timeout/target/
inputs/steps drift, missing/extra plan fields, unsupported fractional values,
actual output hash mismatch and unrelated frame drift. They have not been run
in this source-only preparation window. Root/Signing own the serialized test
window and final integration. No CI or hardware PASS is claimed.

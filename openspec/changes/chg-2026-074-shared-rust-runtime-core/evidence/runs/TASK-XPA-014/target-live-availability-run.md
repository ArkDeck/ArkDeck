# Target aggregate uses live host availability — 2026-09-19

Base: protected main `1ee1d73ddeffcae6cda7ca49bf57ff22bf89d3d7` (#1974),
including live operation discovery #1973 and Rust benchmark launcher #1972.
TASK-XPA-014 and M1 remain in progress.

The bounded `target.availability` aggregate now obtains its operation entries
from the same per-request `Control::operation_availability()` projection as
`operation.list` and `operation.describe`. Previously it still read the startup
fallback and reported provider_not_registered even when the host's live list
reported an executable operation. Its existing four-field items contract,
host scope and unresolved target resolution remain unchanged; no admission,
capability, target/profile resolution or device observation is introduced.

The actual daemon composition test seeds a durable Target through the production
TargetObservations/TargetStore adoption path over an in-memory simulated source.
With the existing three executor dependencies configured, aggregate items equal
the live operation list. Analyzer drift, restoration and HDC drift are then
observed through the same Control instance; the aggregate continues to match.
Inert executable sentinels (retained even in the drifted bytes) prove no process
was dispatched by these availability reads. This is synthetic host testing,
not real-device evidence, installed Runtime activation, or GJ acceptance.

Validation: `cargo test --manifest-path rust/Cargo.toml -p arkdeck-control
-p arkdeck-agentd`: 32 tests passed. Both packages' all-target Clippy with
`-D warnings`, formatting and diff whitespace checks passed.
Final unified validation passed, exit 0 (2026-09-19), including common checks,
Rust workspace tests, Clippy, published/candidate contracts, deny and vet.
Swift/App lanes were not selected. Log: `/private/tmp/arkdeck-target-live-gate.log`.

```sh
ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python \
  /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

The dashboard is repinned to current main and independently recounted: 69/105
explicit routes, 68 canonical parser names, 65/256 matching registered CLI
features. Other coverage counts remain unchanged. #1975 and #1976 remain pending
at this baseline; the goal explicitly includes macOS GJ-1–5 physical acceptance.

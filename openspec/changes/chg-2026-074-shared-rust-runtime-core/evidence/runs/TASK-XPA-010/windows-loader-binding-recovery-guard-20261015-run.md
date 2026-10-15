# Preserve unknown Flash obligations during Loader binding

The first Windows full-restore on published Runtime
`fea0d78222b88b8bbc5efe385f76759637c786a2` retained an unknown delegated
`flash-partitions` intent after its normal-to-Loader transition. Inspection found
that `flash.bind-current-loader` refused only a parked `enter-loader-mode` intent.
The existing `loader_binding_jobs` test explicitly permitted the delegated unknown
to advance its Target binding. Recovery and capability lineage scans use the exact
materialized identity/revision, so advancing this binding could omit the original
uncertain effects from a later admission. This path was not exercised on hardware.

The binding owner now holds the Job admission interlock from its final census
through binding publication/readback. It refuses unsettled Flash work for the
selected Target across all revisions and reads terminal rows as well as active
ones. Running Jobs, unknown outcomes and retained residues cannot be hidden by a
new revision. The original enter-Loader refusal stays intact. A durable superseding
epoch releases an old unknown only on that record's own materialized binding;
the original Job and outcome are unchanged. Other Targets and settled history do
not block the selected binding.

Regression tests preserve the binding, Target and Job bytes for delegated unknown,
running, terminal-unknown and revision-mismatch cases. They verify that admission
cannot race the binding census, resumes after the interlock is dropped, and that an
epoch for another identity or revision cannot release the old unknown. These are
isolated host fixtures and are not hardware evidence.

Compatibility note: this enforces POL-RECOVERY-001 and POL-AGENT-002 against a
binding-change escape from the existing recovery census. It adds no operation,
capability input, new trusted fact, recovery classification or automatic identity
association. No Catalog, schema, acceptance criterion or safety requirement is
relaxed. The installed unknown Job is preserved and has not been replayed or
reclassified. Full Windows GJ-4 acceptance remains blocked on a mechanically proved
Loader lineage and complete recovery path; user confirmation cannot replace them.

Local targeted checks: all commands below exited 0 on the Windows host. Cargo
commands used `rust/scripts/run-cargo.py exec` and this session's fixed cache,
with two build jobs. Full local unified CI was not run.

- Batched `rustfmt --check` covered all 356 workspace roots, avoiding Windows'
  command-line length limit for `cargo fmt --all --check`.
- `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings` passed.
- `cargo test --locked -p arkdeck-hoststore --lib`: 378 passed, four ignored.
- `cargo test --locked -p arkdeck-hoststore --test loader_binding_jobs`: six
  tests passed, including seven unsettled-state cases and three exact-binding
  supersession cases. The final expanded cases also passed a fresh targeted
  clippy/test run and workspace formatting check.
- `cargo test --locked -p arkdeck-agentd --bin arkdeck-agentd loader_binding`:
  three passed; `cargo test --locked -p arkdeck-agentd --test spawning
  bind_loader_binds_the_current_loader_over_the_control_socket`: one passed.
- `cargo test --locked -p arkdeck-soak`: five passed, one ignored.
- `sh scripts/check-sdd.sh`: zero errors/warnings, 121 acceptance IDs;
  `git diff --check`: passed.

Logs are local at
`D:/src/ArkDeck-wt/tools/arkdeck-loader-guard-checks-20261015/`,
`D:/src/ArkDeck-wt/tools/arkdeck-loader-guard-final-checks-20261015/`, and
`D:/src/ArkDeck-wt/tools/arkdeck-loader-guard-sdd-20261015.log`.

CI: this increment is the next layer after
[PR #2648](https://github.com/ArkDeck/ArkDeck/pull/2648). At submission, the
parent's SDD Guard run `38727952433` passed and Swift CI run `38727828575` was
in progress. This layer's PR and CI run will be assigned after push; neither
pending run is counted as a pass.

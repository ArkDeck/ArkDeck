# Known terminal input references without Session finalization

A complete known-terminal Job could block inspection and release of every
Import because the reference census also required its Session `finalized`
event. The census now treats that owner as unsettled and reads its original
typed inputs conservatively. An Import referenced by that owner still returns
`recordUnreadable`; an unrelated Import can be inspected or released. A
publication marker alone cannot clear the original input reference.

The complete census still checks every indexed owner and rejects orphan or
missing directories, row/disk disagreement, changed submission fingerprints,
foreign Job/Session Journal identity, torn history, state disagreement,
outstanding intents and unknown outcomes. This does not publish a Session,
create evidence or authority, repair a Job, or dispatch a Provider. Existing
Artifact retention and collection are unchanged.

The unsettled branch requires a known typed operation and complete input
validation (type, enum, bounds and closed fields) before strict lease parsing.
It does not use the existing best-effort historical string scanner. Its only
historical input compatibility is the exact c6 Catalog with a compiled c6 or
e4 Catalog: all 32 complete input schemas are equal in the whole-SHA-pinned
lineage packet. Unknown digests/operations refuse inspection and release; a
future compiled Catalog does not inherit the c6 exception. This read-only
compatibility grants no execution, facts, plan or capability authority.

Compatibility: the prior global-finalization assertions in
`terminal_publication_retry` described an implementation coupling, also
recorded in the earlier Import lifecycle run. They now assert the narrower
reference behavior. The original publication retry, single-finalized-event,
complete request/audit, duplicate/restart and pre-write patch assertions remain.
`REQ-WF-004` continues to refuse publication/recovery without complete source
facts; [Artifact lifecycle ADR 0007](../../../../../../docs/adr/0007-artifact-lifecycle.md)
continues to retain pinned or unsettled inputs.

## Local targeted checks

Checks run from the isolated `import-reference-census` worktree, initially
based on `87fcfeae77e5360933b17f54264dc46be8f7fca9`, with the existing fixed
`tool-select` Cargo owner/cache and jobs=2. Live opt-ins were cleared. The
fixtures use task-private stores, real local admission/cancellation and counted
workspace ports, with no external child, installed Runtime, HDC or device.
The strict input follow-up was synchronized without overwriting these three
files to the exact adjacent lower `e15c85cb595b6823a77fccf210d39394c3d6aeb8`.

- `run-cargo.py fmt -p arkdeck-hoststore`: exit 0; log
  `tools/logs/import-reference-census-20261007/fmt-hoststore-2.log`.
  The first sandbox invocation stopped before Cargo on Git ownership refusal;
  its original `fmt-hoststore-1.log` is retained. The approved original-owner
  invocation reused the same fixed cache.
- `run-cargo.py test -p arkdeck-hoststore --test terminal_publication_retry`:
  exit 0; 10 passed, 0 failed, 0 ignored; log `terminal-retry-1.log`.
  Includes real unfinalized cancelled-input retention, published-marker/missing
  finalized refusal, reopen/collection and eleven source-defect scenarios with
  complete retained file-byte comparisons.
  The final strict target passed 13/13, 0 failed, 0 ignored in
  `terminal-retry-3.log` (6.62 s test body): full 32-schema proof, original c6
  Native record SHA/input proof, hidden-object/malformed-lease/unknown operation,
  digest and field refusals, and isolated Native enum/type negatives. The latter
  start from the complete original valid Native inputs and change only
  `expectedABI`; their legal starting schema is independently checked first.
  The earlier 13-case `terminal-retry-2.log` remains; its enum/type test setup
  was strengthened before the final run, rather than counted as final proof.
- `run-cargo.py test -p arkdeck-hoststore --test import_upload`: exit 0;
  31 passed, 0 failed, 0 ignored; log `import-upload-1.log`. Original
  submission-fingerprint, unknown-outcome, release and retention cases remain.
  After the strict typed-input follow-up, the same complete target passed
  31/31, 0 failed, 0 ignored and 0 filtered in `import-upload-2.log`
  (1.80 s test body; 40.923 s command). Before and after that command the
  production whole SHA remained `e5abeefd76e370f5584525431416b52c6218d132a991cb8198c5294f6dda1c47`
  and the terminal-regression whole SHA remained
  `29f024262d65334eb2848225dfff5358b12512aa111a520bdc7c8040159dd162`.
  This repeat verifies the affected prior upload/retention behavior on the
  strict source; it is not counted as additional distinct cases.
- `run-cargo.py clippy -p arkdeck-hoststore --all-targets -- -D warnings`:
  exit 0 initially in `clippy-hoststore-1.log`; final synchronized strict source
  exit 0 in `clippy-hoststore-2.log` (39.807 s).
- `run-cargo.py fmt --all --check`: exit 1, Windows argument-length
  `os error 206`; original `fmt-all-check-1.log` retained. The same runner then
  ran `cargo fmt -p <package> --check` for all 13 workspace packages, each
  exit 0; `fmt-packages-check-1.log` records the complete package census.
  The final synchronized strict source repeats this exhaustive fallback in
  `fmt-packages-check-2.log`, all 13 exit 0 (22.286 s). Affected-file formatting
  exits 0 are retained in `fmt-hoststore-3.log` and `fmt-hoststore-4.log`.
- `sh scripts/check-sdd.sh`: exit 0 (2.982 s), through existing Git Bash and
  the repository's pinned SDD Python; log `sdd-3.log`. Earlier shell lookup
  and default-Python dependency refusals are retained in `sdd-1.log` and
  `sdd-2.log`; no dependencies were installed or guards bypassed.
  Final synchronized strict source: exit 0 (2.909 s), `sdd-4.log`.
- `git diff --check`: exit 0 initially in `diff-check-2.log`; final explicit
  per-command `safe.directory` read exits 0 in `diff-check-4.log`. The sandbox
  Git ownership refusal (`diff-check-3.log`, exit 129) is retained; no global
  Git configuration changed.

After the final strict upload target, the delivery-note closure passed SDD
(`sdd-6.log`, exit 0, 3.707 s) and diff whitespace checking
(`diff-check-6.log`, exit 0, 0.144 s). `strict-upload-proof-1.json` retains the
actual command receipt/log whole SHA/count, post-command UTC and byte equality
of both frozen Rust sources with the stable owner's Cargo mirror. All Cargo
children returned before the exclusive host window was explicitly released.

The executed targets cover 44 distinct passed cases, 0 failed and 0 ignored:
13 final terminal-census cases and 31 final Import upload cases on the same
strict census source. The earlier upload log is preserved. The full
hoststore crate, direct-dependent tests and macOS cases were not executed in
this bounded D0 window. They remain for the synchronized stack's checks; no
account-touching fixture or unrelated suite was substituted for those checks.

## CI

This adjacent increment is not pushed. Current-head CI has not run. These
software checks are not hardware evidence or a formal Golden Journey result.

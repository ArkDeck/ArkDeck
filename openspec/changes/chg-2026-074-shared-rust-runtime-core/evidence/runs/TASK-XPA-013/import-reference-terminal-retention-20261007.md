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

The CI consumer follow-up changes only two unrelated-Import expectations in
`debug_hap_run`: `retained_preconsume_hap_failure_republishes_without_provider_or_authority_writes`
and `fresh_evidence_before_consumption_publishes_only_the_known_terminal_hap`.
Before and after the original publication retry, each now compares the whole
successful inspection with its actual immutable committed Import projection,
`clear` references, both empty Job arrays and the string count `0`. The original
Job/WAL, authority, Provider-call, publication retry and own-input refusal
assertions remain. Reversing only these four assertion hunks reconstructs the
original published file byte for byte.

- `run-cargo.py fmt -p arkdeck-hoststore --check`: exit 0 (43.134 s);
  `tools/logs/native-session-observation-20261007/upper-hap-format-131.stdstreams`.
- `run-cargo.py test --locked --offline -p arkdeck-hoststore --test debug_hap_run -- --exact retained_preconsume_hap_failure_republishes_without_provider_or_authority_writes fresh_evidence_before_consumption_publishes_only_the_known_terminal_hap`:
  exit 0; 2 passed, 0 failed, 0 ignored, 12 filtered (2.42 s test body,
  44.537 s command). `upper-hap-targeted-131.stdstreams` and the complete
  `upper-hap-targeted-131.json` command/source receipt are in the same log
  directory. The stable source SHA is
  `b8fca69dd4aadd71acdd8008432dbe74a0e025ef466dd8f1089aabd5b1b45225`.
  These checks used the existing isolated signing-readiness cache, jobs=2,
  with live/HDC/DevEco opt-ins removed. No account, SDK or device fixture ran.
  The unaffected 44-case checks above were not repeated for this test-only
  consumer correction.
- Delivery-note `sh scripts/check-sdd.sh`: exit 0 (2.733 s), 121 acceptance
  IDs, 0 errors and 0 warnings; the original command and whole-log receipt
  are `upper-hap-note-sdd-132.json` and `upper-hap-note-sdd-132.log` in the
  same log directory.

## CI

[PR #2629](https://github.com/ArkDeck/ArkDeck/pull/2629) published head
`d489646021dff2be8f328dffd9377668cdafd5a0` on adjacent lower
`1ffd9709a5e086cf15a1a527a6c7d384ea2aff09`. Swift CI run `37615096070`
completed with required aggregate `swift` failure (job `112784004208`,
2026-10-07 12:08:53 UTC). Both SDD Guard runs `37615095875` and
`37615228315` succeeded. Plan, Swift tests, App build, Windows ClientKit,
Rust host-independent and both Ubuntu Rust lanes succeeded.

Windows workspace job `112771821148` and macOS workspace job
`112771821273` each passed 12 and failed the two exact HAP cases named
above: their obsolete pre-retry `unwrap_err()` received the complete clear
unrelated-Import result. Complete original logs are retained in
`tools/logs/import-ci-windows-37615096070-112771821148.log` and
`tools/logs/import-ci-macos-37615096070-112771821273.log`. These are
consumer failures, not host-load or timeout classifications.

macOS parity job `112771821216` also exposed the lower current Native oracle's
three task-private fake-host files at mode `644`, where whole snapshots require
`600`, across seven snapshots and the final store (24 differences per affected
function). Its whole log is `import-ci-macos-parity-37615096070-112771821216.log`.
Windows parity job `112771821328` completed all visible test bodies and stage
commands with exit 0, then the historical execution receipt rejected the sole
ignored `session_publication_cost::copying_a_journal_into_its_session_costs`
selection: `ignored-only selection cannot discharge coverage`. Its complete
log and original public artifact receipt are
`import-ci-windows-parity-37615096070-112771821328.log` and
`import-ci-windows-parity-37615096070-catalog-execution.json`. Both lower
consumer corrections are owned by the adjacent Native layer; this increment
does not waive their assertions or change its manifest.

The original failed run and logs remain. The local HAP consumer correction and
adjacent lower fixes still require CI on their next synchronized heads; no
new-head green conclusion is claimed here. These software checks are not
hardware evidence or a formal Golden Journey result, and CI is not maintainer
approval.

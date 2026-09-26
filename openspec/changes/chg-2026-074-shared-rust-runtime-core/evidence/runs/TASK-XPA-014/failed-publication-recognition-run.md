# A failed publication's Session is passed over only as its Job's durable record proves it (TASK-XPA-014, macOS, 2026-09-26)

TASK-XPA-014 / CHG-2026-074. A publication that stops short of its rename moves what it staged to
the Session's name (#2230), as Swift, which writes in place, leaves what it wrote. Such a Session
holds its identity and no Manifest. Rust's continuity proof refuses some of these, and a device
mutation is then refused until someone moves the Session:
- one with its identity and directories alone;
- one whose Journal copy has a torn tail or an unresolved device mutation.

The coordinator ruled on 2026-09-26:
- **Pass such a Session over only on durable proof**, all three at once:
  - its identity names a Job;
  - that Job's durable record says its Session publication failed, for the same Session;
  - the Session's shape is exactly what the failure path leaves.
- **Refuse anything else as before**, with a message that points to session cleanup.
- **Only add this way through (option A).** Nothing that passes today is newly refused: a Session
  without a Manifest whose Journal replays clean passes as before, as Swift's does. The coordinator
  first reasoned that a missing Manifest leaves the Journal's completeness unproved, which would
  refuse those too. It then corrected itself: the Job's own record and Journal stay in the Job
  store, which the proof checks. A copy that replays clean hides no unresolved mutation.
- **The wording.** The code stays `recordUnreadable`. The message names the Session by its place
  under the Sessions root, bounded, and says to move it out once reviewed, never to remove it: an
  incomplete Session may be evidence.
- **The public entries.** The proof over one Sessions root, and the predicate, are public, so the
  cutover preflight (S36) runs the same scan the admission runs.

Base: protected `main` `a66520ca6` (#2240). Disposable host data only; nothing here is device
evidence. This slice also records the CI of #2234 and #2240.

## Swift

`RuntimeStateContinuity.requireMutationState` (`ArkDeckStorage/RuntimeStateContinuity.swift`,
63–96) reads each Session root with `contentsOfDirectory` (line 70): its direct children only.
For each child directory:
- a `manifest.json`, if there is one, must decode (line 81);
- a `journal.jsonl`, if there is one, must have no torn tail and no unresolved or unknown device
  mutation (line 86 on).

It never refuses a Session for having no Manifest. It also never descends: in the
`yyyy/mm/session-*` layout the root's children are year directories, which hold neither file.
So in the current layout Swift's proof reads no Session at all. Rust's scan descends to each
Session. That makes it stricter, failing closed where it cannot prove the state, and this slice
keeps it so. It is a declared difference, and Swift's shallow walk is not copied.

## What a failed publication leaves

From `SessionPublisher::attempt` (`session_publication.rs`), in its order, where a failure moves
the staged Session to its name:

| Stopped | The Session holds |
| --- | --- |
| before or while writing its identity | its directories: then no identity, so this slice does not apply |
| after its identity, before its Journal | `.session-identity.json`; `audit/`, `artifacts/{raw,derived,partial}/`, all empty |
| while copying its Journal | and `journal.jsonl`, the Job's Journal as far as it went, maybe torn; `.manifest.lock`, empty |
| after its Journal | and the whole Journal |
| at its Manifest | and `audit/session.jsonl`, the outcome audit; `artifacts/partial/.publication-lock-<hex>.lock`, empty |

A Session left at its Manifest has its whole Journal, which replays clean. It passes as it always
did. The Swift device reconcile oracle leaves one: its observation Job's publication failed there
(`storageUnavailable`, "journal binding revision does not exist in Manifest").

## Change

- **The scan** (`inspect_named_children`, `mutation_state_continuity.rs`) settles a Session as
  before, into a verdict. When the verdict is a refusal and the Session holds its identity and no
  Manifest:
  - it passes the Session over when a failed publication accounts for it. It never keeps that
    verdict: the proof also reads the Job's record;
  - otherwise it refuses with `recordUnreadable`: "Runtime mutation state continuity cannot be
    proved: retained Session <yyyy/mm/name> has no Manifest and no failed publication of this
    Runtime accounts for it; runtime storage status and session cleanup name it; move it out of
    the Session root once reviewed; original state is preserved". The place is bounded to 200
    characters.
- **The proof** (`JobStore::failed_publication`), all of it:
  - The identity, canonical, names Job J, and the Session's name is `session-J`.
  - J's durable record, the index row, never a resident record, keeps a publication whose fact is
    `failed`, for `session-J`.
  - The Session is at `yyyy/mm` of J's creation, where the publication would have written it.
  - The Session holds only `.session-identity.json`, `audit`, `artifacts`, `journal.jsonl` and
    `.manifest.lock`, of the kinds the publication writes. `artifacts` holds exactly `raw`,
    `derived` and `partial`. `raw` and `derived` are empty, and `partial` holds only empty
    `.publication-lock-<hex>.lock` files. `.manifest.lock` is empty.
  - The Journal, if any, is a byte prefix of J's own Journal.
  - `audit/session.jsonl`, if any, comes only with the whole Journal. It is one line, J's outcome
    audit as the publication writes it: the digest of J's Manifest proposal, J's operation and
    terminal state, any timestamp.
- **Public, for the cutover preflight:**
  - `JobStore::require_retained_sessions(sessions_root)` runs the same scan over one Sessions root
    alone, read-only and reusing nothing, and answers its first refusal. It takes the Job store's
    `activity` guard, as the proof does.
  - `JobStore::failed_publication_accounts_for(sessions_root, [yyyy, mm, name])` is the predicate.
    It takes no lock.
- `session_publication::utc_month` is crate-visible, so the proof places the Session as the
  publication does.

## Tests

`tests/failed_publication_recognition.rs` replays the device reconcile oracle through its
reconciles, over the shared fake HDC. Rust's publication then leaves the observation Job's failed
Session. Every answer is compared both ways: `require_retained_sessions` and
`require_mutation_state` must agree.
- **What the failure left** is accounted for and passes, as it always did. This is the one
  Session Rust's failure path wrote itself, outcome audit included, so it also checks the audit
  as the proof rebuilds it.
- **A Journal copy stopped mid-record** (a torn tail, the audit and locks gone) is refused by the
  scan, accounted for, and passes.
- **The identity and directories alone** are also accounted for, and pass.
- **Refused, naming the Session** (starting from the identity and directories alone):
  - a file the publication never writes;
  - an Artifact in a directory it leaves empty;
  - a Journal that is not the Job's;
  - an outcome audit before the whole Journal;
  - an identity that is not canonical;
  - an identity naming another Job;
  - a lock that is not empty;
  - the published Job's Session cut back to its identity and directories, its Manifest moved
    aside. Only its record, which keeps a receipt, tells it apart.

**Negative controls, each failing the test:**
- the proof never holding: the first accounted Session was refused;
- the proof always holding: the first unaccounted case passed;
- the record's failed state left unchecked: the published Job's Session was accounted for.

The last one first passed. The published Session was cut back only partly, so the shape check
alone refused it. The case now leaves nothing but what the record tells apart.

## Cutover

An installed Swift Runtime writes Sessions in place. A crash there leaves a Session with its
identity and no Manifest, and no Rust record accounts for it. After cutover, Rust refuses device
mutations until it is moved: when it holds its identity alone, or a Journal copy with a torn tail
or an unresolved device mutation. The coordinator's S36 will run `require_retained_sessions` in
the cutover preflight, so such a Session is named before cutover rather than at the first
mutation.

## Contract

No contract input changes. The new refusal is a message of `recordUnreadable`, which the proof
already answered, and no ControlFrames frame holds either.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`, on `a66520ca6`.

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`f-fmt.log`).
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`f-clippy2.log`). The first run
  (`f-clippy.log`) flagged the test's table type as too complex, and a type alias fixed it.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --no-fail-fast`: exit 0 (`f-test.log`): 114 suites, 838 passed, 0 failed, 18
  ignored (the ignores already existed). The recognition test again after the alias: passed
  (`f-test2.log`).
- The three negative controls above.
- `sh scripts/check-sdd.sh` (validation venv): exit 0.
- Not run:
  - `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
  - The App and a device.

## CI

#2242, head `87246bc5a`, run 36203549851: every selected lane passed.
- Rust workspace: macOS 13m17s, Ubuntu 1m54s, Windows 4m41s. Host-independent checks: 41s.
- `guard`; `swift` aggregate. `swift-tests` was not selected.

It merged as `9428277e3`. Recorded by the next slice (TASK-XPA-014, the cleanup's storage lock),
as AGENTS.md has it.

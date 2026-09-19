# TASK-XPA-014 — the isolated daemon's development USB relations and the adoption oracle against the real daemon (macOS, 2026-09-15)

TASK-XPA-014 remains in progress. Base: protected main `81957589` (rehung 2026-09-19 from its
original base `1ce890dc` with `git rebase --onto origin/main 1ce890dc`); no stack. Main carries the
daemon's device observation and adoption routes (#1966), and this slice composes the USB relation
source those routes read. It supplies only the development source: the trusted production USB
relation source listed among the M1 remainders stays with the ArkForge lane. Every request and answer here is
synthetic host data over `/bin/sh` scripts; nothing is device evidence (POL-VERIFY-001,
POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The Target adoption oracle and its control shapes (#1957) and the hoststore Target observation owner (#1959); the daemon's observation and adoption routes (#1966); `target.availability` and its in-process oracle replay (#1974, #1978); HAR raise/resume (#1970, #1981) | The isolated owner's development USB relations (`ARKDECK_DEVELOPMENT_USB_RELATIONS`, `agentd/src/development_usb.rs`); `check-corpus-replay.py` replays the adoption oracle against the real daemon | Candidate display names through the owner, once Swift's coordinator is recorded for them; the three availability exchanges in the real-daemon replay; the production (trusted) USB reader — the ArkForge lane; runbook §2 on the isolated daemon and GJ-1 |

## What changes

- **The development source** (`agentd/src/development_usb.rs`, macOS):
  - Only `ARKDECK_DEVELOPMENT_USB_RELATIONS` names it, and it must be an explicit absolute path.
    It is allowed only beside the development HDC. That HDC is itself allowed only with an
    isolated development root, so the production daemon never reads the source. Startup refuses
    it in two cases:
    - a relative path: "ARKDECK_DEVELOPMENT_USB_RELATIONS must be an explicit absolute path";
    - no development HDC: "development USB relations are configured only with a development
      HDC".
  - The file is read on every call as `{"relations": [...]}`. Each relation is parsed as the
    provider parses one (`UsbRelation::from_value`).
  - With `"after": {"reads": n, "relations": [...]}`, the file reads the second list once it has
    been read n times since its bytes last changed. This is how the oracle's drift case times the
    replug.
  - A missing file reads no relations. An unreadable, non-JSON or malformed file is the source's
    failure. The owner answers it as it answers any relation source's failure: the observation
    fails and keeps no snapshot.
- **The daemon** (`main.rs`) composes the source after the development HDC.
  `Host::with_usb_relations` is now compiled outside tests on macOS.
- **The harness** (`rust/scripts/check-corpus-replay.py`):
  - It serves `device.observations` and `target.adopt`.
  - It seeds the Target document only for an oracle with Jobs. An adoption oracle starts with no
    Target and adopts it itself.
  - It writes each exchange's `usbRelations`, with its `usbRelationsAfter`, to the file the daemon
    reads.
  - Identities the owner mints at random read as the oracle's labels, by kind, in order of first
    appearance. A label in a request is sent as the identity it stands for.
  - After the replay it compares `targets.json` and `target-display-names.json` with Swift's,
    with their times read alike.
  - The CLI's Job reads run only for an oracle with Jobs.
  - Two more startups are refused (above).
- **README**: the Target section, in place.

## Tests

- **The source**:
  `development_usb::tests::relations_change_after_the_reads_the_file_names_and_restart_with_it`.
  It covers a missing file, the replug after two reads, a rewrite that restarts the count, and a
  file that is not JSON.
- **The adoption oracle against the real daemon**:
  `check-corpus-replay.py --fixture rust/tests/fixtures/target-adoption`.
  - It starts `arkdeck-agentd` over a fresh isolated root with the fake HDC and the development
    source, then replays the 18 observations and adoptions over the socket.
  - The 3 availability exchanges are not replayed, because the daemon does not serve
    `target.availability` yet.
  - Its 25 checks are every answer at T1, the fake's 19 calls in order, `targets.json`,
    `target-display-names.json`, and four refused startups.

The first full run failed on the two agent oracles. The harness's new label map had the same name
as the cursor match those oracles' listings use, and the match rebound it. After the map was
renamed, all five oracles passed.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The daemon's tests | `cargo test -p arkdeck-agentd` | 12 passed, none failed. Includes the source's test and the routes slice's control replay |
| The adoption oracle, real processes | `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/target-adoption` | PASS: 18 exchanges replayed, 3 not replayed (availability), 25 checks. The received calls hash to `5aacdce3…`, the recorded log's hash in `provenance.json` |
| The other oracles, real processes | the same for `agent-execution`, `agent-lifecycle`, `observe-device` and `capture-diagnostics` | PASS on all four (29, 25, 28 and 28 exchanges; 59, 60, 59 and 59 checks). The exchanges are the same as before; each has two more checks, the two new refused startups |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS: 124 control responses, 12 CLI envelopes, 115 valid requests |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all -- --check`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

These checks first ran on 2026-09-15 with #1962's fix (`e0ca2ddc`) picked locally beneath this
slice, because main `5e966172` did not compile (E0252) until #1962 landed. The pick was never part
of this slice; main has carried #1962 since.

### Rehang onto `81957589` (2026-09-19)

The rebase conflicted only in `agentd/src/main.rs`: main had added the human-action owner
(`with_human_actions`, `human-action-snapshots`) to the isolated composition this slice turns into a
`let host = …; match development_usb … {}` block. The resolution keeps both; nothing else changed.
Rerun in a fresh `rust/target` on `44aa0325`, 13:42:08–13:43:13 CST, all exit 0:

| Check | Result |
| --- | --- |
| `cargo build --workspace --bins --locked` | built |
| `cargo test --locked -p arkdeck-agentd` | 21 + 1 + 1 passed, none failed |
| `check-corpus-replay.py --fixture rust/tests/fixtures/target-adoption` | PASS: 18 replayed, 3 not replayed (availability, above), 25 checks |
| the same for `agent-execution`, `agent-lifecycle`, `observe-device`, `capture-diagnostics` | PASS: 29/25/28/28 exchanges, 59/60/59/59 checks, none left out |

Log: `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/usb-targeted-44aa0325.log`,
SHA-256 `a93cfc788675fd0ef06c16798faf800935930bbd0c929277c197e5e33077c93f`.

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| 2026-09-19 13:44:40–13:49:16 CST, merge base `81957589` | `e779eeef` (rehung slice; the evidence-only amend that records this row follows) | **exit 0**. Lanes: rust only. Every cargo test summary sums to 881 passed, 0 failed, 15 ignored; published and candidate contract checks, `check-sdd` (0 errors), `cargo deny` and `cargo vet` pass | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/usb-gate-e779eeef.log`, SHA-256 `d2082a224bdc9cd16dc45bbe0dad9f9c1980db3a5e073a78fb1071662fcf41f1` |

`cargo clippy --workspace --all-targets --locked --target <t> -- -D warnings` for
`x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` on the same head: both exit 0.

## Not run, and why

- **Availability in the real-daemon replay.** Main's daemon now serves `target.availability`
  (#1974), and `target_observation_control`'s in-process Control replay covers the oracle's three
  availability exchanges, rewriting the recorded `tool` (Swift's oracle had a managed HDC; the
  development composition names only an external executable) and checking `operations` against
  the daemon's own `operation.list`. This harness's `SERVED` set still leaves them out; carrying
  the same two normalizations into it is a follow-up, not part of this rehang.
- **Candidate display names through the owner**, until Swift's coordinator is recorded for them.
- **The production reader.** Without the development source, the daemon still composes
  `NoUsbRelations`. The ArkForge lane's reader is not part of this slice.
- **Adoption across a restart.** The snapshot, the generations and the receipts live in memory, as
  in Swift. The harness's restart reads no Job here. Restart semantics stay out until L.1 item 13
  is decided.
- No device, no real HDC.

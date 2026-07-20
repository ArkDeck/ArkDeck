# TASK-UD-REDACTOR-001 implementation run — 2026-07-20

> This record describes the initial candidate. The four review findings and the
> current source/hash chain are closed in
> `review-remediation-2026-07-20.md`; its hashes supersede this file's candidate
> hashes for implementation review.
> Every stale source-hash row, three-safe-literal assertion, and 18-test total
> below is also marked `SUPERSEDED` at the fact itself.

## Classification and scope

- Evidence class:`contract` / host-only / synthetic-only.
- Change:`CHG-2026-008-ui-dump-hidumper-wrapper@r5`.
- Source base:`48cbcaffa889c22e6f91cd0be5dcf69b9a1d026d` (`main`, r5 readiness
  merged by PR #136).
- Acceptance:`INT-UD-REDACTOR-001` / `TEST-INT-UD-REDACTOR-001`.
- Canonical boundary:`REQ-DUMP-008` is a read-only Safety input. This run does
  **not** execute diagnostic export and does not claim `AC-DUMP-008-01` PASS.
- Real UI raw, installed HDC, device, network, GUI, external process from the
  redactor, device mutation, destructive dispatch, and hardware evidence count:
  `0` each. Test subprocesses only re-executed the local Python redactor CLI
  against generated synthetic temporary files.

The implementation changed only the six approved files under
`scripts/ui_dump_redaction/` and this allowed evidence record. No Swift,
`Package.swift`, Core/spec/contract, platform, capture, golden, or task-status
file was changed. Per the approved task PR boundary, `ready→done` is not mixed
into this implementation/evidence diff; maintainer review of a later independent
status PR remains required.

## Environment

The detached worktree does not contain its own `.venv-sdd`. The fixed interpreter
from the main repository checkout was used directly; no fallback or install was
performed:

| Item | Observed value |
| --- | --- |
| Python path | `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python` |
| Python | `3.14.6` (`Clang 21.0.0`) |
| PyYAML preflight | `6.0.3` |
| Interpreter SHA-256 | `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf` |
| Host/test mode | macOS headless shell; local temporary directories only |

The redactor itself imports Python stdlib only. PyYAML was used only by the
repository SDD guard.

## SUPERSEDED — Reviewed-source candidate hashes

**SUPERSEDED:** These hashes described the initial candidate only.

| File | SHA-256 | Status |
| --- | --- | --- |
| `scripts/ui_dump_redaction/README.md` | `7dbd5857bc7cd5be25ddeb9d6339cc840e501963d99088e796220aedb543d790` | `SUPERSEDED` |
| `scripts/ui_dump_redaction/redact.py` | `c9b70916cdd1153bcf18dbf15dc4a1b932c0cd47dbc553c10450296a4dbd8e92` | `SUPERSEDED` |
| `scripts/ui_dump_redaction/test_redact.py` | `87acd45294f8fb7cbdf0464ffade7b6893a03496cc0427bd7dc9ed95390f4137` | `SUPERSEDED` |
| `scripts/ui_dump_redaction/algorithm-v1.json` | `727eb15a79082de8400f22cb6d68e76286870c87a4f9195e6e48cf6faf5d2e26` | `SUPERSEDED` |
| `scripts/ui_dump_redaction/safe-literals-v1.txt` | `3296a1c8a3690ff05d7bf80295c001c80f13b7698d7049211a7d131c3cd16f2a` | `SUPERSEDED` |
| `scripts/ui_dump_redaction/redaction-receipt.schema.json` | `f4bffe70a51dc3f6228f24d41b814dc47cc2d6f0cde5f00445070f86cd1ec4b6` | `SUPERSEDED` |

**SUPERSEDED:** `algorithm-v1.json` pinned the two initial policy-file hashes.

**SUPERSEDED:** The initial candidate safe-literal set contained exactly three
sorted, exact-match values: `false`, `null`, and `true`.

**SUPERSEDED:** The initial run deferred review of those three literals; the
remediated candidate retains none of them.

## Commands and results

### Offline adversarial/property contract

```text
/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  -m unittest -v scripts/ui_dump_redaction/test_redact.py
```

**SUPERSEDED:** Result:`PASS` — 18 tests, 0 failures, 0 skips, 0.470 seconds in
the initial run.

The binary negative matrix covered:

- invalid UTF-8; NUL/tab/other controls; bidi format character; Cyrillic
  confusable; non-NFC and unassigned Unicode;
- CRLF, CR, and LF normalization; JSON escaping; duplicate placeholder reuse;
  exact ordering; repeated-run derived byte determinism;
- package, ability, page, window, component, user path, serial, long number,
  quoted and non-ASCII page-text replacement;
- reserved-placeholder impersonation, dangling quote, empty-only input,
  over-tokenized line, overlong token, and input above 8 MiB;
- manifest, allowlist, receipt-schema, and expected-input-hash drift;
- input/output/receipt path collisions, stdin token rejection, existing output,
  symlink/FIFO input rejection without blocking, receipt-write rollback, raw
  byte immutability, and `0600` exclusive outputs;
- receipt closed-schema/hash-chain tampering, independent sensitive-output
  survivor rejection, 250 seeded property lines, and static stdlib-only /
  no-process/no-network/no-shell-dispatch inspection.

All failing CLI vectors returned their manifest-fixed nonzero code, retained the
raw bytes, and produced no derived/receipt pair. No synthetic outcome was
classified as capture, privacy attestation, platform evidence, or hardware.

### Synthetic transform and receipt chain

*(superseded at the hash facts below — this section records the initial-run
chain; its receipt-embedded source/input hashes predate the hardening commit
and no longer match `main` bytes. The authoritative current chain, with source
`938cc117…` and the full six-file table, is recorded in
`review-remediation-2026-07-20.md`.)*

The approved algorithm manifest bytes were copied to a temporary synthetic
input (not real UI raw), then transformed twice with the exact task CLI:

```text
/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  scripts/ui_dump_redaction/redact.py \
  --algorithm-manifest scripts/ui_dump_redaction/algorithm-v1.json \
  --safe-literals scripts/ui_dump_redaction/safe-literals-v1.txt \
  --input /private/tmp/arkdeck-ud-redactor-evidence.J49bF4/synthetic.raw \
  --expected-input-sha256 727eb15a79082de8400f22cb6d68e76286870c87a4f9195e6e48cf6faf5d2e26 \
  --output /private/tmp/arkdeck-ud-redactor-evidence.J49bF4/derived-final.txt \
  --receipt /private/tmp/arkdeck-ud-redactor-evidence.J49bF4/receipt-final.json
```

First and replay commands both exited `0`. The second used distinct
`derived-final-replay.txt` / `receipt-final-replay.json` paths and the same other
arguments.

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| synthetic input | 2651 | `727eb15a79082de8400f22cb6d68e76286870c87a4f9195e6e48cf6faf5d2e26` |
| derived output | 2626 | `ef9054f047cd87ae380359e55200d6dd885990af44e6bb0d9b924f3b527cac89` |
| replayed derived output | 2626 | `ef9054f047cd87ae380359e55200d6dd885990af44e6bb0d9b924f3b527cac89` |
| first receipt | — | `3dd4e23df0d52209c3be1a86bb4eb113d6286178f690b8f11600070b12daf7bb` |
| replay receipt | — | `9e7899b9218b246911d25bd76159946acda065884cd0ff74ccb52f36cde7b228` |

Receipt facts:algorithm source hash
`c9b70916cdd1153bcf18dbf15dc4a1b932c0cd47dbc553c10450296a4dbd8e92`,
manifest/allowlist/schema hashes equal the table above; 79 lines / 319 tokens;
145 replacements / 132 unique; output-side check passed over 132 sensitive
literals. Receipt hashes differ because `completedAt` records the actual UTC
completion second; the derived hashes are byte-identical as required.

An ASCII scan of the derived output for synthetic package/window/component,
user-directory, key-material, and operator-name patterns returned zero matches
(`rg` exit `1`, the expected no-match result).

### Repository checks

```text
/usr/bin/env \
  ARKDECK_PYTHON=/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  sh scripts/check-sdd.sh
```

Result:`PASS` — 0 errors, 0 warnings, 111 acceptance IDs.

```text
swift test --package-path Packages/ArkDeckKit
```

Result:`PASS` — 249 tests executed, 1 skipped, 0 failures. Existing Swift
`await` warnings were emitted in unchanged test code; no redactor Swift/product
code exists.

```text
git diff --check
```

Result:`PASS`.

## Acceptance conclusion

`TEST-INT-UD-REDACTOR-001`:**PASS (`contract`, synthetic-only)** for this
implementation worktree. The fixed transform verifies the raw whole-stream hash,
opens raw read-only, refuses overwrite/path collisions, applies a closed
UTF-8/NFC/line/token grammar and typed deterministic placeholders, fails closed
for unsafe/unknown input, independently scans the output before write, validates
the receipt and records its complete hash chain, and has reproducible negative
and determinism evidence.

## Deviations and residual risks

- Environment deviation:the Codex worktree has no `.venv-sdd`; the fixed main
  checkout interpreter was used by absolute path with the expected version,
  PyYAML version, and measured hash. No dependency was downloaded.
- This synthetic contract does not show that an eventual DAYU200 raw output is
  accepted by the deliberately strict grammar. Unsupported Unicode/confusable or
  unclassified input fails closed and may require a separately reviewed v2
  algorithm rather than an ad-hoc fallback.
- The three safe literals and all implementation bytes still require maintainer
  review/merge. This evidence and the Agent do not approve them, mark the task
  done, attest future derived golden privacy, or make CHG-008 verified.
- Actual derived golden creation remains forbidden until this task is separately
  moved to `done`; TASK-UD-001 and all capture/output-family decisions remain
  governed by their existing blockers.

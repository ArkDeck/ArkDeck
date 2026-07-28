# UI Dump raw root-cause diagnosis (read-only, non-content)

`arkdeck-ud-raw-diagnosis` is the host-only, offline diagnosis face fixed by
`TASK-UD-R2-DIAG-001` readiness r1 (CHG-2026-008). It measures **why** the
fixed `uidump-derived-redaction-v1` transform rejected the pinned R2 sidecar
raw origin (`866256` bytes, SHA-256
`ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077`) with
`INVALID_UNICODE` / exit `27`, so a later revision can choose between the two
mutually exclusive follow-up branches (raw-data root cause vs capture-pipeline
root cause). The tool itself draws no root-cause conclusion and authorizes no
branch: it emits measured, non-content evidence; the binary conclusion is made
offline by the human maintainer and recorded in evidence per the readiness
execution model.

## Red lines

- The agent never opens, copies, or receives the controlled raw. The
  controlled raw path never enters the conversation, the repository, or
  evidence; records use the `<CONTROLLED_RAW_PATH>` placeholder.
- The tool reads the input once, read-only (`O_RDONLY|O_NOFOLLOW`,
  regular-file only, outside-repository only), never writes any file, and
  never echoes input bytes. No raw byte subsequence, decoded text, content
  window, page text, or window/component literal can appear on stdout,
  stderr, or in evidence — including any "context around the offending
  byte" style output, which is forbidden by design and rejected by the
  output-side final check.
- Python stdlib only; zero shell/subprocess/socket/network/exec/eval; the
  AST audit in `test_diagnose.py` enforces this and the zero-write rule.
- Tests are synthetic-only. No test reads any real raw.

## Fixed files

- `diagnose.py`: input gates, dual census, closed-schema report builder,
  fail-closed output validator, CLI.
- `test_diagnose.py`: the readiness r1 synthetic matrix — 32 pinned case
  families plus 2 mandatory audits (additions allowed, removals not).
- `README.md`: this contract summary.

## Maintainer execution sequence (the only authorized real-raw run)

The human maintainer personally executes the pinned CLI outside every
repository checkout. The only non-pinned argument is the controlled raw path:

```text
<ARKDECK_ROOT>/.venv-sdd/bin/python scripts/ui_dump_diagnosis/diagnose.py \
  --input <CONTROLLED_RAW_PATH> \
  --expected-input-sha256 ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077 \
  --expected-length 866256
```

1. Preflight in the checkout: `scripts/check-sdd.sh` green, and
   `.venv-sdd/bin/python scripts/ui_dump_diagnosis/test_diagnose.py` all
   PASS (records interpreter path/version/hash and both tool file hashes).
2. Run the exact CLI above. Exit `0` prints exactly one canonical JSON line
   on stdout; paste that line verbatim into the run record. Any input-gate
   failure prints a single stderr line `diagnose: <ERROR_NAME>` and nothing
   on stdout.
3. Evidence lands in
   `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-R2-DIAG-001/`
   as `run.md` in the readiness-pinned form: ids and evidence class
   (humanOfflineDiagnosis), readiness merge OID, interpreter facts, tool and
   test hashes plus source OID, synthetic matrix result, the exact CLI with
   the raw path placeholder, the verbatim stdout report, the maintainer's
   offline reading in prose, the binary root-cause conclusion (`raw-data` or
   `pipeline`) or an honest "cannot determine", dispatch/read counters, and
   `check-sdd` / `git diff --check` results.
4. `done` requires maintainer review/merge of that evidence plus a separate
   `ready→done` status PR; an inconclusive reading forces `ready→blocked`.

## CLI contract

- `--input`: path to the raw file. Must resolve outside this repository and
  must not be a symlink or non-regular file (`IO_ERROR`, exit 32).
- `--expected-input-sha256`: 64 lowercase hex. Malformed values and any
  measured-hash mismatch are `INPUT_HASH_MISMATCH` (exit 24).
- `--expected-length`: positive decimal integer; anything else is an
  argparse usage error (exit 2). A measured-length mismatch is
  `INPUT_HASH_MISMATCH` (exit 24).
- Hard input cap `16777216` bytes (`INPUT_TOO_LARGE`, exit 25) measured
  before reading.
- Exit `0` means the diagnosis completed — including over a violating raw;
  the findings are inside the report, not in the exit code.
- Error codes reuse the redactor numeric namespace:
  `INPUT_HASH_MISMATCH=24`, `INPUT_TOO_LARGE=25`, `SENSITIVE_OUTPUT=31`
  (output-side final check), `IO_ERROR=32` (symlink/non-regular/in-repo
  path/read failures).

## Output schema (`arkdeck-ud-raw-diagnosis-1.0.0`, closed)

One canonical JSON line (`sort_keys=True`, `ensure_ascii=True`, separators
`(",", ":")`); identical input produces identical bytes. Closed keys, no
additions:

- `schema`: the schema id.
- `tool{name,sha256}`: tool id and the runtime SHA-256 of `diagnose.py`.
- `policyRefs{redactPySha256,algorithmManifestSha256}`: embedded constants
  pinning the fixed redactor (`938cc117…f53e1` / `a75778fd…20185`); tests
  assert they equal the measured repository hashes.
- `input{expectedSha256,measuredSha256,expectedLength,measuredLength}`:
  equal by construction — the report exists only after the gates pass.
- `byteHistogram{nul,tab,lf,cr,otherC0,asciiPrintable,del,lead2,lead3,
  lead4,continuation,invalidByte}`: byte-value classes; counts sum to
  `measuredLength`.
- `utf8Structure{decodable,invalidSequenceCount,invalidByteCount,
  firstInvalidOffset,lastInvalidOffset,classCounts,runs,runsTruncated,
  decileCounts,tailConcentrated}`: RFC 3629 well-formedness census. The
  scanner accepts exactly what a strict Python UTF-8 decode accepts, so
  `decodable` mirrors the redactor's decode step. Malformed-sequence
  classes: `STRAY_CONTINUATION`, `INVALID_LEAD` (`0xF8`–`0xFF`),
  `OVERLONG` (`0xC0/0xC1` leads, `0xE0 80–9F`, `0xF0 80–8F`),
  `SURROGATE_ENCODING` (`0xED A0–BF`), `OUT_OF_RANGE` (`0xF4 90–BF`,
  `0xF5`–`0xF7`), `TRUNCATED_SEQUENCE_MID`, `TRUNCATED_SEQUENCE_EOF`. A
  malformed sequence consumes its maximal subpart; one sequence is one run
  `{offset,length,class}` in byte units.
- `codepointPolicy{evaluated,nfc,combiningMarkCount,violationCount,
  firstViolationByteOffset,lastViolationByteOffset,classCounts,runs,
  runsTruncated,decileCounts,tailConcentrated}`: evaluated only when
  `decodable`; otherwise `nfc` is null and every other field is
  zero/null/empty. Mirrors the redactor's
  `_validate_unicode(text, allow_line_endings=True)`: LF/CR exempt, then
  first hit in redactor condition order — `DEL_7F`, `CONTROL_C0`
  (remaining `<0x20`), `CATEGORY_CC`, `CATEGORY_CF`, `CATEGORY_CS`,
  `CATEGORY_CO`, `CATEGORY_CN`, `CONFUSABLE_NAME_PREFIX` (`ARMENIAN`,
  `CHEROKEE`, `CYRILLIC`, `FULLWIDTH`, `GREEK`, `MATHEMATICAL`, `SMALL`
  name prefixes). One violating codepoint is one run; `offset` is the byte
  offset of its UTF-8 encoding, `length` its encoded byte length.
  `combiningMarkCount` counts codepoints with a nonzero canonical
  combining class; `nfc` is whether the decoded text equals its NFC
  normalization (a non-NFC stream is a redactor rejection even with zero
  per-codepoint violations).
- Shared face semantics: `classCounts` always carries every class key;
  `decileCounts` buckets each run's start byte offset into ten equal
  slices of the input and sums to the run/violation count;
  `tailConcentrated := 2*decileCounts[9] >= total` (false at zero);
  `runs` keeps the first 32 + last 32 entries when there are more than 64
  and sets `runsTruncated`, while every count stays exact;
  `firstInvalidOffset`/`lastInvalidOffset` (and the violation
  equivalents) are the first/last run start offsets, null when clean.
- `redactorEquivalent{errorName,errorCode}`: fixed derivation — not
  decodable → `INVALID_UTF8`/26; decodable and (non-NFC or
  `violationCount>0`) → `INVALID_UNICODE`/27; else `NONE`/null. This
  re-measures the redactor outcome; it is not the root-cause verdict.

Value-type law: every value is an integer, boolean, null, fixed enum
literal, or 64-hex digest (or a list/object of those). Before printing, a
fail-closed validator walks the whole tree checking key closure, types,
enum membership, and cross-field consistency; any violation aborts with
`SENSITIVE_OUTPUT` and no stdout.

## Tests

```text
<ARKDECK_ROOT>/.venv-sdd/bin/python scripts/ui_dump_diagnosis/test_diagnose.py
```

Runs the pinned 32-family matrix (input gates, clean positives, UTF-8
structure negatives, codepoint policy negatives, distribution summaries,
output discipline) plus the two mandatory audits (AST
no-shell/no-network/no-write; policyRefs vs measured repository redactor
hashes) and additive extras. All fixtures are synthetic bytes in a
temporary directory outside the repository; the suite performs no
subprocess, socket, or network operation.

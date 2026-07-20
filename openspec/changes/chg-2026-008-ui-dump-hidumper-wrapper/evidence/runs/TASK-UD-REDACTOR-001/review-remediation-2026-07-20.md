# TASK-UD-REDACTOR-001 review remediation — 2026-07-20

## Scope and classification

- Evidence class:`contract` / host-only / synthetic-only.
- Base:`48cbcaffa889c22e6f91cd0be5dcf69b9a1d026d` (`main`, r5 readiness).
- Acceptance:`INT-UD-REDACTOR-001` / `TEST-INT-UD-REDACTOR-001`.
- This run addresses four supplied implementation-review findings. It performs
  no GitHub thread/review write and does not resolve or reply to review threads.
- Real UI raw, installed HDC, device, network, GUI, redactor external process,
  device mutation, destructive dispatch, and hardware evidence count:`0` each.
  Python tests re-executed only the local redactor against synthetic temporary
  files.
- Canonical `AC-DUMP-008-01` is not claimed. `ready→done` remains a separate
  status PR boundary and is not changed here.

## Findings closed

### P1 — repository-contained data paths

`redact.py` now derives the repository root from its resolved source location and
requires the resolved input, output, and receipt paths all to be outside that
root. Direct descendants, the root itself, and paths redirected into the
repository through a symlink fail with `PATH_CONFLICT` before the raw descriptor
or either output is opened.

Regression coverage exercises each of the three path positions, a symlinked
output parent, and a real CLI invocation with repository-contained input. Every
case returns exit `22` and creates no output/receipt.

### P1 — context-free safe literals

`safe-literals-v1.txt` is now a zero-byte allowlist with SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
No input atom is retained. In particular `text=true`, `text=false`, and
`text=null` redact both the key and value. The manifest states that v1 retains
no input token; adding any literal requires a versioned structural grammar and
matching reviewed source/manifest/allowlist update.

### P2 — escaped controls in quoted values

Whole-stream Unicode validation now accepts CR/LF only when invoked for physical
line splitting. JSON-decoded quoted values use the default strict mode and
reject all `Cc`. Synthetic `\\n`, `\\r`, `\\t`, `\\b`, `\\f`, and
`\\u000a` quoted vectors all fail `INVALID_UNICODE` before derived output.

### P2 — receipt statistic integrity

`validate_receipt` now compares all of the following exactly with the supplied
`TransformResult`:replacement total/unique, every `byType` and `uniqueByType`
counter, all line-ending counters, line/token count, and
`checkedSensitiveLiterals`. It also independently requires:

- exact closed type/line-ending key sets and nonnegative integer values;
- replacement totals equal the sums of their type maps;
- `1 <= unique <= total`, and checked literals between one and unique;
- token count at least replacement total;
- every unique-per-type count no greater than its occurrence count.

Tests add 100 independently to each receipt statistic, mutate a built receipt in
place to prove it does not alias `TransformResult` dictionaries, and provide an
internally inconsistent result; every vector now fails `MANIFEST_INVALID`.

## Current reviewed-source candidate hashes

| File | SHA-256 |
| --- | --- |
| `scripts/ui_dump_redaction/README.md` | `18befd7c720226019b47f4dbf6a43e12b60a077b9a37c75221c15de8677cc528` |
| `scripts/ui_dump_redaction/redact.py` | `ff12537c7c9832f410bdb0ed370e7fd810b2e18eda3c58d7123eea14e4a70dc7` |
| `scripts/ui_dump_redaction/test_redact.py` | `78f80b86a0ff030b74811cd816582eb710f99beecefd57d2760d50eaae341952` |
| `scripts/ui_dump_redaction/algorithm-v1.json` | `a75778fdf525050c4c0bcf11579e5f09f99a6fa70697bcf79026656a71f20185` |
| `scripts/ui_dump_redaction/safe-literals-v1.txt` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/ui_dump_redaction/redaction-receipt.schema.json` | `f4bffe70a51dc3f6228f24d41b814dc47cc2d6f0cde5f00445070f86cd1ec4b6` |

The algorithm manifest pins the empty allowlist and receipt-schema hashes. These
candidate bytes still require maintainer review; this run does not self-approve
them.

## Targeted contract result

```text
/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  -m unittest -v scripts/ui_dump_redaction/test_redact.py
```

Result:`PASS` — 20 tests, 0 failures, 0 skips, 0.662 seconds in the final recorded
run.

Besides the original negative/property matrix, this run includes repository-root
exclusion for all data paths, empty-allowlist booleans/null, six quoted escaped
control vectors, eight independently altered receipt statistics, inconsistent
result totals, symlink/FIFO nonblocking rejection, and deterministic replay.

## Remediated synthetic hash chain

The current algorithm manifest bytes were copied to the temporary synthetic
input below (not real UI raw) and transformed twice:

```text
/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  scripts/ui_dump_redaction/redact.py \
  --algorithm-manifest scripts/ui_dump_redaction/algorithm-v1.json \
  --safe-literals scripts/ui_dump_redaction/safe-literals-v1.txt \
  --input /private/tmp/arkdeck-ud-redactor-remediation.ClbUzl/synthetic.raw \
  --expected-input-sha256 a75778fdf525050c4c0bcf11579e5f09f99a6fa70697bcf79026656a71f20185 \
  --output /private/tmp/arkdeck-ud-redactor-remediation.ClbUzl/derived-current.txt \
  --receipt /private/tmp/arkdeck-ud-redactor-remediation.ClbUzl/receipt-current.json
```

Both invocations exited `0`; the replay used distinct
`derived-current-replay.txt` and `receipt-current-replay.json` paths.

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| synthetic input | 3024 | `a75778fdf525050c4c0bcf11579e5f09f99a6fa70697bcf79026656a71f20185` |
| derived output | 2828 | `473ab3d630364563172658691670a9afb2eedc61c783525d7596d3b2f337d125` |
| replayed derived output | 2828 | `473ab3d630364563172658691670a9afb2eedc61c783525d7596d3b2f337d125` |
| first receipt | — | `74d781ee6754da8a4b042fd8e4a5ec03fa5fde490b62b93c974f6a674b76ca57` |
| replay receipt | — | `360cc7240313ddb346338056a1dd6aa5463d56cced86c4dc6fcfb69f728d2b35` |

Receipt facts:source hash
`ff12537c7c9832f410bdb0ed370e7fd810b2e18eda3c58d7123eea14e4a70dc7`;
manifest/allowlist/schema hashes equal the table above; raw 3024 bytes, derived
2828 bytes; 86 lines / 343 tokens; 156 replacements / 140 unique; output-side
check passed over 140 sensitive literals. Receipts differ only in run metadata,
while the two derived hashes are byte-identical.

## Repository checks

```text
/usr/bin/env \
  ARKDECK_PYTHON=/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  sh scripts/check-sdd.sh
```

Result:`PASS` — 0 errors, 0 warnings, 111 acceptance IDs.

```text
swift test --package-path Packages/ArkDeckKit
```

Result:`PASS` — 249 tests, 1 skipped, 0 failures. The skipped case is the
pre-existing manual sleep/wake observation harness; no redactor Swift/product
code exists.

Allowed-path/status, source SHA-256, JSON parse, line-length, trailing-whitespace,
and `git diff --check` audits were also clean. The only worktree changes are the
six approved redactor files and two records in the approved task evidence path.

## Conclusion and residual boundary

All four supplied findings are closed by code plus negative regression vectors.
The remediation preserves the task's offline/stdlib-only/no-overwrite contract
and tightens it:all data paths are repository-external, no input literal is
allowlisted, quoted controls cannot use the physical-line exception, and receipt
statistics are result-bound.

Actual DAYU200 raw grammar compatibility, future golden privacy review,
canonical diagnostic export, hardware support, task `done`, and change
`verified` remain outside this synthetic contract evidence.

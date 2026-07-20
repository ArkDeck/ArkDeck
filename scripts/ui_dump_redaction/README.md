# UI Dump derived-golden redactor

`uidump-derived-redaction-v1` is the host-only, offline privacy boundary used
before a captured ArkUI UI Dump can be considered for a derived golden fixture.
It does **not** capture from a device, classify a HiDumper output family, or
make raw UI Dump bytes repository-safe by assertion alone.

The tool is Python-stdlib-only. It never imports or starts HDC, opens a network
connection, accepts stdin, or constructs a shell command. Tests use synthetic
bytes only.

## Fixed files

- `redact.py`: transform, closed receipt validator, output-side gate, and CLI.
- `algorithm-v1.json`: exact v1 grammar, normalization, limits, error codes,
  placeholder semantics, and hashes of the two policy inputs below.
- `safe-literals-v1.txt`: the complete v1 allowlist (intentionally empty).
- `redaction-receipt.schema.json`: closed JSON schema for the generated receipt.
- `test_redact.py`: offline adversarial and seeded property contract.

The v1 safe-literal file is zero bytes: no input token is retained, including
`true`, `false`, or `null`. This avoids treating a lexical value as structural
without a parser context—for example, `text=true` must redact `true` because it
may be page text. Package, ability, page, window, component, path, user/device
identifier, and page-text values therefore cannot enter derived bytes through
the allowlist. Any future literal requires a versioned grammar with a provable
structural context plus a reviewed source/manifest/allowlist revision; changing
only the text file fails its manifest hash pin.

## Transform contract

The transform:

1. resolves input, output, and receipt and rejects any path at or below the
   repository root (including paths redirected there by a symlink). It then
   opens the input with a read-only, nonblocking, no-follow descriptor and
   requires a regular file bounded to 8 MiB;
2. compares the measured whole-stream SHA-256 with the exact lowercase digest
   supplied by `--expected-input-sha256`;
3. strictly decodes UTF-8, requires NFC, normalizes CRLF/CR/LF to LF, and rejects
   controls, format/bidi characters, unassigned/private/surrogate characters,
   and the fixed confusable-script families in the manifest implementation;
4. applies the closed line/token grammar. Only structural punctuation is
   retained; every valid input token is replaced with a typed placeholder such
   as `@R-PK-000001@` or `@R-TX-000001@`;
5. assigns ordinals per type at first occurrence and reuses the first
   placeholder for an exact duplicate, preserving line and token order;
6. independently reparses the complete derived bytes and accepts only ASCII
   structural punctuation and well-formed placeholders.
   It also checks that no sensitive input lexeme, user path, or key marker
   survived;
7. validates a complete receipt against the bundled closed schema, then creates
   output and receipt with exclusive `0600` writes. Existing files are never
   overwritten. If receipt creation fails, the newly created derived output is
   removed.

JSON double-quoted input values use JSON escaping. Their decoded content is
validated with no line-ending exception: all decoded `Cc`, including `\n`,
`\r`, `\t`, `\b`, and `\f`, fail closed. A valid decoded value is replaced as
one `QU` token and its quotes are retained. Physical CR/LF acceptance applies
only to whole-stream line splitting. Malformed escaping, dangling quotes,
reserved-placeholder impersonation, overlong input, or any unknown/unclassified
line or token also fail closed.

The derived bytes are deterministic for identical input and policy bytes.
Receipt `completedAt` intentionally records the actual UTC completion second,
so receipts from two replays need not be byte-identical; their raw/derived and
policy hashes remain directly comparable.

## Invocation

Use the interpreter fixed by the change readiness record. Pass only filesystem
path tokens; do not pass raw bytes or `-` for stdin:

```text
<ARKDECK_PYTHON> scripts/ui_dump_redaction/redact.py \
  --algorithm-manifest scripts/ui_dump_redaction/algorithm-v1.json \
  --safe-literals scripts/ui_dump_redaction/safe-literals-v1.txt \
  --input <CONTROLLED_RAW_PATH> \
  --expected-input-sha256 <RAW_SHA256> \
  --output <DERIVED_PATH> \
  --receipt <RECEIPT_PATH>
```

All three data paths must resolve outside the repository root. `<DERIVED_PATH>`
and `<RECEIPT_PATH>` must not exist and must not resolve to the input or each
other. A future TASK-UD-001 golden PR may submit only the reviewed derived
bytes and receipt under that task's separate privacy and hash-chain gates; this
tool never performs that submission.

The receipt contains:

- algorithm source, manifest, allowlist, and receipt-schema SHA-256 values;
- raw and derived size/SHA-256 pairs;
- total/unique replacement counts by type;
- line-ending, line, and token accounting;
- the output-side gate result;
- a path-redacted argument-array replay recipe and `completedAt`.

The replay recipe records the real raw SHA-256 but uses
`<CONTROLLED_RAW_PATH>`, `<DERIVED_PATH>`, and `<RECEIPT_PATH>` tokens. It does
not disclose an operator home path or construct a shell string.

## Stable failures

The CLI writes no raw content to stdout or stderr. On failure it prints only a
stable error name and exits with the matching code from `algorithm-v1.json`:

| Code | Name | Meaning |
| ---: | --- | --- |
| 20 | `MANIFEST_INVALID` | algorithm or receipt-schema policy is invalid/drifted |
| 21 | `ALLOWLIST_INVALID` | safe-literal bytes, order, duplicates, or contents drifted |
| 22 | `PATH_CONFLICT` | stdin/empty/conflicting or repository-contained data path |
| 23 | `OUTPUT_EXISTS` | output or receipt already exists |
| 24 | `INPUT_HASH_MISMATCH` | expected digest is malformed or differs |
| 25 | `INPUT_TOO_LARGE` | raw exceeds 8 MiB |
| 26 | `INVALID_UTF8` | strict UTF-8 decode failed |
| 27 | `INVALID_UNICODE` | NFC/control/bidi/confusable/Unicode safety gate failed |
| 28 | `INVALID_LINE` | empty-only, malformed, or over-tokenized line stream |
| 29 | `INVALID_TOKEN` | reserved or malformed token/escape |
| 30 | `RESOURCE_LIMIT` | another manifest resource bound was exceeded |
| 31 | `SENSITIVE_OUTPUT` | independent final output gate found a survivor |
| 32 | `IO_ERROR` | bounded read or exclusive write failed |

Argument-parser errors use argparse's exit code 2.

## Verification

From the repository root:

```text
<ARKDECK_PYTHON> -m unittest -v scripts/ui_dump_redaction/test_redact.py
```

The suite covers repository-contained and symlink-redirected data paths,
invalid UTF-8, CRLF/CR normalization, physical and JSON-escaped controls, NUL, bidi,
confusables, NFC drift, package/ability/path/serial/window/component/long-number
and page-text replacement, malformed/unknown tokens and lines, resource limits,
manifest/allowlist/schema/input-hash drift, every path collision, exclusive
output behavior, rollback, duplicate/order semantics, closed receipt validation,
independent sensitive-output rejection, every receipt statistic and internal
count relationship, seeded property vectors, deterministic replay, raw
immutability, and a static no-process/no-network/stdlib-only audit.

Passing this suite is contract evidence for `INT-UD-REDACTOR-001` only. It is
synthetic, does not close canonical `AC-DUMP-008-01`, and is not raw capture,
hardware evidence, or human privacy review.

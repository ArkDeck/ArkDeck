# TASK-XPA-025 — Python reader RSS allocation diagnosis and v4 fix

The previous real 1 GiB v3 capture reported client sampled growth 253,181,952 bytes.
That PID is the **Python benchmark process**, not the Swift App, ClientKit or Rust
CLI. The result exposes instrument-side overhead in design I.2's large Artifact
paged-transfer measurement. It cannot establish App RSS, the original Swift
128 MiB publication/redaction limit, or a Rust CLI client's memory behavior.
The earlier result remains valid for its named instrument and unchanged.

## Evidence before the fix

The 1 GiB trace has 1,127 actual samples, repeated roughly 5.6 MB increases, and
large later falls; it does not show 253 MB of permanently live Python pages.
A bounded diagnostic therefore exercises the actual read_all / ControlClient /
validate_page code with twelve 4 MiB pages supplied by a fake in-memory socket.
The socket retains only one constant encoded page template, streams small slices,
and adjusts the small envelope per request; no full response is recreated by the
fake server. All identities/ranges/base64/final digest checks still run.

`diagnose.py` records tracemalloc live/peak, native RSS via ps, and read-only
malloc_zone_statistics (SDK header layout) after exchange, after base64, and at
return. It neither calls gc.collect nor changes GC settings, allocator settings,
trim/reclaim APIs, fixture scale or production RSS sampling. Instrumentation has
its own overhead, so this is a causal diagnostic, not a performance baseline.

With v3, RSS went from **34,848,768 to 115,802,112 bytes** over twelve pages. Live
traced allocations at return were only 32,259 bytes; native malloc in-use returned
near baseline (9,819,824 vs 9,746,576 bytes). Per-page live traced memory stayed
near one encoded page after exchange and encoded+decoded pages after validation.
This separates the observed native RSS from Python objects remaining live. It is
consistent with native allocation retention/accounting, not proof of the exact
OS allocator or VM reclamation internals.

Fresh bounded processes isolate each operation (12 iterations, same 4 MiB input):

| Operation | Endpoint RSS growth bytes |
| --- | ---: |
| bytearray.extend receive accumulation | 69,435,392 |
| JSON decoding alone | 5,685,248 |
| complete validate_page | 71,696,384 |
| strict base64 decode alone | 4,243,456 |
| whole-page base64 encode then ASCII decode | 67,436,544 |
| ASCII encode alone | 32,768 |
| fixed transport-capacity receive alternative | 8,486,912 |
| 48 KiB aligned canonical re-encode alternative | 114,688 |

All outputs, including unfavorable intermediate values, are adjacent. The last two
are intentional allocation-path changes, not retries of the same implementation.
The before/after stage diagnostic and these isolated cases identify two concrete
instrument paths: growing bytearray storage and whole-page canonical re-encoding.
They do not claim every native allocator mechanism was proven.

The upstream [CPython 3.14 bytearray resize implementation](https://github.com/python/cpython/blob/v3.14.0/Objects/bytearrayobject.c)
uses realloc on growth, and [binascii base64 encode](https://github.com/python/cpython/blob/v3.14.0/Modules/binascii.c)
allocates oversized output then finishes it to the actual length. These are
supporting upstream source references, not a claim that v3.14.0 is the exact local
C build: the actual diagnostic interpreter is Python 3.14.7. The local behavioral
isolation is the direct evidence for this environment.

## Minimal instrument change

Only the opt-in Artifact measurement exchange changes. It allocates the existing
transport maximum once per response, fills equal-length slices without resizing,
checks the logical received length before every write, and decodes only the filled
prefix. Existing JSON encoding/BOM behavior, duplicate-key/closed envelope checks,
CR/LF/extra-frame refusal, failure byte hashes/prefixes and absolute deadlines
remain. Default UDS microbenchmark exchange is untouched.

Canonical validation still strictly decodes and re-encodes **every byte**, now in
48 KiB decoded input chunks (divisible by three). Each resulting string is at most
64 KiB except the bounded final fragment; no whole-page encoded string is joined.
Every chunk is compared at its correct encoded offset, including final padding
bits, and total encoded length must match. Decoded bytes, final digest, ranges,
4 MiB page size and connection renewal are unchanged.

The new comparison identity is `fixed-buffer-chunked-canonical-json-v4`.
The exact measured pre-commit v4 files and SHA-256 values are archived, alongside
v3's source commit. After diagnosis only a loop-local name was clarified and
behavior tests/docs added; the measured numbers are not attributed to a later
commit or real daemon. No old v2/v3 measurement is relabeled as v4.

Under the same twelve-page diagnostic, v4 RSS went from **36,388,864 to 56,295,424
bytes** (growth 19,906,560), with 30,904 live traced bytes at return. The final
page's exchange/base64 RSS stayed near the first page instead of a page-sized
staircase. This is a bounded instrument improvement, **not 1 GiB/Swift App budget
acceptance**. Tracemalloc peak is also a diagnostic, not a physical copy count.
No target, sampling interval, read budget or acceptance criterion changes.

## Server cost remains a separate finding

Independent read-only review identified two full-file verification paths for a
committed Import: listed_rows/verified_rows/verify_payload, then
read_with_metadata/verify_payload_range. For the prior 1 GiB/256-page case this
implies about 512 GiB of logical hash input in these paths, not measured physical
I/O. The earlier record's statement about 256 full-file checks describes only
the range pass and is incomplete as a total count. Raw measurements are preserved.
Server caching work belongs to a separate task/PR; this change neither bypasses
server proof nor changes Rust/Swift production behavior.

## Local targeted checks

- Twelve-page before/after and each bounded isolation process: exit 0, all raw
  JSON adjacent; no real daemon or target-size artifact run performed here.
- Python benchmark suite: 221 tests, exit 0, three opt-in integration skips,
  `python-tests-permitted.log.gz`. New checks cover chunk-boundary/full padding
  residues, noncanonical pad bits, excess padding, non-ASCII/whitespace refusal,
  bounded re-encoding of every byte, exact frame maximum including LF, fragmented
  UTF-8/BOM and no uninitialized buffer tail. Existing deadline, raw-error,
  duplicate/envelope, digest and 65-page renewal tests remain.
- The first test command inside the sandbox failed only because its existing ps
  test received PermissionError. That original log is retained as
  `python-tests.log.gz`; normal-permission execution passed without changed
  assertions. This is an execution-permission failure, not a suppressed code bug.
- No Rust build/test or full unified gate: only Python instrument/tests/docs change.
  The local window was released to the server owner after diagnostics/tests ended.
- SDD (`sdd.log.gz`) and git diff --check returned 0. A new actual large-fixture
  validation is deliberately deferred until the independently reviewed server
  change and this instrument can be measured together with fresh pinned binaries
  in a coordinated quiet window. No unchanged 1 GiB run was repeated.

## CI

Pending for this new PR. Prior implementation #2285 and v3 capture evidence #2286
passed their own CI; those results are not reused as this head's CI. The PR body
will carry the completed run IDs without amending an already green head.

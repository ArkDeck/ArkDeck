# Windows client startup readiness — 2026-10-06

The Windows daemon reserves its pipe before backend composition. The client
previously accepted the authenticated process image as startup success and
closed the proving connection without exchanging a frame. Composition could
then fail, leaving the caller to connect to an absent Runtime. The reported
cold-start failure had an absent pipe and a retained instance document after
the child exited; that document alone did not prove readiness. No device Job
was launched in that attempt, and its unknown startup intent remains retained.

Every successful `ensure_running` outcome now requires one existing typed
`health` exchange on the same authenticated proving connection. Its connection
and all health IO share the original absolute startup deadline. EOF, timeout,
malformed or incompatible health refuse startup before any caller/business
request; the readiness connection is never reconnected or replayed. The early
namespace reservation, installed-image checks, starter interlock and daemon
single-instance guard remain unchanged. When the retained launched process has
already exited with a nonzero status, the failure preserves that known exit
alongside the readiness diagnostic. It does not infer an initialization cause.

This is a client readiness repair, not an HDC ownership or trust-policy change.
No external process is stopped, no lost request is retried, and no current
Runtime/device acceptance result or hardware evidence is produced here.

## Local targeted checks

All commands ran from `D:/src/ArkDeck-wt/rc-smoke-path`, based on protected
`361d306fd667bb59ad5e1ba8346eef64960b75ee`. The fixed exclusive owner is
`tool-select`, with the existing repository-external cache
`D:/src/ArkDeck-wt/tools/cargo-owners/tool-select` and `CARGO_BUILD_JOBS=2`.
`start_readiness_check.py` invokes `python -X utf8 rust/scripts/run-cargo.py`
with the arguments below, clears all live/signing opt-ins, and retains each
actual exit in a new log under `D:/src/ArkDeck-wt/tools/logs/`.

| Arguments to `run-cargo.py` | Actual result | Log |
| --- | --- | --- |
| `fmt -p arkdeck-client` (sandbox) | 1; Git ownership refused before Cargo | `windows-start-readiness-fmt-initial.log` |
| `fmt -p arkdeck-client` (native) | 0 | `windows-start-readiness-fmt-native.log` |
| `test -p arkdeck-client` | 0; 10 passed | `windows-start-readiness-client-test.log` |
| `clippy -p arkdeck-client -p arkdeck-cli -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `windows-start-readiness-clippy.log` |
| `test -p arkdeck-cli --test client_failure_mapping` | 0; 9 passed | `windows-start-readiness-cli-mapping.log` |
| `fmt --all --check` | 1; Windows `os error 206` | `windows-start-readiness-fmt-all.log` |
| `exec python D:/src/ArkDeck-wt/tools/native_fmt_fallback.py` | 0; all 13 workspace packages checked individually | `windows-start-readiness-fmt-fallback.log` |
| `exec sh scripts/check-sdd.sh` (PATH interpreter) | 2; dependency preflight refused missing PyYAML | `windows-start-readiness-sdd.log` |
| `exec sh scripts/check-sdd.sh` (explicit verified Python/PyYAML) | 0 | `windows-start-readiness-sdd-explicit-python.log` |
| Final `exec sh scripts/check-sdd.sh` | 0 | `windows-start-readiness-sdd-final.log` |

The final source checkout's `git diff --check` returned 0. SDD's first failure
is preserved; the successful check selected the existing Python interpreter
with the exact pinned PyYAML version, without installing or changing a pin.

Native check execution was needed for the existing repository's Windows owner;
no ACL, ownership or Git `safe.directory` setting was changed. The four new
Windows unit cases use only fixture streams and channels: a connection cannot
report readiness before its one health reply, initialization EOF/timeout/broken
pipe cannot replay, incompatible/incomplete replies cannot send a business
frame, and the expired original deadline sends no frame. The existing six
client no-replay cases and nine CLI mapping cases retain their assertions.

The signed native daemon/process fixtures and full direct-consumer test suites
were not executed in this explicitly D0-only window. The new delayed-reply
case measures the readiness exchange, not a native backend-composition failure.
Existing native starter fixtures remain available to CI; their independent
post-start health probe did not itself catch the original early-pipe defect.
The Unix-only bounded transport cases are not executed on this Windows host.

## CI

Not yet pushed; no PR or current-head CI result is claimed. Root owns source
publication, required `guard`/`swift` checks and protected-main RC acceptance.

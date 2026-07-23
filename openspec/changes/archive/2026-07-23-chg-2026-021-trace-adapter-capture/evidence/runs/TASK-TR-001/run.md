# TASK-TR-001 trace tool provenance registration run

- Date/window:2026-07-22 08:59-09:02 Asia/Shanghai(the three redacted-manifest
  filesystem creation times are 08:59:17,09:01:32 and 09:02:12 respectively).
- Operator:`lvye`,human maintainer.The operator stated in the task conversation that the
  approved discover→probe→capture commands were personally completed and authorized direct
  read of the controlled result directory.
- Base:`main` `67f46093c3a2a2389f000e3066b1ff004b359cd9`.
- Approved harness chain:PR #259 (merge
  `a0742f8b38322295fc9c94b89bcf111a27a8e633`) + hardening PR #274 (merge
  `628653c69afdf5f1b3c69e0b9eda03ba111fa5bc`),both APPROVED and merged by `lvye`.
- Environment:DAYU200/OpenHarmony 7.0.0.34,USB;macOS 26.5.2 arm64;HDC
  `Ver: 3.2.0d`,binary SHA-256
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`.
- Evidence class:`controlledHumanCapture` + `documentReview`.This is adapter-input provenance,
  not a canonical realHardware AC and not a hardware/support/conformance/release claim.Agent
  device/HDC/network/external-process dispatch = 0;the Agent only read operator-authorized local
  output after the window.

## Controlled run results

| Phase | Commands | Outcome | Redacted manifest |
| --- | ---: | --- | --- |
| discover | 3 | `probeCaptured`;0 timeout;all exit 0;self-check PASS | `redacted-manifests/discover.json`,SHA-256 `82a8a78810c638a2ef4b774def83334db848410c6799eee3be2cacb0aa425d10` |
| probe | 9 | same pinned HDC/target inventory plus hitrace/bytrace `--help`/`-h`/`-l`;0 timeout;all exit 0;all streams untruncated and self-check PASS | `redacted-manifests/probe.json`,SHA-256 `a3ef53ff58a3b7c761caf6f327e92e65794ce1cf23ca9a68d3b49e77f788c3a7` |
| capture | 8 | same-window manifest gate matched target,HDC hash,`-t/-b/-o` and `sched`;outcome `receivedNonEmptyCleanupComplete`;verified receive preceded exact file/dir cleanup | `redacted-manifests/capture.json`,SHA-256 `4916e025f1e564da218a95d5336a96a0dd4fe8a3ab975e2477a5720d8fdbaa1f` |

The serial/connect key,full manifests,target inventory and full trace remain in the
operator-controlled non-repository directory.The redacted manifests replace every target argv
token with `<connectkey>` and every operator-home prefix with `~`;private-key/user-path scans are
clean.

## Registered observed families

- `hitrace --help` and `hitrace -h` were byte-identical(3,382 bytes,SHA-256
  `9ab0718d7da1d5beb459c74548f89cc69775a931be7931686637d6e584d70e39`)and advertise
  duration `-t` in seconds,buffer `-b` in **KB as spelled by help**,output `-o`,begin/finish,
  text/raw and related options.
- `hitrace -l` produced the registered 81-tag family(3,604 bytes,SHA-256
  `ade3fdc4dd8231dc57e2a8e4ec9d38151a376d245b822f75687c207ead467e96`);all
  built-in `trace-presets` logical tags are present.
- `bytrace --help`/`-h` were byte-identical(3,382 bytes,SHA-256
  `690ca26bbe14d6edd8ad163cce18c1f1a494e4984e8d86f1866f32b7f8bb94fd`),and
  `bytrace -l` produced its registered 81-tag family(3,604 bytes,SHA-256
  `c37e017549ff634b5ffd03339fc7cbe50fd627a1140e84496eb6b68a56694810`).
  No bytrace capture was executed,so it remains `probeOnlyNotCaptureEligible`.
- The exact hitrace minimal argv was
  `hdc -t <durableConnectKey> shell hitrace -t 5 -b 2048 sched -o
  /data/local/tmp/arkdeck/<jobUUID>/minimal.ftrace`.Exit 0 alone is insufficient.The observed
  stdout(268 bytes,SHA-256
  `6070bb0b3d804313449a43e92e570b5e34415cb731ec43ded91b4a3796d99723`)contains
  ordered start/capture-done/read-done(exact owned path)/`TraceFinish done.` markers and empty
  stderr.
- Post-capture remote `ls -l` reported **1,058,246 bytes**.The received immutable raw file was
  also **1,058,246 bytes**,SHA-256
  `6227b5bb0685a2c5c3cd647c6f92bd71da2106ff55e34056cc72c7486b78c21e`,and
  begins with the registered 12-line ftrace header(SHA-256
  `4b6433a1845d533dd466aeb3db965e273f4d4db582c94fe67cf1cb6e1a625ae0`).The full
  raw trace is not committed because it contains process/event data.

## Registry and hash closure

- Registry:`openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml`,
  `OPENHARMONY-TRACE-PROBES@1.0.0`,SHA-256
  `0c093f98b57706b3723a68ae7552bef0db0731a675fb6cc023f69bbe21d6e566`.
- Resource manifest:`resources.json`,SHA-256
  `6b77b020b50921ef419720a434a186aba48c13e7284fa66598d4efd0c4f14879`;
  7 resources/14,939 bytes with exact path/size/SHA-256 closure and binary `.gitattributes`.
- `OPENHARMONY-TOOLS` is bumped 0.3.0→0.4.0 and the lock 0.4.0→0.5.0;existing HDC
  readonly-probe provenance remains pinned to 0.3.0.The new trace registry may be consumed only by
  an independently approved task that adopts the complete 0.4.0 closure(TASK-TR-003 boundary).

## Post-run harness deviation and remediation

The approved schema-1.1.0 harness used for this window captured pre/post/absent `ls -l` receipts,
the capture stdout and the complete received-file hash,but its cleanup gate mechanically required
only a non-empty,self-checked receive.It did **not** itself compare the post-capture remote byte
count with the received byte count or require registered capture markers/ftrace header before
cleanup.This contradicted its runbook claim that truncation was mechanically detected.

The actual run is manually reconcilable and shows no adverse outcome:remote and local sizes are
both 1,058,246 bytes,the exact registered success markers/path and ftrace header are present,and
cleanup happened after receive.This implementation PR hardens schema 1.2.0 so all three checks are
required before cleanup authority,with negative tests for size mismatch,missing markers and
unregistered header;every rejection produces `partialRemoteRetained` and zero rm/rmdir dispatch.
No second real-device run was performed or claimed.

## Verification

| Command | Result |
| --- | --- |
| `python3 -m unittest scripts/trace_capture/test_capture.py -v` | PASS;33 tests,0 failures(30 prior + 3 cleanup-receipt negative gates). |
| `python3 scripts/trace_capture/validate_registry.py` | `TEST-TRACE-PROV-001 PASS`;7 entries,7 resources,14,939 fixture bytes,hash closure and privacy checks PASS,real device dispatch 0. |
| `python3 -m unittest scripts/trace_capture/test_registry.py -v` | PASS;4 tests,0 failures;fixture tamper,unlisted byte and duplicate-member controls fail closed. |
| `scripts/check-sdd.sh` | PASS;0 errors,0 warnings,111 acceptance IDs. |
| allowed-path/diff/secret/privacy scan | PASS;all intended files are within `openspec/integrations/**`,`scripts/**` or this change's `evidence/**`;connectkey leaks 0,raw host user paths/private-key material 0 in registered bytes/evidence,full trace files over 100 KiB 0. |

## Binary conclusion

`TRACE-PROV-001`:**PASS candidate**,subject to maintainer review/merge of this implementation+
evidence PR.Registry exact argv/authority/timeout/marker semantics,help/tag/capture/header golden
bytes,per-file hash closure,redacted manifests and human-operated run are reproducible.No adapter
parser is implemented here;TASK-TR-001 remains `ready`,TASK-TR-003 remains `blocked`,and the change
remains unverified until their separate governance gates complete.

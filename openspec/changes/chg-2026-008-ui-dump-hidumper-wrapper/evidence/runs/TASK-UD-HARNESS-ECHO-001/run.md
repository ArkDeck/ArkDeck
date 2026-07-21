# TASK-UD-HARNESS-ECHO-001 — host-only implementation run

## Classification

- Executed at: `2026-07-21T15:22:04+08:00`.
- Change: `CHG-2026-008-ui-dump-hidumper-wrapper@r9` (`approved`).
- Core baseline: `CORE-2.0.0`.
- Readiness approval: PR #222, merge commit
  `0e0a875d105a1b194f6cfd1ffc5421ee2cbeaf1a`.
- Implementation base: `7f5cb1b9292229c0eafc184361760fa4ebbab191`.
- Implementation source revision:
  `4049bb0de80160a696e6f8defabb3f70e4135d5a`.
- Evidence class: `contract` / offline synthetic fake-runner.
- Change-local result: `INT-UD-HARNESS-ECHO-001` /
  `TEST-INT-UD-HARNESS-ECHO-001` **PASS at the implementation source
  revision above**.
- Canonical result: no `AC-DUMP-008-01` or other canonical Core PASS is
  claimed. This run is not real-hardware, compatibility, support, conformance,
  or release evidence.

## Environment and source identity

- Interpreter: `<ARKDECK_CANONICAL_ROOT>/.venv-sdd/bin/python`, Python
  `3.14.6`, PyYAML `6.0.3`, SHA-256
  `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`.
- No dependency installation or network access was used.
- Deliverable SHA-256 at the implementation source revision:

| Deliverable | SHA-256 |
| --- | --- |
| `scripts/ud_capture/README.md` | `6e5db1827176a0c16b5a4b21431efa9e4d4dab041f03801a357f74b3db2f2601` |
| `scripts/ud_capture/capture.py` | `b407aaa07260e3252428bdf00431f4d1e451c30f77c55f1f6b15a5d170d19492` |
| `scripts/ud_capture/test_capture.py` | `b29c15b8fdca755f26fdfe4f5156082a8bb4a6fd80d8ceecec178419d4690070` |

## Implemented boundary

- Future full/redacted schemas are
  `arkdeck-ud-capture-manifest-1.1.0` and
  `arkdeck-ud-capture-redacted-1.1.0`. Existing PR #219 schema-`1.0.0`
  evidence was not modified, migrated, or reclassified.
- Every stream records deterministic `policyId`,
  `expectedLocalInputEchoFound`, `unexpectedUserPathFound`, and
  `unexpectedLocalInputPathFound` facts while retaining
  `userPathFound` and `localInputPathFound`.
- `fx1-stdout-exact-local-hap-v1` is selected only from the registered
  `FX-1` object for complete, untruncated, non-drain-incomplete stdout when the
  command did not time out. One or more delimiter-bounded byte-exact spans of
  the validated resolved `LOCAL_HAP_PATH` are permitted; every generic
  user-path match must be wholly contained by one of those spans.
- Any outside/embedded match, dirname/prefix/sibling/suffix, case or Unicode
  normalization variant, supplied symlink alias, stderr/other-command echo,
  key material, timeout, truncation, or incomplete drain remains fail-closed.
- `strict-sensitive-output-v1` remains the policy for every other stream.
  Raw retention, whole-stream hashing, owner-only exclusive creation,
  timeout/truncation/drain behavior, and closed argv identities are unchanged.
- Repository-facing `_assert_redacted_clean` is unchanged and still hard-fails
  operator home, connect key, window id, local/user paths, and key-material
  markers. Exact local-path bytes remain only in synthetic controlled raw/full
  artifacts and never enter a redacted manifest, hash summary, CLI text, or
  repository evidence.

## Synthetic adversarial matrix

| Case | Binary result |
| --- | --- |
| Registered `FX-1` complete stdout with two exact resolved-path spans | PASS; expected echo true, unexpected user/local false |
| Exact `/Users/...` span contains every generic user-path byte range | PASS |
| Exact echo plus a second user path | FAIL; `unexpectedUserPathFound=true` |
| Dirname, prefix, sibling, suffix, case, and Unicode-normalization variants | FAIL; no expected echo, unexpected local path true |
| Supplied symlink alias echoed instead of the resolved path | FAIL |
| Exact path in `FX-1` stderr | FAIL under strict policy |
| Same candidate path under a non-`FX-1` registered identity | FAIL under strict policy |
| Exact echo plus key material | FAIL |
| Timeout, truncation, or drain-incomplete stream | FAIL; echo policy not selected and capture incomplete |
| Broken redaction attempts to publish the full FX-1 manifest | FAIL; repo-facing manifest withheld |
| Schema/README/runbook synchronization and deterministic manifest bytes | PASS |

The suite contains the original `52` tests plus `11` remediation tests; all
`63` passed. All bytes in the new positive/negative matrix are synthetic. The
implementation read only the permitted PR #219 `run.md` and redacted FX-1
manifest facts; controlled raw/full manifests and user paths were not opened,
copied, parsed, or fixtureized.

## Commands and results

| Command | Result |
| --- | --- |
| `<ARKDECK_PYTHON> scripts/ud_capture/test_capture.py` | PASS — `Ran 63 tests`, `OK`, 0 failures/errors |
| `ARKDECK_PYTHON=<ARKDECK_PYTHON> scripts/check-sdd.sh` | PASS — 0 errors, 0 warnings, 111 acceptance IDs |
| `<ARKDECK_PYTHON> -m py_compile scripts/ud_capture/capture.py scripts/ud_capture/test_capture.py` | PASS |
| `git diff origin/main...4049bb0de80160a696e6f8defabb3f70e4135d5a --check` | PASS |
| AST no-shell/no-network contract inside `test_capture.py` | PASS |
| Allowed-path and forbidden raw/user-literal audit | PASS — only the three harness deliverables changed at the implementation revision |

## Dispatch accounting, deviations, and residual risk

| Channel | Count |
| --- | ---: |
| Installed HDC process dispatch | 0 |
| Device/fixture/Recipe dispatch | 0 |
| Network or GUI dispatch | 0 |
| Device mutation/destructive dispatch | 0 |
| PR #219 controlled raw/full-manifest reads | 0 |

- No product/spec/contract/Swift/redactor file changed, and
  `TASK-UD-CAP-MUT-001` remains `blocked`.
- An initial static audit expression matched legitimate source literals ending
  in `.manifest.json`; it was narrowed to the exact forbidden evidence path and
  real user literals, then passed. This was an audit-query correction only and
  did not change implementation behavior or evidence classification.
- Residual risk: the exact echo policy is proven only with synthetic bytes in
  this task. It does not reclassify #219 and does not authorize a device run.
  After this implementation PR is merged, a separate status PR must establish
  `TASK-UD-HARNESS-ECHO-001 done`; a further independent status PR must restore
  `TASK-UD-CAP-MUT-001 ready` before a human may start a fresh session at
  `HP-0`.

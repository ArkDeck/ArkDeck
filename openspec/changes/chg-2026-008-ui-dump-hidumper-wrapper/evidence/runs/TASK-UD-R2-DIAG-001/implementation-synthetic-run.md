# TASK-UD-R2-DIAG-001 implementation + synthetic-matrix run — 2026-07-28

**Host-only implementation evidence.** This record covers only the agent-side
deliverable: the three fixed tool files and the synthetic verification matrix.
**The one authorized diagnosis run over the controlled R2 raw is pending and
belongs to the human maintainer alone** (readiness r1 execution model): the
maintainer executes the exact pinned CLI outside every repository and records
`run.md` in this directory in the readiness-pinned form, including the
verbatim stdout report, the offline reading, and the binary root-cause
conclusion (`raw-data` or `pipeline`) or an honest "cannot determine".
Nothing in this record is that run, and nothing here draws or implies a
root-cause conclusion.

## Classification and scope

- Change/task: `CHG-2026-008-ui-dump-hidumper-wrapper` / `TASK-UD-R2-DIAG-001`.
- Acceptance/test: `INT-UD-R2-DIAG-001` / `TEST-INT-UD-R2-DIAG-001`
  (synthetic-contract half; the humanOfflineDiagnosis half is pending).
- Evidence class: `contract` / host-only / synthetic-only.
- Readiness trust root: readiness r1 merged by PR #679, merge OID
  `d9aa14a6d8e73f16fabb7434db351c5e734923fe`.
- Implementation source base: protected `main`
  `8ce50007a6c434e88371fff904519d97d40cf177`. Drafting began at the
  readiness merge OID itself; `main` advanced during the implementation
  window (#680/#681/#682, all outside this task's surfaces), so the same
  four-file change was rebased onto the new tip and every pin below was
  re-measured there — zero drift, zero content change to the delivered
  files.
- Implementation worktree: detached scratchpad worktree on branch
  `agent/chg-2026-008-diag-impl`; the shared primary checkout was not
  written to.
- Agent controlled-raw read count: `0`. The controlled raw path is unknown to
  the agent and appears nowhere in this PR; records use
  `<CONTROLLED_RAW_PATH>`.
- Installed HDC / device / network / GUI / mutation / destructive dispatch:
  `0` each. The tool and its tests performed zero subprocess, socket,
  network, and repository-write operations (AST-audited).

## Open-work re-verification (readiness r1 preconditions, measured in-worktree)

All measured twice — at the readiness merge OID `d9aa14a…23fe` before any
file was created, and again at the rebased source base `8ce5000…cf177`
before push; zero drift both times, so implementation proceeded.

1. Fixed redactor pins — measured equal to the readiness pin table:

   | Input | Measured SHA-256 |
   | --- | --- |
   | `scripts/ui_dump_redaction/redact.py` | `938cc117da97304b5ede66ff55c84dd9ce0a987600d4a1ecec2c3e01351f53e1` |
   | `scripts/ui_dump_redaction/algorithm-v1.json` | `a75778fdf525050c4c0bcf11579e5f09f99a6fa70697bcf79026656a71f20185` |
   | `scripts/ui_dump_redaction/safe-literals-v1.txt` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
   | `scripts/ui_dump_redaction/redaction-receipt.schema.json` | `f4bffe70a51dc3f6228f24d41b814dc47cc2d6f0cde5f00445070f86cd1ec4b6` |

2. Pinned raw origin tuple (`866256` bytes / SHA-256 `ec6663e6…b077`)
   measured literally present and consistent in all three registered places:
   `decisions/r2-element-tree-v1.md`,
   `evidence/runs/TASK-UD-R2-DECISION-001/run.md`, and the proposal r11
   section.
3. Absence: `scripts/ui_dump_diagnosis/` and
   `evidence/runs/TASK-UD-R2-DIAG-001/` did not exist at the source base.
4. Live declaration: the task's Allowed paths block resolves to exactly 7
   patterns (three carrier files, three fixed implementation files, and this
   evidence subtree).

## Environment (fixed SDD interpreter; no fallback, no install)

| Item | Observed value |
| --- | --- |
| Python path | `<PRIMARY_CHECKOUT>/.venv-sdd/bin/python` (shared discovery from the worktree Git common directory) |
| Python | `3.14.6` |
| PyYAML preflight | `6.0.3` (used only by the repository SDD guard; the tool imports stdlib only) |
| Interpreter SHA-256 | `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf` |
| Host/test mode | macOS headless shell; synthetic fixtures in temporary directories outside the repository |

## Delivered files (SHA-256 at commit)

| File | SHA-256 |
| --- | --- |
| `scripts/ui_dump_diagnosis/README.md` | `e25bf27ca74815a87bd95519f449f46a1ee222853955267c0230f451d42429c8` |
| `scripts/ui_dump_diagnosis/diagnose.py` | `df1157af2b672a18c50d1845789cca59b81d515c0b99b7641cd226f5e27da51a` |
| `scripts/ui_dump_diagnosis/test_diagnose.py` | `5ac3d879ceb966a69a9f68d12ca439f61a1a801629f8950e6d2bbda2793ccb62` |

The runtime `tool.sha256` self-measurement in a synthetic end-to-end run
equals the `diagnose.py` hash above, and the embedded `policyRefs` constants
equal the measured repository redactor hashes (asserted by
`test_audit_34_policy_refs_match_repository_redactor`).

## Synthetic matrix result (zero real raw)

```text
<PRIMARY_CHECKOUT>/.venv-sdd/bin/python scripts/ui_dump_diagnosis/test_diagnose.py
Ran 37 tests ... OK  (37/37 PASS)
```

- The 32 readiness-pinned case families all PASS: input gates 7 (hash
  mismatch, length mismatch, oversize, symlink, non-regular, in-repository
  path, non-positive `--expected-length` usage error), clean positives 3,
  UTF-8 structure negatives 7 (EOF truncation, mid-stream truncation, stray
  continuation, invalid lead `0xFE/0xFF`, overlong `0xC0 0xAF`, surrogate
  encoding `0xED 0xA0 0x80`, out-of-range `0xF4 0x90 0x80 0x80`), codepoint
  policy negatives 8 (NUL, TAB+other C0 with LF/CR exemption mirror control,
  DEL, Cf `U+200B`, Co, Cn, confusable CYRILLIC/FULLWIDTH prefixes, non-NFC
  combining sequence), distribution 2 (tail-concentrated true/false), output
  discipline 5 (closed keys, unknown-key injection → `SENSITIVE_OUTPUT`,
  free-string/float injection → `SENSITIVE_OUTPUT`, byte-identical
  determinism, >64 runs truncation with exact counts).
- The 2 mandatory audits PASS: AST audit (both files: import allowlists, no
  shell/subprocess/socket/network/exec/eval; `diagnose.py` additionally has
  no builtin `open` call and only `O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK`
  descriptor flags — zero write surface), and policyRefs-vs-repository hash
  equality.
- Additive extras (allowed by "可增不可减"): matrix-manifest completeness
  (34 pinned names all present), empty-input pure-function closure, and a
  34-string adversarial corpus asserting the structural scanner accepts
  exactly what a strict Python UTF-8 decode accepts.

A synthetic end-to-end CLI smoke over a generated fixture (EOF-truncated
multibyte tail) produced exit `0` and a single canonical JSON line under
`arkdeck-ud-raw-diagnosis-1.0.0` with `redactorEquivalent`
`INVALID_UTF8/26`, `tailConcentrated=true`, and zero content echo; the
mismatched-hash and in-repository-path smokes failed closed with
`INPUT_HASH_MISMATCH`/24 and `IO_ERROR`/32 and zero stdout. (Synthetic bytes
only; not the controlled raw.)

## Repository gates

| Check | Result |
| --- | --- |
| `scripts/check-sdd.sh` (shared `.venv-sdd` interpreter) | `PASS`; `0` errors, `0` warnings, `111` acceptance IDs |
| `git diff --check` (staged tree) | `PASS`; clean |
| `check_pr_paths` local simulation (declared `TASK-UD-R2-DIAG-001`; base = implementation source base `8ce5000…cf177`; head = this PR head; file set = three `scripts/ui_dump_diagnosis/` files + this evidence file) | `PASS`; `changed_paths=4`, every path inside the task's 7-pattern live declaration |
| Sensitive-literal review of this diff | `PASS`; no controlled-raw path, raw bytes, device serial, connect key, token, or nonce; raw facts limited to the already-pinned public tuple |

## Exact-head CI observation and readiness r2 dependency (2026-07-28)

- After push, this PR's exact-head checks measured: `swift` PASS, `open-pr`
  PASS, `guard` PASS, `allowed-paths` FAIL at its first step (`PR
  allowed-paths contract tests`: 49 tests, exactly 1 failure —
  `test_readme_boundary_map_covers_every_first_level_scripts_entry`, because
  `scripts/README.md` does not yet mention `ui_dump_diagnosis`). The job's
  second step, the `check_pr_paths` judgment itself, did not get to run;
  its base-tree simulation over this PR's four paths passes independently
  (table above).
- Root cause: TASK-DEC-001 (#640, merge `3232377…6c8f`) introduced the
  `scripts/` boundary map and that contract test one day before readiness
  r1 was drafted. r1's closed implementation surface (three new files +
  evidence only) cannot satisfy both steps at once: omitting the README
  row fails the contract test, adding it outside the live declaration
  fails the path judgment.
- Remedy in flight: readiness r2 addendum PR #686 (branch
  `agent/chg-2026-008-diag-readiness-r2`) pins `scripts/README.md` into
  the task's Allowed paths with exactly one authorized boundary-map table
  row. Only after the maintainer reviews/merges that addendum will this PR
  be updated with exactly that row plus a rebase; until then this PR does
  not touch `scripts/README.md`, honoring the r1 declaration in force.
- Local proof of the closed fix: with the single authorized row inserted
  in a scratch working tree, the contract suite runs 49/49 OK; the edit
  was reverted and this PR's tree leaves `scripts/README.md` unmodified.

## Pending (maintainer-only; not claimed here)

1. Human maintainer executes, outside every repository:

   ```text
   <ARKDECK_ROOT>/.venv-sdd/bin/python scripts/ui_dump_diagnosis/diagnose.py \
     --input <CONTROLLED_RAW_PATH> \
     --expected-input-sha256 ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077 \
     --expected-length 866256
   ```

2. Maintainer records `run.md` here in the readiness-pinned form (ids +
   evidence class `humanOfflineDiagnosis`, readiness merge OID, interpreter
   facts and preflight, tool/test hashes + source OID, synthetic matrix
   result, exact CLI with placeholder, verbatim stdout JSON, offline reading
   prose, binary conclusion or honest "cannot determine", raw-read and
   dispatch counters, `check-sdd` and `git diff --check` results).
3. Separate `ready→done` status PR only if the conclusion is exactly
   `raw-data` or `pipeline`; otherwise `ready→blocked`. Neither this record
   nor the tool authorizes any revival branch, output family, or
   compatibility/support/conformance claim.

# Design — CHG-2026-076 declared scope extension

## Context and constraints

- Proposal revision 1; `class: implementation-only`, `core_change_level: none`, CORE-3.0.0.
- Related: `scripts/check_pr_paths.py` (TASK-MECH-004 lineage), CHG-2026-040 review finding B-H2
  (the checker runs from the head checkout; base-tree Task authority closed the allowlist half of
  the loop), `AGENTS.md` "提交与 PR", `.github/workflows/agent-pr.yml`.
- Repository evidence: five scope PRs around one implementation PR for `TASK-XPA-003`
  (#1828–#1831, #1834, 2026-09-09/10).

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| DSE-AC-01 in-band extension admitted | `declared_scope_extension()` called from `check_paths()` after the vertical-change supplement returns `None` | fixture repository with a base Task, a head `tasks.md` that adds patterns, a commit with matching trailers |
| DSE-AC-02 every condition fails closed | one named `CheckError` per condition | negative matrix, one case per condition |
| DSE-AC-03 two declaration sources agree | trailer parser shared by preflight (head commit body) and event mode (PR body) | mismatch and one-sided cases |
| DSE-AC-04 configuration | `never_self_extend` in `automation_config.json`, `CONFIG_KEYS`/schema bump, loader validation | config matrix, shipped-config anchor |
| DSE-AC-05 reporting | stderr block in preflight, `--scope-extension-summary`, workflow body/summary steps | output tests, workflow contract tests |
| DSE-AC-06 documentation and no other change | `AGENTS.md` bullet, module docstring | existing suite green, docstring/AGENTS assertions |

## Architecture and data flow

`check_paths()` today: resolve the declared Task → load its definition from the base commit →
compute offenders against `A_base` → try the vertical-change supplement → fail. The extension is
inserted after the supplement returns `None` and before the failure: it loads the head definition of
the same Task from the checkout (already available as `head_definitions`), computes `E`, validates
conditions 1–7 of the proposal, and returns `E` as additional allowed patterns. `CheckResult` gains a
`scope_extension` tuple so callers can report it. No new authority source is introduced: the base
tree still says what is authorised without a declaration; the head tree and the commit message
together say what the PR is asking for, and the reviewer decides by merging.

Trailer syntax: `Scope-Extension: <pattern>` on its own line in the commit body (and, copied by the
workflow, in the PR body); one pattern per line; the pattern text is the exact backtick-free
pattern as written in `tasks.md`; the confusable-token guard used for `Task:` applies.

## Data and contract changes

- `scripts/automation_config.json`: `schema` bumped to the next value; new required key
  `never_self_extend` (non-empty list of unique strings). `CONFIG_KEYS` gains the key; the shipped
  anchor test is updated.
- No durable format, wire contract, Catalog or spec changes.

## Authority and production reachability

Not applicable: the change is a repository CI guard with no production composition root, no
authority or capability, and no effect dispatch. The only "effect" is a pull request check passing or
failing on the hosted runners, and merge by the human CODEOWNER remains the governance decision.

- Production composition root: not applicable (no product code path).
- Authority 产生点: unchanged — maintainer review + merge.
- Effect dispatch point: not applicable.
- Fake/simulation 与 production 的结构差异: the test fixtures build real temporary Git repositories
  with real commits, the same objects the guard reads in CI; no fake path exists.
- Facts/provenance: the base-tree Task definition (immutable Git objects), the head checkout's
  `tasks.md` and the head commit message; the PR identity checks already pin head OID, base ref,
  author and repository.

## Failure, cancellation, and recovery

A guard run either returns a `CheckResult` or raises a `CheckError`; there is no partial state. A
failed run blocks the PR check and prints the condition; the author fixes the trailer, the pattern or
the `tasks.md` line and pushes again.

## Security and privacy

- The trust root stays two-step: `scripts/**`, `.github/**`, `AGENTS.md` and the governance texts are
  in `never_self_extend`, so the checker, the workflow and the rules cannot be self-extended.
- The security kernel (durable formats, device lowering, admission/capability/recovery sources and
  the capability registry) stays two-step by the same list.
- Prefix overlap is refused in both directions, so a broad directory pattern cannot swallow a
  kernel file, and a kernel directory cannot be entered through a sibling pattern.
- No secrets, logs or device data are involved.

## Alternatives and ADRs

- Unconditional head-tree authority: reopens B-H2; rejected.
- Label- or comment-based approval: needs a second human step and write API calls the bot does not
  have; the merge already is the human step; rejected.
- Only widening Allowed paths (CHG-2026-074 r9): necessary but insufficient — packaging scripts,
  test registration and host files were not foreseeable; kept as the companion.
- A second Task per PR: violates one-Task-per-PR (`AGENTS.md`); rejected.
- No new ADR: the guard's contract is documented in its module docstring and `AGENTS.md`.

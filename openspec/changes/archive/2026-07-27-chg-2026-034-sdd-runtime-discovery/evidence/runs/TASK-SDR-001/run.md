# TASK-SDR-001 run — shared SDD runtime discovery and explicit bootstrap

```text
task:      TASK-SDR-001
readiness: r1 (PR #612, merge 982b679)
audit base: d5fac1e0d68e35c1ff0439848500de4a1b60d312 (#605)
implementation base: 86f9e72b8ecb4295061d485a0f4925706c847be1 (#615; branch
           rebased onto it, every gate re-run on the rebased tree)
scope:     host-only; offline checker; ZERO install/network/write in the
           entry; zero device/HDC/product dispatch; no task status change
date:      2026-07-27
operator:  agent session (implementation), maintainer merges per V2
```

## Source pins (readiness r1 → re-verified at implementation base, all exact)

```text
scripts/check-sdd.sh          3ab25cfa5603a74a4ed8e99b54e55a1afaf4e256
scripts/requirements-sdd.txt  f62ce0c56db2b5d134cff98f7fb1625023cd2874  (PyYAML==6.0.3)
.python-version               3f0a10fda703c327eb329f869a19cc5cc05af521  (3.14.6)
openspec/README.md            890f6f7a1abac7d81252b001d82ee7e8892a13f9
```

Interval scans (`git diff --stat/--name-only` over 005e1ff..d5fac1e,
d5fac1e..75926f1, 75926f1..90085a9, 90085a9..86f9e72): zero touch on every
pinned surface and on this change directory. `check_sdd.py` /
`test_check_sdd.py` stay deliberately UNPINNED per r1 (CHG-2026-040
TASK-DEC-003 surface; relational gate, #597 precedent).

## Delivered surface (all inside r1 Allowed paths; blob OIDs)

```text
scripts/check-sdd.sh              7668f5aea9e8d4aeb4620b3047926a8802c1746a
scripts/bootstrap-sdd.sh          c6b7db045d981b54db91dcfc675be22451728afa
scripts/test_sdd_runtime_entry.py 74f8db886d7852edee96e066a45d95d49e0f601c
openspec/README.md                9797daf667efab8ee67d26baa8dd8c755bea9f42
```

- `check-sdd.sh` — resolver `ARKDECK_PYTHON` → current-checkout `.venv-sdd`
  → primary-checkout `.venv-sdd` (canonicalized `git rev-parse
  --git-common-dir`, fixed suffix only) → PATH `python3`; single-process
  PyYAML import/version preflight against the exact pin; five stable
  failure classes with source tag (`explicit|worktree|shared|PATH`) and the
  one bootstrap hint; no traceback, no env dump, no silent fallback; on
  pass the SAME interpreter execs `check_sdd.py` (no second resolution).
  `check_sdd.py` and all SDD rules byte-for-byte untouched.
- `bootstrap-sdd.sh` — human-invoked only; derives the same primary
  checkout; base = `ARKDECK_BOOTSTRAP_PYTHON` single token or `python3`;
  creates the ignored `.venv-sdd` only when absent (never deletes);
  `venv-python -m pip install --require-virtualenv -r
  scripts/requirements-sdd.txt` as argv array; post-install exact
  import/version preflight before reporting success; mkdir-mutex makes
  concurrent bootstrap fail visibly; no `--break-system-packages`, no
  profile writes.
- `scripts/test_sdd_runtime_entry.py` — stdlib-only contract suite (below).
- `openspec/README.md` — Agent-entry note: first-machine bootstrap +
  checker read-only boundary.

## Contract suite (design §4 matrix)

`python3 scripts/test_sdd_runtime_entry.py` → **33 tests, OK** on the
rebased tree. Coverage by class:

- ResolverPrecedenceTests (9): explicit>worktree, explicit bare-name via
  PATH (CI shape `ARKDECK_PYTHON=python`), worktree>shared>PATH,
  primary-checkout self-venv, PATH fallback, git-binary-unavailable and
  no-git-metadata closed fallbacks, spaced primary/linked/interpreter
  paths kept single-token, exactly-two-invocations (preflight + checker).
- FailClosedTests (6): broken explicit blocks healthy lower candidates
  (zero fallback calls logged); missing explicit path; missing PATH
  python3; worktree venv missing-module blocks healthy shared; shared
  version-drift (6.0.99 vs 6.0.3) blocks healthy PATH; silent interpreter
  → stable "did not complete" diagnostic. All exit 2, no `Traceback`.
- PinContractTests (6): pin file missing / entry missing / duplicated /
  non-exact (`PyYAML>=6.0`) / empty version → four named stable failures;
  comments + unrelated dependency lines leave the single exact pin valid.
- ReadOnlyAndCanaryTests (2): fake `pip`/`pip3`/`venv`/`curl`/`wget`
  call-count == 0 across a full pass; worktree file inventory
  byte-identical before/after (zero writes); same-interpreter exec proof.
- SharedDiscoveryRedCanaryTests (1): stripping the marked shared-discovery
  block from the shipped script flips the linked-worktree case green→red
  (exit 2, PATH source, missing-module reason) — mechanism evidence, not
  just an all-green suite.
- BootstrapContractTests (8): primary-target selection from a linked
  worktree (venv lands in primary, not the worktree); exact pip argv
  (`--require-virtualenv -r …requirements-sdd.txt`, no
  `--break-system-packages`); requires-git failure; pre-existing env kept
  (sentinel intact, no re-create) while install still runs; venv-create /
  pip / post-install-drift failures all visible and non-success; concurrent
  lock failure visible; checker rejects a partial bootstrap product.
- CurrentRepositoryIntegrationTests (1): temp linked worktree of THIS
  repository, shipped entry, plain invocation → PASS via the primary
  shared venv (below).

## Live before/after on this machine (real repo, venv-less linked worktree)

```text
audit base (readiness r1 red probe):
  ./scripts/check-sdd.sh → ModuleNotFoundError: No module named 'yaml',
  raw traceback, exit 1
implemented tree, same worktree, same plain command:
  check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs — exit 0
diagnostic sample (measured without pipe masking):
  ARKDECK_PYTHON=/nonexistent/python ./scripts/check-sdd.sh → exit 2,
  four-line stable diagnostic, source=explicit, bootstrap hint, no
  traceback
```

Interpreter facts: primary `.venv-sdd/bin/python` = CPython 3.14.6,
PyYAML 6.0.3 == both pins; PATH `python3` cannot import yaml (PEP 668
externally-managed host); linked-worktree `git rev-parse --git-common-dir`
= `<primary>/.git` (derivation premise).

## Full gate on the rebased tree (readiness ⑧)

```text
python3 scripts/test_sdd_runtime_entry.py   33 OK
<venv>/python scripts/test_check_sdd.py     19 OK   (implementation-time state)
python3 scripts/test_check_pr_paths.py      24 OK
plain ./scripts/check-sdd.sh (linked wt)    0 errors / 0 warnings / 111 acceptance IDs
sh -n check-sdd.sh bootstrap-sdd.sh         syntax OK
git diff --check                            clean
```

CI compatibility: sdd-guard.yml keeps `ARKDECK_PYTHON: python` after
`pip install -r scripts/requirements-sdd.txt` — explicit bare-name source,
pinned version → preflight passes by construction; zero workflow change
(`.github/**` Forbidden and untouched).

## Deviations / residual risk

- `bootstrap-sdd.sh` was NOT executed for real on this machine: the primary
  `.venv-sdd` pre-dates this task, and per tasks.md Notes the existing venv
  must not impersonate clean-host bootstrap evidence. Clean-host behavior
  is covered by the fake-argv bootstrap contract (8 tests); a real
  clean-host run remains a future human action.
- pip/venv/network canaries are argv-level fakes; no OS-level syscall
  tracing was attempted (design asks for canary executables, satisfied).
- No device/HDC/product/destructive dispatch of any kind in this run.

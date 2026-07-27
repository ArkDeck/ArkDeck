# Design — shared SDD runtime discovery

> Change:CHG-2026-034-sdd-runtime-discovery@r1

## 0. Invariants

1. `scripts/check-sdd.sh` remains read-only: no venv creation, package
   installation, network access, profile edit, cache write or repository mutation.
2. Explicit user choice wins. A present higher-priority candidate that fails
   preflight is an error; the entrypoint never silently tries a lower-priority
   interpreter.
3. Shared discovery never crosses a Git repository boundary. The only derived
   executable is `<dirname(canonical git-common-dir)>/.venv-sdd/bin/python`.
4. No command string, `eval`, sourced configuration or shell-generated argv is
   used. Every external invocation receives separately quoted arguments.
5. `check_sdd.py` and every SDD consistency pass/fail rule remain byte-for-byte
   unchanged.
6. Bootstrap is a separate, direct human action. A checker failure may print the
   command but cannot invoke it.

## 1. Resolver

The entrypoint determines one candidate in this order:

1. non-empty `ARKDECK_PYTHON`;
2. executable `<current-checkout>/.venv-sdd/bin/python`;
3. executable `<primary-checkout>/.venv-sdd/bin/python`, where the primary
   checkout is derived from `git -C <current-checkout> rev-parse
   --git-common-dir`, canonicalized, and reduced to its parent directory;
4. `python3` resolved by the host PATH.

For a primary checkout, steps 2 and 3 name the same environment and step 2 wins.
For a linked worktree, Git returns the primary checkout's shared `.git`
directory, so step 3 reuses one machine-local venv across sessions. If Git
common-dir lookup or canonicalization fails, step 3 is skipped and the resolver
continues to PATH; it does not infer a path.

Candidate tokens are never split or reinterpreted. `ARKDECK_PYTHON` continues to
represent one executable path/name, not a command plus arguments.

## 2. Dependency preflight and diagnostics

After resolution, one Python process imports `yaml` and reports its version.
The entrypoint compares that value with the exact `PyYAML==...` pin in the
current checkout's `scripts/requirements-sdd.txt`.

The following are distinct stable failures:

- no executable candidate;
- selected executable cannot start;
- `yaml` cannot be imported;
- imported PyYAML version differs from the current checkout pin;
- dependency pin file is absent, or its PyYAML entry is missing, duplicated or
  not an exact `PyYAML==...` pin. Comments and unrelated future dependency
  entries do not change this preflight.

Diagnostics identify the selected source (`explicit`, `worktree`, `shared` or
`PATH`) and provide the explicit bootstrap command. They do not dump a Python
traceback or environment. Once preflight passes, the same selected executable
executes `scripts/check_sdd.py`; there is no second resolution.

## 3. Explicit bootstrap

`scripts/bootstrap-sdd.sh` is a machine-setup command, not part of the checker:

- it requires a Git working tree and derives the same primary checkout through
  common-dir;
- it selects a base Python from an explicit, single-token override or `python3`;
- it creates the primary checkout's ignored `.venv-sdd` when absent;
- it invokes that venv's Python as an argv array to install the current
  checkout's `scripts/requirements-sdd.txt`;
- it verifies the resulting import and exact PyYAML pin before reporting
  success.

It does not use `--break-system-packages`, write a shell profile, delete an
existing environment, or run automatically. A partial/failed install is not
accepted by the checker preflight. Concurrent bootstrap is unsupported and
must fail visibly rather than being advertised as safe; ordinary concurrent
checker reads remain supported.

## 4. Contract-test seams

The host contract suite uses temporary repositories and fake executable argv
targets; it performs no package download. It exercises:

- explicit/local/shared/PATH precedence, including a real Git linked-worktree
  topology;
- primary checkout and source tree without usable Git metadata;
- spaces in checkout and executable paths;
- missing executable, missing module, wrong version and malformed pin;
- an invalid higher-priority candidate blocking lower-priority fallback;
- a canary `pip`/`venv` executable proving checker invocation count remains zero;
- bootstrap argv/target selection through a fake base Python and fake venv
  interpreter, with no network;
- current repository integration: plain checker invocation from a linked
  worktree succeeds when only the primary checkout contains the pinned venv.

The implementation run must include one red canary showing that removal of
shared discovery makes the linked-worktree case fail, so an all-green suite
alone is not accepted as mechanism evidence.

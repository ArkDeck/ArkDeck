#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")

# Interpreter resolution order:
#   1. explicit ARKDECK_PYTHON override,
#   2. the repo-local pinned virtualenv (.venv-sdd) if present,
#   3. python3.14 from PATH.
# Whichever is chosen, the tooling itself still fails closed unless the
# interpreter matches .python-version and PyYAML matches
# scripts/requirements-sdd.txt.
if [ -n "${ARKDECK_PYTHON:-}" ]; then
  PYTHON=$ARKDECK_PYTHON
elif [ -x "$REPO_DIR/.venv-sdd/bin/python" ]; then
  PYTHON="$REPO_DIR/.venv-sdd/bin/python"
else
  PYTHON=python3.14
fi

"$PYTHON" "$SCRIPT_DIR/check-json.py"
exec "$PYTHON" "$SCRIPT_DIR/check_sdd.py"

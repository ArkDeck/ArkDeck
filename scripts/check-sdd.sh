#!/bin/sh
# ArkDeck SDD 只读一致性校验入口(V2)。解释器解析顺序:
#   1. ARKDECK_PYTHON 显式覆盖;2. 仓库内 .venv-sdd;3. PATH 上的 python3。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")

if [ -n "${ARKDECK_PYTHON:-}" ]; then
  PYTHON=$ARKDECK_PYTHON
elif [ -x "$REPO_DIR/.venv-sdd/bin/python" ]; then
  PYTHON="$REPO_DIR/.venv-sdd/bin/python"
else
  PYTHON=python3
fi

exec "$PYTHON" "$SCRIPT_DIR/check_sdd.py"

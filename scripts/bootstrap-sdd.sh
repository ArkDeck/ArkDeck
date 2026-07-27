#!/bin/sh
# ArkDeck SDD 共享运行时的一次性机器初始化(TASK-SDR-001;仅限人工直接运行)。
# 在同一 Git repository 的主 checkout 创建/更新 ignored `.venv-sdd`,安装当前
# checkout 的 scripts/requirements-sdd.txt,并以 exact import/version preflight
# 验证结果后才报告成功。
# 边界:check-sdd.sh 永不调用本脚本;base 解释器用 ARKDECK_BOOTSTRAP_PYTHON
# 单 token 覆盖(缺省 python3);不使用 --break-system-packages、不写 shell
# profile、不删除既有环境;并发 bootstrap 不受支持,检测到即可见失败。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
REQ_FILE="$REPO_DIR/scripts/requirements-sdd.txt"

bfail() {
  printf 'bootstrap-sdd: %s\n' "$1" >&2
  exit 2
}

[ -f "$REQ_FILE" ] || bfail "dependency pin file is missing: scripts/requirements-sdd.txt"

# exact pin 解析(与 check-sdd.sh 同一契约:恰一行 PyYAML==<version>)。
cr=$(printf '\r')
tab=$(printf '\t')
pin_lines=$(sed -e "s/$cr\$//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$REQ_FILE" | grep -v '^#' | grep '^PyYAML' || true)
if [ -z "$pin_lines" ]; then
  pin_count=0
else
  pin_count=$(printf '%s\n' "$pin_lines" | wc -l | tr -d ' ')
fi
[ "$pin_count" = 1 ] || bfail "scripts/requirements-sdd.txt must contain exactly one PyYAML pin (found $pin_count)"
case $pin_lines in
  *' '*|*"$tab"*) bfail "malformed PyYAML entry in scripts/requirements-sdd.txt (need exact PyYAML==<version>)" ;;
  PyYAML==?*) PIN_VERSION=${pin_lines#PyYAML==} ;;
  *) bfail "malformed PyYAML entry in scripts/requirements-sdd.txt (need exact PyYAML==<version>)" ;;
esac

# 主 checkout 推导:与 check-sdd.sh 同一条只读 common-dir 路径。
common_dir=$(git -C "$REPO_DIR" rev-parse --git-common-dir 2>/dev/null) \
  || bfail "requires a Git working tree (git rev-parse --git-common-dir failed)"
[ -n "$common_dir" ] || bfail "requires a Git working tree (empty git common directory)"
case $common_dir in
  /*) : ;;
  *) common_dir="$REPO_DIR/$common_dir" ;;
esac
common_dir=$(CDPATH= cd -- "$common_dir" 2>/dev/null && pwd -P) \
  || bfail "cannot canonicalize the git common directory"
PRIMARY_DIR=$(dirname -- "$common_dir")
VENV_DIR="$PRIMARY_DIR/.venv-sdd"
VENV_PY="$VENV_DIR/bin/python"

BASE_PYTHON=${ARKDECK_BOOTSTRAP_PYTHON:-python3}

# 并发护栏:mkdir 互斥;失败必须可见,不得宣称并发安全。
LOCK_DIR="$VENV_DIR.bootstrap-lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  bfail "another bootstrap appears to be running (lock exists: $LOCK_DIR); concurrent bootstrap is unsupported — remove the lock only after confirming that run has stopped"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# 只在缺失时创建;绝不删除/重建既有环境。
if [ ! -e "$VENV_DIR" ]; then
  "$BASE_PYTHON" -m venv "$VENV_DIR" \
    || bfail "venv creation failed at $VENV_DIR (base interpreter: $BASE_PYTHON)"
fi
[ -f "$VENV_PY" ] && [ -x "$VENV_PY" ] \
  || bfail "no executable venv python at $VENV_PY"

"$VENV_PY" -m pip install --require-virtualenv -r "$REQ_FILE" \
  || bfail "pip install failed for scripts/requirements-sdd.txt in $VENV_DIR"

# post-install preflight:import + exact 版本,失败不得报告成功。
actual=$("$VENV_PY" -c 'import yaml; print(yaml.__version__)' 2>/dev/null) \
  || bfail "post-install verification failed: venv python cannot import yaml"
[ "$actual" = "$PIN_VERSION" ] \
  || bfail "post-install verification failed: PyYAML $actual != pinned $PIN_VERSION"

printf 'bootstrap-sdd: OK — %s provides PyYAML==%s\n' "$VENV_PY" "$actual"

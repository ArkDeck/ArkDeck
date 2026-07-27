#!/bin/sh
# ArkDeck SDD 只读一致性校验入口(V2)。解释器解析顺序(TASK-SDR-001):
#   1. ARKDECK_PYTHON 显式覆盖;2. 当前 checkout 的 .venv-sdd;
#   3. 同一 Git repository 主 checkout 的共享 .venv-sdd(git common-dir 推导);
#   4. PATH 上的 python3。
# 首个被选中的候选 dependency preflight 失败即 fail closed,不静默降级。
# 本入口零安装、零联网、零仓库写入;机器初始化 = 人工显式运行
# scripts/bootstrap-sdd.sh(本入口只提示,永不调用)。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
PIN_FILE="$REPO_DIR/scripts/requirements-sdd.txt"

fail() {
  # $1 = 选中来源, $2 = 解释器 token, $3 = 原因(稳定诊断,零 traceback)
  printf 'check-sdd: preflight failed\n' >&2
  printf 'check-sdd: interpreter (%s): %s\n' "$1" "$2" >&2
  printf 'check-sdd: reason: %s\n' "$3" >&2
  printf 'check-sdd: bootstrap: run scripts/bootstrap-sdd.sh once on this machine, or set ARKDECK_PYTHON to a Python that satisfies scripts/requirements-sdd.txt\n' >&2
  exit 2
}

# ---- 解释器解析(候选 token 不拆词、不 eval) ----
PYTHON=
SOURCE=
if [ -n "${ARKDECK_PYTHON:-}" ]; then
  PYTHON=$ARKDECK_PYTHON
  SOURCE=explicit
elif [ -x "$REPO_DIR/.venv-sdd/bin/python" ]; then
  PYTHON="$REPO_DIR/.venv-sdd/bin/python"
  SOURCE=worktree
else
  shared_python=
  # --- TASK-SDR-001 shared discovery begin ---
  # 只读推导:git common-dir 规范化为绝对目录后,仅拼接固定后缀。
  # Git 不可用/查询失败/规范化失败一律跳过本级,不做路径猜测。
  if common_dir=$(git -C "$REPO_DIR" rev-parse --git-common-dir 2>/dev/null) \
      && [ -n "$common_dir" ]; then
    case $common_dir in
      /*) : ;;
      *) common_dir="$REPO_DIR/$common_dir" ;;
    esac
    if common_dir=$(CDPATH= cd -- "$common_dir" 2>/dev/null && pwd -P); then
      primary_dir=$(dirname -- "$common_dir")
      if [ -x "$primary_dir/.venv-sdd/bin/python" ]; then
        shared_python="$primary_dir/.venv-sdd/bin/python"
      fi
    fi
  fi
  # --- TASK-SDR-001 shared discovery end ---
  if [ -n "$shared_python" ]; then
    PYTHON=$shared_python
    SOURCE=shared
  else
    PYTHON=python3
    SOURCE=PATH
  fi
fi

# ---- 候选存在性(路径按路径查,裸名按 PATH 查) ----
case $PYTHON in
  */*)
    if [ ! -f "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
      fail "$SOURCE" "$PYTHON" "no executable interpreter at this path"
    fi
    ;;
  *)
    if ! command -v "$PYTHON" >/dev/null 2>&1; then
      fail "$SOURCE" "$PYTHON" "no executable interpreter with this name on PATH"
    fi
    ;;
esac

# ---- 依赖 pin 解析(exact PyYAML==<version>;注释与无关依赖行不参与) ----
if [ ! -f "$PIN_FILE" ]; then
  fail "$SOURCE" "$PYTHON" "dependency pin file is missing: scripts/requirements-sdd.txt"
fi
cr=$(printf '\r')
tab=$(printf '\t')
pin_lines=$(sed -e "s/$cr\$//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PIN_FILE" | grep -v '^#' | grep '^PyYAML' || true)
if [ -z "$pin_lines" ]; then
  pin_count=0
else
  pin_count=$(printf '%s\n' "$pin_lines" | wc -l | tr -d ' ')
fi
case $pin_count in
  0) fail "$SOURCE" "$PYTHON" "no PyYAML pin found in scripts/requirements-sdd.txt" ;;
  1) : ;;
  *) fail "$SOURCE" "$PYTHON" "duplicated PyYAML entries in scripts/requirements-sdd.txt" ;;
esac
case $pin_lines in
  *' '*|*"$tab"*)
    fail "$SOURCE" "$PYTHON" "malformed PyYAML entry in scripts/requirements-sdd.txt (need exact PyYAML==<version>)"
    ;;
  PyYAML==?*)
    PIN_VERSION=${pin_lines#PyYAML==}
    ;;
  *)
    fail "$SOURCE" "$PYTHON" "malformed PyYAML entry in scripts/requirements-sdd.txt (need exact PyYAML==<version>)"
    ;;
esac

# ---- dependency preflight:恰一个 Python 进程导入 yaml 并报告版本 ----
probe='try:
    import yaml
except Exception:
    print("SDD-YAML-MISSING")
else:
    print("SDD-YAML " + str(getattr(yaml, "__version__", "unknown")))'
if ! probe_out=$("$PYTHON" -c "$probe" 2>/dev/null); then
  fail "$SOURCE" "$PYTHON" "selected interpreter failed to start"
fi
case $probe_out in
  "SDD-YAML $PIN_VERSION") : ;;
  "SDD-YAML-MISSING")
    fail "$SOURCE" "$PYTHON" "PyYAML is not importable by the selected interpreter"
    ;;
  "SDD-YAML "*)
    fail "$SOURCE" "$PYTHON" "PyYAML version drift: found ${probe_out#SDD-YAML }, pinned $PIN_VERSION"
    ;;
  *)
    fail "$SOURCE" "$PYTHON" "selected interpreter did not complete the dependency preflight"
    ;;
esac

# preflight 通过:同一解释器执行 checker,无二次解析。
exec "$PYTHON" "$SCRIPT_DIR/check_sdd.py"

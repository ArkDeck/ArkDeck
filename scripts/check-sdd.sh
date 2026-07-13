#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$SCRIPT_DIR/check-json.py"
exec ruby "$SCRIPT_DIR/check-sdd.rb"

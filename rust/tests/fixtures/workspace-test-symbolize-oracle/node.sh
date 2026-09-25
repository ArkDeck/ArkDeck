#!/bin/sh
# The workspace test and symbolize oracle's stand-in for the Node launcher a
# registered DevEco toolchain pins (TASK-XPA-015). Its bytes are fixed, so the
# plans and capabilities name the same executable on every host. It is run
# exactly as a registered Hvigor test preset runs Node: the pinned hvigorw.js
# first, then `test` and the preset's closed argv, in the project root. It
# never runs a real test: it lists the module's ArkTS sources as passing
# cases, or fails a module the project does not declare, as Hvigor does.
set -u
script=$1
task=$2
shift 2
if [ ! -r "$script" ]; then
  printf 'hvigor ERROR: cannot read the Hvigor script\n' >&2
  exit 3
fi
module=
for argument in "$@"; do
  case $argument in
    module=*) module=${argument#module=} ;;
  esac
done
name=${module%@*}
printf '> hvigor Starting task %s for %s\n' "$task" "$module"
printf 'DEVECO_SDK_HOME=%s\n' "${DEVECO_SDK_HOME-unset}"
if [ "$name" != entry ]; then
  printf 'hvigor ERROR: module %s is not declared in build-profile.json5\n' "$name" >&2
  printf 'TESTS FAILED\n'
  exit 1
fi
/usr/bin/find "$name/src/main/ets" -type f | LC_ALL=C /usr/bin/sort | while IFS= read -r file; do
  printf 'PASS %s\n' "$file"
done
printf '> hvigor Finished task %s\n' "$task"
printf 'TESTS PASSED\n'

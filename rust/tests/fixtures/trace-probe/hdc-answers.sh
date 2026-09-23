# trace.probe answers of the shared fake HDC, by mode. The probe's reads
# run concurrently, so each call appends its own line here (one append);
# the driver's log appends a call's arguments and its newline apart.
printf '%s\n' "$*" >> "$root/hdc-calls.log"
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
resources=$root/resources
# A registered family captured at another time: the registry ignores only
# the leading `YYYY/MM/DD HH:MM:SS ` of its enter line.
stamped() { printf '%s' "$1"; /usr/bin/tail -c +21 "$resources/$2"; }
lines() { i=0; while [ $i -lt "$2" ]; do printf '%s\n' "$1"; i=$((i+1)); done; }
run() { i=0; while [ $i -lt "$2" ]; do printf '%s' "$1"; i=$((i+1)); done; printf '\n'; }
# Seven hundred lines of about a hundred bytes: past the 64 KiB a help or
# tag read keeps.
flood() { lines "$1 ................................................................................" 700; }
missing() { printf 'Get parameter "%s" fail! errNum is:106!\n' "$1"; }
parameter() {
  case "$mode:$1" in
  parametersUnreadable:persist.ace.trace.syntax.enabled)
    printf 'Get parameter "another.parameter" fail! errNum is:106!\n' ;;
  parametersUnreadable:persist.ace.trace.layout.enabled)
    printf 'Get parameter "%s" fail! errNum is:105!\n' "$1" ;;
  parametersUnreadable:persist.ace.trace.build.enabled)
    missing "$1"
    printf 'unexpected stderr\n' >&2 ;;
  parametersUnreadable:persist.ace.trace.measure.debug.enabled)
    missing "$1"
    printf 'extra output\n' ;;
  parametersUnreadable:persist.ace.trace.sync.debug.enabled) printf 'true\377\n' ;;
  parametersUnreadable:persist.ace.debug.enabled) run x 401 ;;
  parametersUnreadable:persist.ace.performance.monitor.enabled) lines "$1=true" 600 ;;
  parametersUnreadable:persist.sys.graphic.openDebugTrace) exit 1 ;;
  parametersUnreadable:persist.rosen.animationtrace.enabled) printf 'device offline\n' ;;
  parametersEdge:persist.ace.trace.syntax.enabled) printf 'device unauthorized\n' ;;
  parametersEdge:persist.ace.trace.layout.enabled) kill -9 $$ ;;
  parametersEdge:persist.ace.trace.build.enabled)
    printf '\n  Get parameter "%s" fail! errNum is:106!  \n\n' "$1" ;;
  parametersEdge:persist.ace.trace.measure.debug.enabled) printf 'other.key = 1\n' ;;
  parametersEdge:persist.ace.trace.sync.debug.enabled) printf '%s.extra = 1\n' "$1" ;;
  parametersEdge:persist.ace.debug.enabled) run y 400 ;;
  parametersEdge:persist.ace.performance.monitor.enabled)
    printf 'true\n'
    lines 'noise noise' 600 >&2 ;;
  parametersEdge:persist.sys.graphic.openDebugTrace)
    printf '\357\273\277'
    missing "$1" ;;
  parametersEdge:persist.rosen.animationtrace.enabled) printf '%s =\n' "$1" ;;
  *:persist.ace.trace.syntax.enabled) printf 'false\n' ;;
  *:persist.ace.trace.layout.enabled) printf '%s = true\n' "$1" ;;
  *:persist.ace.trace.build.enabled) missing "$1" ;;
  *:persist.ace.trace.measure.debug.enabled) printf '%s=1\n' "$1" ;;
  *:persist.ace.trace.sync.debug.enabled) : ;;
  *:persist.ace.debug.enabled) printf '0\n' ;;
  *:persist.ace.performance.monitor.enabled) printf '\n  true  \n\n' ;;
  *:persist.sys.graphic.openDebugTrace) printf '1\n' ;;
  *:persist.rosen.animationtrace.enabled) printf 'false\n' ;;
  *)
    printf 'unregistered fixture parameter\n' >&2
    exit 24 ;;
  esac
}
case "$*" in
"-t $key shell hitrace --help")
  case "$mode" in
  restamped) stamped '2026/09/14 08:30:00 ' hitrace-help.stdout.bin ;;
  helpExitNonZero)
    /bin/cat "$resources/hitrace-help.stdout.bin"
    exit 1 ;;
  helpUnregistered) /usr/bin/sed 's/buffer/BUFFER/' "$resources/hitrace-help.stdout.bin" ;;
  helpBadTimestamp) stamped '2026/13/14 08:30:00 ' hitrace-help.stdout.bin ;;
  helpStderr)
    /bin/cat "$resources/hitrace-help.stdout.bin"
    printf 'hitrace: running as shell\n' >&2 ;;
  helpSwapped) /bin/cat "$resources/bytrace-help.stdout.bin" ;;
  helpUnobservable) kill -9 $$ ;;
  helpNotUTF8) printf '\377\376 hitrace\n' ;;
  tagsTimeout)
    /bin/sleep 1
    /bin/cat "$resources/hitrace-help.stdout.bin" ;;
  *) /bin/cat "$resources/hitrace-help.stdout.bin" ;;
  esac ;;
"-t $key shell bytrace --help")
  case "$mode" in
  restamped) stamped '2026/09/14 08:30:00 ' bytrace-help.stdout.bin ;;
  helpExitNonZero)
    /bin/cat "$resources/bytrace-help.stdout.bin"
    exit 3 ;;
  helpUnregistered)
    printf '/bin/sh: bytrace: inaccessible or not found\n'
    exit 127 ;;
  helpSwapped) /bin/cat "$resources/hitrace-help.stdout.bin" ;;
  helpUnobservable) flood 'bytrace usage' ;;
  tagsTimeout)
    /bin/sleep 1
    /bin/cat "$resources/bytrace-help.stdout.bin" ;;
  *) /bin/cat "$resources/bytrace-help.stdout.bin" ;;
  esac ;;
"-t $key shell hitrace -l")
  case "$mode" in
  restamped) stamped '2026/09/14 08:30:00 ' hitrace-tags.stdout.bin ;;
  tagsUnregistered) /usr/bin/sed 's/Ability/ABILITY/' "$resources/hitrace-tags.stdout.bin" ;;
  tagsStderr)
    /bin/cat "$resources/hitrace-tags.stdout.bin"
    printf 'hitrace: running as shell\n' >&2 ;;
  tagsSwapped) /bin/cat "$resources/bytrace-tags.stdout.bin" ;;
  tagsExitNonZero)
    /bin/sleep 1
    /bin/cat "$resources/hitrace-tags.stdout.bin"
    exit 1 ;;
  tagsFailMarker)
    /bin/sleep 1
    printf '[Fail]ExecuteCommand need connect-key?\n' ;;
  tagsUnobservable)
    /bin/sleep 1
    kill -9 $$ ;;
  tagsTruncated)
    /bin/sleep 1
    flood 'category - description' ;;
  tagsTimeout) /bin/sleep 30 ;;
  *) /bin/cat "$resources/hitrace-tags.stdout.bin" ;;
  esac ;;
"-t $key shell param get "*) parameter "$6" ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

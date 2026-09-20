# debug.probe and debug.template.run answers of ArkDeckFakeHDCFixture, by mode.
# The driver records a call as two appends (its arguments, then a
# newline), which three concurrent reads interleave. This oracle records
# its own line instead: one append, so one call is one line whatever else
# runs beside it.
printf '%s\n' "$*" >> "$root/hdc-calls.log"
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
packages() {
  printf 'Bundle names:\n'
  printf '\tcom.example.alpha\n'
  printf '\tcom.example.zeta\n'
}
case "$*" in
"-t $key shell bm dump -a")
  case "$mode" in
  packagesUnavailable|allUnavailable) exit 1 ;;
  packagesUnparseable) printf 'no bundle is installed\n' ;;
  *) packages ;;
  esac ;;
"-t $key fport ls")
  case "$mode" in
  forwardUnavailable|allUnavailable) exit 1 ;;
  *) printf 'tcp:9000 tcp:9001    [Forward]\n' ;;
  esac ;;
"-t $key rport ls")
  case "$mode" in
  reverseUnavailable|allUnavailable)
    printf '[Fail]Device not founded or connected\n' >&2 ;;
  *) printf 'tcp:9100 tcp:9101    [Reverse]\n' ;;
  esac ;;
"-t $key shell param get persist.ace.debug.enabled")
  case "$mode" in
  templateTruncated) i=0; while [ $i -lt 600 ]; do printf 'persist.ace.debug.enabled=true\n'; i=$((i+1)); done ;;
  templateBinary) printf 'persist.ace.debug.enabled=\377\n' ;;
  *) printf 'true\n' ;;
  esac ;;
"-t $key shell hidumper -s WindowManagerService -a -a")
  printf 'WindowManagerService\n----------\nfocus window: com.example.alpha\n' ;;
"-t $key shell uptime")
  case "$mode" in
  templateFailure)
    printf 'uptime: cannot read /proc/uptime\n' >&2
    exit 7 ;;
  templateKilled)
    kill -9 $$
    sleep 5 ;;
  *) printf ' 10:00:00 up 1 day,  2:03,  0 users\n' ;;
  esac ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

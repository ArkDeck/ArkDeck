# The tool's version; a held gesture waits at its injection until the
# oracle releases it; an offline device list names the device offline.
case "$*" in
"-v")
  printf 'Ver: 3.2.0d\n'
  exit 0 ;;
*" shell uinput "*)
  if [ "$mode" = held ]; then
    while [ ! -e /private/tmp/arkdeck-hdc-oracle/released ]; do /bin/sleep 0.01; done
  fi ;;
"list targets -v")
  if [ "$mode" = offline ]; then
    printf '%s\t\tUSB\tOffline\tlocalhost\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    exit 0
  fi ;;
esac
# input.tap@1, input.long-press@1 and input.swipe@1 answers of the shared fake HDC, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
"list targets -v")
  printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"-t $key shell uinput "*)
  case "$mode" in
  rejected) printf 'parameter error, unable to run\n'; exit 0 ;;
  silent) exit 0 ;;
  otherGesture) printf 'startX:100, startY:2200, endX:100, endY:1200\n'; exit 0 ;;
  esac
  shift 4
  [ "$1" = -D ] && shift 2
  case "$2" in
  -c) printf '   click coordinate: (%s, %s)\nclick interval time: 100ms\n' "$3" "$4" ;;
  -d) printf 'touch down %s %s\ntouch up %s %s\n' "$3" "$4" "$8" "$9" ;;
  -m) printf 'startX:%s, startY:%s, endX:%s, endY:%s\n' "$3" "$4" "$5" "$6" ;;
  esac
  printf 'If the command does not work as expected, check whether the specified coordinates exceed the screen boundary\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

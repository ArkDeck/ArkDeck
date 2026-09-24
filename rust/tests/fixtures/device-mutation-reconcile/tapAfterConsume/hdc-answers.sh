# input.tap@1 answers of the shared fake HDC.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
"list targets -v")
  printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"-t $key shell uinput "*)
  shift 4
  [ "$1" = -D ] && shift 2
  case "$2" in
  -c) printf '   click coordinate: (%s, %s)\nclick interval time: 100ms\n' "$3" "$4" ;;
  esac
  printf 'If the command does not work as expected, check whether the specified coordinates exceed the screen boundary\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

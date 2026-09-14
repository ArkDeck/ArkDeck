# observe.device@1 answers of ArkDeckFakeHDCFixture, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
"-v")
  [ "$mode" = emptyVersion ] || printf 'Ver: 3.2.0d\n' ;;
"checkserver")
  if [ "$mode" = serverMismatch ]; then server=3.2.0f; else server=3.2.0d; fi
  printf 'Client version:Ver: 3.2.0d, server version:Ver: %s\n' "$server" ;;
"list targets -v")
  if [ "$mode" = otherDevice ]; then row=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; else row=$key; fi
  printf '%s\t\tUSB\tConnected\tlocalhost\n' "$row" ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

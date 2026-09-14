# capture.diagnostics@1 answers of ArkDeckFakeHDCFixture and the scripted dispatcher, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
"-v")
  printf 'Ver: 3.2.0d\n' ;;
"checkserver")
  printf 'Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n' ;;
"list targets -v")
  if [ "$mode" = otherDevice ]; then row=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; else row=$key; fi
  printf '%s\t\tUSB\tConnected\tlocalhost\n' "$row" ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"-t $key shell df -k /data/local/tmp")
  if [ "$mode" = lowStorage ]; then available=16; else available=1047552; fi
  printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
  printf '/dev/block/data 1048576 1024 %s 1%% /data\n' "$available" ;;
"-t $key shell hilog -x")
  [ "$mode" = emptyHilog ] || printf '01-01 00:00:00 I app: hello\n' ;;
"-t $key shell hidumper -s WindowManagerService -a -a")
  printf '{"windows":[]}\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

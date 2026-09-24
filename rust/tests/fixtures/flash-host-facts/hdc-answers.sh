# flash.prerequisites answers of the shared fake HDC, by mode.
hdc_key=1501ffff00000000000000000000cafe
new_key=1501ffff0000000000000000000beef1
case "$*" in
"list targets -v")
  case "$mode" in
  hdcKey) printf '%s\t\tUSB\tConnected\tlocalhost\n' "$hdc_key" ;;
  newKey) printf '%s\t\tUSB\tConnected\tlocalhost\n' "$new_key" ;;
  offline) printf '%s\t\tUSB\tOffline\tlocalhost\n' "$hdc_key" ;;
  empty) printf '[Empty]\r\n' ;;
  malformed) printf 'no device table here\n' ;;
  *) printf 'list targets failed\n' >&2; exit 1 ;;
  esac ;;
"-t $hdc_key shell param get const.ohos.fullname"|"-t $new_key shell param get const.ohos.fullname")
  printf 'OpenHarmony-7.0.0.36\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

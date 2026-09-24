# port-forward.create@1 answers of the shared fake HDC, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
marker() { printf '%s/device-rule-%s' "$root" "$(printf '%s' "$*" | tr ': ' '__')"; }
case "$*" in
"list targets -v")
  printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"-t $key fport ls")
  for rule in "$root"/device-rule-*; do
    [ -e "$rule" ] || continue
    IFS= read -r row < "$rule"
    printf '%s    %s\n' "$key" "$row"
  done ;;
"-t $key fport tcp:"*)
  printf '%s %s    [Forward]\n' "$4" "$5" > "$(marker "$4" "$5")"
  [ "$mode" = createKilledAfter ] && kill -KILL $$
  printf 'Forwardport result:OK\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

# port-forward.create@1 and port-forward.remove@1 answers of the shared fake HDC, by mode.
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
  [ "$mode" = readbackUnanswered ] && exit 1
  [ "$mode" = ruleUnlisted ] && exit 0
  for rule in "$root"/device-rule-*; do
    [ -e "$rule" ] || continue
    IFS= read -r row < "$rule"
    printf '%s    %s\n' "$key" "$row"
  done ;;
"-t $key fport rm "*)
  rule=$(marker "$5" "$6")
  if [ ! -e "$rule" ]; then
    printf '[Fail]Remove forward ruler failed, ruler is not exist\n'
    exit 1
  fi
  rm -f "$rule"
  printf 'Remove forward ruler success, ruler:%s %s\n' "$5" "$6" ;;
"-t $key fport tcp:"*)
  if [ "$mode" = createRefused ]; then
    printf '[Fail]Forwardport result failed\n'
    exit 1
  fi
  printf '%s %s    [Forward]\n' "$4" "$5" > "$(marker "$4" "$5")"
  printf 'Forwardport result:OK\n' ;;
"-t $key rport tcp:"*)
  printf '%s %s    [Reverse]\n' "$4" "$5" > "$(marker "$4" "$5")"
  printf 'Forwardport result:OK\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

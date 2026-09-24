# capture.diagnostics@1 component tree answers of the shared fake HDC, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
/bin/mkdir -p "$root/device-tmp"
umask 077
case "$*" in
"list targets -v")
  printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"-t $key shell df -k /data/local/tmp")
  printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
  printf '/dev/block/data 1048576 1024 1047552 1%% /data\n' ;;
"-t $key shell uitest dumpLayout -p /data/local/tmp/arkdeck-"*)
  [ "$mode" = treeKilledBefore ] && kill -KILL $$
  printf '{"attributes":{"text":"Sign in","hint":"/private/tmp/arkdeck-hdc-oracle/home/Documents/draft.txt"},"children":[]}\n' > "$(device "$7")"
  [ "$mode" = treeKilledAfter ] && kill -KILL $$
  printf 'DumpLayout saved to:%s\n' "$7" ;;
"-t $key shell ls -l /data/local/tmp/arkdeck-"*)
  if [ -f "$(device "$6")" ]; then
    printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
      "$(($(/usr/bin/wc -c < "$(device "$6")")))" "$6"
  else
    printf 'ls: %s: No such file or directory\n' "$6"
  fi ;;
"-t $key shell ls -ld /data/local/tmp/arkdeck-"*)
  if [ -e "$(device "$6")" ]; then
    printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
      "$(($(/usr/bin/wc -c < "$(device "$6")")))" "$6"
  else
    printf 'ls: %s: No such file or directory\n' "$6"
  fi ;;
"-t $key file recv /data/local/tmp/arkdeck-"*)
  /bin/cp "$(device "$5")" "$6"
  printf 'FileTransfer finish\n' ;;
"-t $key shell rm -f /data/local/tmp/arkdeck-"*)
  if [ "$mode" = cleanupRefused ]; then
    printf 'rm: %s: Read-only file system\n' "$6"
    exit 1
  fi
  /bin/rm -f "$(device "$6")" ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

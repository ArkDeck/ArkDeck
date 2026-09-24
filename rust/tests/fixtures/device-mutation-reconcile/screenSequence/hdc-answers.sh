# capture.screen-sequence@1 answers of the shared fake HDC, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
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
"-t $key shell mkdir -p /data/local/tmp/arkdeck-"*)
  mkdir -p "$(device "$6")" ;;
"-t $key shell snapshot_display "*)
  type=jpeg width=720 height=1280 frame=
  shift 4
  while [ $# -gt 1 ]; do
    case $1 in
    -t) type=$2 ;;
    -w) width=$2 ;;
    -h) height=$2 ;;
    -f) frame=$2 ;;
    esac
    shift 2
  done
  printf '%s %sx%s\n' "${frame##*/}" "$width" "$height" > "$(device "$frame")"
  printf 'file type: %s, width: %s, height: %s\n' "$type" "$width" "$height" ;;
"-t $key shell tar -c -f /data/local/tmp/arkdeck-"*)
  if [ "$mode" = missingArchive ]; then
    printf 'tar: %s: No space left on device\n' "$7"
    exit 1
  fi
  for still in "$(device "$9")"/*; do cat "$still"; done > "$(device "$7")" ;;
"-t $key shell ls -l /data/local/tmp/arkdeck-"*)
  if [ -f "$(device "$6")" ]; then
    printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
      "$(($(wc -c < "$(device "$6")")))" "$6"
  else
    printf 'ls: %s: No such file or directory\n' "$6"
  fi ;;
"-t $key file recv /data/local/tmp/arkdeck-"*)
  [ "$mode" = receiveKilled ] && kill -KILL $$
  cp "$(device "$5")" "$6"
  printf 'FileTransfer finish\n' ;;
"-t $key shell rm -f /data/local/tmp/arkdeck-"*)
  shift 5
  for path; do rm -f "$(device "$path")"; done ;;
"-t $key shell rmdir /data/local/tmp/arkdeck-"*)
  if ! rmdir "$(device "$5")" 2>/dev/null; then
    printf 'rmdir: %s: Directory not empty\n' "$5"
    exit 1
  fi ;;
"-t $key shell ls -ld /data/local/tmp/arkdeck-"*)
  if [ -d "$(device "$6")" ]; then
    printf '%s 2 shell shell 3452 2026-09-14 00:00 %s\n' drwxrwxrwx "$6"
  else
    printf 'ls: %s: No such file or directory\n' "$6"
  fi ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

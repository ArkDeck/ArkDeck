# capture.diagnostics@1 file-leg answers of the shared fake HDC, by mode.
keys='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cccccccccccccccccccccccccccccccc dddddddddddddddddddddddddddddddd'
# The adopted device a call names, if it names one.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if [ "$1" = -t ]; then
  for adopted in $keys; do [ "$2" = "$adopted" ] && key=$adopted; done
fi
# The devices' /data/local/tmp, kept beside the log so that a Job's owned
# files outlive the calls that made them; every owned name carries its Job.
device() { printf '%s/device-tmp/%s' "$root" "${1#/data/local/tmp/}"; }
/bin/mkdir -p "$root/device-tmp"
# What `file recv` lands is owner-only whatever umask the caller runs
# under, so that a landing a failed receive leaves has one mode.
umask 077
case "$*" in
"list targets -v")
  for adopted in $keys; do
    printf '%s\t\tUSB\tConnected\tlocalhost\n' "$adopted"
  done ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"-t $key shell df -k /data/local/tmp")
  printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
  printf '/dev/block/data 1048576 1024 1047552 1%% /data\n' ;;
"-t $key shell uitest dumpLayout -p /data/local/tmp/arkdeck-"*)
  case $mode in
  emptyTree) : > "$(device "$7")" ;;
  treeMissing)
    printf 'DumpLayout failed: no window\n'
    exit 1 ;;
  *)
    printf '{"attributes":{"text":"Sign in","hint":"/private/tmp/arkdeck-hdc-oracle/home/Documents/draft.txt"},"children":[]}\n' > "$(device "$7")" ;;
  esac
  printf 'DumpLayout saved to:%s\n' "$7" ;;
"-t $key shell snapshot_display -t "*)
  if [ "$6" = jpeg ] || [ "$mode" = notPNG ]; then
    printf '\377\330\377\340JFIF still' > "$(device "$8")"
  else
    printf '\211PNG\r\n\032\nIHDR still' > "$(device "$8")"
  fi
  printf 'process: display 0, file type: %s, width: 720, height: 1280\n' "$6" ;;
"-t $key shell ls -l /data/local/tmp/arkdeck-"*)
  if [ -f "$(device "$6")" ]; then
    printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
      "$(($(/usr/bin/wc -c < "$(device "$6")")))" "$6"
  else
    printf 'ls: %s: No such file or directory\n' "$6"
  fi ;;
"-t $key file recv /data/local/tmp/arkdeck-"*)
  case $mode in
  emptyLanding) : > "$6" ;;
  nothingLanded) ;;
  *) /bin/cp "$(device "$5")" "$6" ;;
  esac
  printf 'FileTransfer finish\n' ;;
"-t $key shell rm -f /data/local/tmp/arkdeck-"*)
  case $mode in
  cleanupRefused)
    printf 'rm: %s: Read-only file system\n' "$6"
    exit 1 ;;
  cleanupTimeout) exec /bin/sleep 30 ;;
  *) /bin/rm -f "$(device "$6")" ;;
  esac ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

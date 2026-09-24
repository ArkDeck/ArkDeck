# debug.hap@1 answers of the shared fake HDC, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bundle=com.example.demo
installed=$root/device-installed
running=$root/device-running
marker() { printf '%s/device-path-%s' "$root" "$(printf '%s' "$1" | tr / _)"; }
case "$*" in
"list targets -v")
  printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
"-t $key shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"-t $key shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"-t $key file send "*)
  : > "$(marker "$6")"
  printf 'FileTransfer finish\n' ;;
"-t $key shell bm install -p "*" -r")
  [ "$mode" = installKilledBefore ] && kill -KILL $$
  : > "$installed"
  [ "$mode" = installKilledAfter ] && kill -KILL $$
  printf 'install bundle successfully.\n' ;;
"-t $key shell bm dump -n $bundle")
  if [ -e "$installed" ]; then
    printf '%s:\n' "$bundle"
    printf '{"applicationInfo":{"nativeLibraryPath":"libs/arm64","cpuAbi":"arm64-v8a"},"hapModuleInfos":[{"nativeLibraryFileNames":["libentry.so"]}]}\n'
  fi ;;
"-t $key shell aa start -b $bundle -a EntryAbility")
  [ "$mode" = startFailed ] && exit 1
  : > "$running"
  printf 'start ability successfully\n' ;;
"-t $key shell pidof $bundle")
  [ -e "$running" ] || exit 1
  printf '3421\n' ;;
"-t $key shell hilog -x")
  [ "$mode" = emptyHilog ] || printf '01-01 00:00:00 I app: hello\n' ;;
"-t $key shell aa force-stop $bundle")
  rm -f "$running" ;;
"-t $key uninstall $bundle")
  rm -f "$installed"
  printf 'uninstall bundle successfully\n' ;;
"-t $key shell rm -f /data/local/tmp/arkdeck-"*)
  rm -f "$(marker "$6")" ;;
"-t $key shell ls -ld /data/local/tmp/arkdeck-"*)
  if [ ! -e "$(marker "$6")" ]; then
    printf 'ls: %s: No such file or directory\n' "$6"
  else
    printf '%s 1 shell shell 24 2026-09-14 00:00 %s\n' -rw-r--r-- "$6"
  fi ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

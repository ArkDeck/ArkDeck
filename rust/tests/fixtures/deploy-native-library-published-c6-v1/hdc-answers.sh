# deploy.native-library.app-owned@1 answers of the scripted dispatcher of NativeLibraryDeploymentContractTests, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bundle=com.example.demo
directory=/data/app/el1/bundle/public/$bundle/libs/arm
target=$directory/libexample.so
loader=/data/storage/el1/bundle/libs/arm/libexample.so
replaced=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
library=f8cd1ccd46071323e6b3b8e1a6b2246b7b4ea5d5f71d6ea9990e33ec722f5b53
helper=86497e1a8f9b586169218df912895785c1c0f2d8bb3f87b2b700f6f86264f5c1
running=$root/device-running
published=$root/device-published
marker() { printf '%s/device-path-%s' "$root" "$(printf '%s' "$1" | tr / _)"; }
listed() {
  case "$1" in
  */arkdeck-native/*/*)
    printf '%s 1 20010050 20010050 256 2026-09-14 00:00 %s\n' -rw------- "$1" ;;
  "$directory"|*/libs|*/arkdeck-native/*)
    printf '%s 2 20010050 20010050 3452 2026-09-14 00:00 %s\n' drwx------ "$1" ;;
  *)
    printf '%s 1 20010050 20010050 256 2026-09-14 00:00 %s\n' -rw------- "$1" ;;
  esac
}
present() {
  case "$1" in
  "$directory"|"$target"|*/libs) [ "$mode" != targetAbsent ] ;;
  *) [ -e "$(marker "$1")" ] ;;
  esac
}
case "$*" in
"-t $key shell mkdir -p "*)
  : > "$(marker "$6")" ;;
"-t $key file send "*)
  : > "$(marker "$6")"
  printf 'FileTransfer finish\n' ;;
"-t $key shell chmod 700 "*)
  ;;
"-t $key shell sha256sum "*)
  if ! present "$5"; then
    printf 'sha256sum: %s: No such file or directory\n' "$5"
    exit 0
  fi
  case "$5" in
  *.staging) printf '%s  %s\n' "$library" "$5" ;;
  */arkdeck-code-sign-enable) printf '%s  %s\n' "$helper" "$5" ;;
  "$target") if [ -e "$published" ]; then printf '%s  %s\n' "$library" "$5"; else printf '%s  %s\n' "$replaced" "$5"; fi ;;
  *) printf '%s  %s\n' "$replaced" "$5" ;;
  esac ;;
"-t $key shell ls -la "*)
  if present "$6"; then printf 'total 4\n'; listed "$6/arm"; else printf 'ls: %s: No such file or directory\n' "$6"; fi ;;
"-t $key shell ls -l "*|"-t $key shell ls -ld "*|"-t $key shell ls -ln "*)
  if present "$6"; then listed "$6"; else printf 'ls: %s: No such file or directory\n' "$6"; fi ;;
"-t $key shell rm -f "*)
  [ "$mode" = cleanupFailure ] || rm -f "$(marker "$6")" ;;
"-t $key shell rmdir "*)
  [ "$mode" = cleanupFailure ] || rm -f "$(marker "$5")" ;;
"-t $key shell ln "*)
  : > "$(marker "$6")" ;;
"-t $key shell mv -f "*)
  rm -f "$(marker "$6")" "$published" ;;
"-t $key shell "*"/arkdeck-code-sign-enable verify "*)
  if [ "$mode" = unattested ]; then
    printf 'ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\n'
  else
    printf 'ARKDECK_CODE_SIGN_VERIFIED sha256:%s\n' "$replaced"
  fi ;;
"-t $key shell "*"/arkdeck-code-sign-enable publish "*)
  : > "$published"
  if [ "$mode" = unattested ]; then
    printf 'ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED replaced-file-had-none\n'
  else
    printf 'ARKDECK_CODE_SIGN_PUBLISHED sha256:%s\n' "$replaced"
  fi ;;
"-t $key shell aa force-stop $bundle")
  rm -f "$running" ;;
"-t $key shell aa start -b $bundle -a EntryAbility")
  : > "$running" ;;
"-t $key shell pidof $bundle")
  [ -e "$running" ] || exit 1
  printf '4321\n' ;;
"-t $key shell sleep 2")
  ;;
"-t $key shell grep -F $loader /proc/*/maps")
  if [ "$mode" = loaderFailure ] && [ -e "$published" ]; then exit 1; fi
  printf '/proc/4321/maps:7f000 %s\n' "$loader" ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac

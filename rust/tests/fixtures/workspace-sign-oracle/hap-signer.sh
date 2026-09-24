#!/bin/sh
# The workspace sign oracle's stand-in for the Java launcher a signing preset
# pins, running hap-sign-tool (TASK-XPA-015). Its bytes are fixed, so the
# plans name the same executable on every host. It follows
# ArkDeckFakeHapSignerFixture's protocol — both passwords asked for on the
# terminal and never printed, `sign-app` appending a marker to the staged
# input, `verify-app` writing the two readbacks — and reads its mode from the
# `mode=` line of the HAP it is given rather than from the JAR, so one preset
# serves every case. It never signs anything for real.
set -u
[ "$#" -ge 3 ] && [ "$1" = "-jar" ] || exit 64
[ -r "$2" ] || exit 64
command=$3
shift 3
input= output= chain= profile=
while [ "$#" -gt 0 ]; do
  case $1 in
    -inFile) input=${2-}; shift 2 ;;
    -outFile) output=${2-}; shift 2 ;;
    -outCertChain) chain=${2-}; shift 2 ;;
    -outProfile) profile=${2-}; shift 2 ;;
    *) shift ;;
  esac
done
[ -r "$input" ] || exit 64
mode=$(/usr/bin/sed -n 's/^mode=//p' "$input" | /usr/bin/head -n 1)
case $command in
  sign-app)
    [ -n "$output" ] || exit 64
    if [ "$mode" = unknown-prompt ]; then
      printf 'Password: '
      /bin/sleep 1
      exit 65
    fi
    printf 'please input KeystorePwd (timeout 30 seconds):'
    IFS= read -r keystore || exit 66
    [ -n "$keystore" ] || exit 66
    if [ "$mode" = repeat-prompt ]; then
      printf 'please input KeystorePwd (timeout 30 seconds):'
      /bin/sleep 1
      exit 67
    fi
    printf 'please input KeyPwd (timeout 30 seconds):'
    IFS= read -r key || exit 68
    [ -n "$key" ] || exit 68
    case $mode in
      echo-secret)
        printf '%s' "$keystore"
        exit 69
        ;;
      sign-failure)
        printf 'Incorrect keystore password, please input the correct plaintext password.'
        exit 74
        ;;
    esac
    case $input in
      *.hap) ;;
      *)
        printf 'Invalid file format.'
        exit 75
        ;;
    esac
    [ -e "$output" ] && exit 71
    { /bin/cat "$input" && printf 'arkdeck-signed-fixture'; } >"$output" || exit 70
    exit 0
    ;;
  verify-app)
    [ -n "$chain" ] && [ -n "$profile" ] || exit 72
    magic=$(/usr/bin/head -c 4 "$input" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n')
    [ "$magic" = 504b0304 ] || exit 72
    case $mode in
      verify-failure) exit 73 ;;
      verify-once:*)
        marker=${mode#verify-once:}
        if [ ! -e "$marker" ]; then
          printf 'failed-once' >"$marker"
          exit 73
        fi
        ;;
    esac
    [ -e "$chain" ] || printf 'fixture-certificate-chain' >"$chain"
    [ -e "$profile" ] || printf 'fixture-profile' >"$profile"
    exit 0
    ;;
esac
exit 64

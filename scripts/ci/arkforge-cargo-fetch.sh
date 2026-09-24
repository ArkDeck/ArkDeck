#!/bin/sh
# Fetch the Rust workspace's locked dependency graph. Its ArkForge crates come
# from ArkForge's private repository at the revision Package.swift pins, so
# this fetch needs the same repository-scoped read-only deploy key the Swift
# lanes use, and nothing after it does.
#
# arkforge-package-auth.sh writes the key and the Git transport that uses it.
# Here that transport goes to a private file instead of GITHUB_ENV and is
# exported to this process alone: no later step inherits the key path or the
# rewrite of every github.com URL to SSH, and the key is removed when this
# script exits, before any step builds or runs checked-out code. `cargo fetch`
# itself builds and runs nothing; every later step reads the fetched sources
# from Cargo's cache. Run it from rust/.

set -eu
umask 077

here=$(cd "$(dirname "$0")" && pwd)
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
transport="${RUNNER_TEMP}/arkforge-cargo-transport.env"

# The host key arkforge-package-auth.sh pins, for the Windows path below.
readonly github_ed25519_host_key='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) windows=true ;;
  *) windows=false ;;
esac
credentials=""

remove() {
  if [ "$windows" = true ]; then
    if [ -n "$credentials" ]; then
      rm -f "$credentials/id_ed25519" "$credentials/known_hosts"
      rmdir "$credentials"
    fi
  else
    sh "$here/arkforge-package-auth.sh" cleanup
  fi
  rm -f "$transport"
}
trap remove EXIT

: > "$transport"
if [ "$windows" = true ]; then
  # Git Bash on a Windows runner cannot set a mode on NTFS: the auth script's
  # `install -d -m 0700` fails there with "Permission denied". The key goes
  # instead into a directory mktemp creates for this user alone, written under
  # the umask above, checked and pinned exactly as the auth script does.
  if [ -z "${ARKFORGE_DEPLOY_KEY:-}" ]; then
    echo "::error title=ArkForge package authentication missing::Configure the ARKFORGE_DEPLOY_KEY repository secret with ArkForge's read-only deploy key."
    exit 1
  fi
  credentials=$(mktemp -d)
  printf '%s\n' "$ARKFORGE_DEPLOY_KEY" > "$credentials/id_ed25519"
  if ! ssh-keygen -y -f "$credentials/id_ed25519" </dev/null >/dev/null 2>&1; then
    echo "::error title=ArkForge package authentication invalid::ARKFORGE_DEPLOY_KEY must be an unencrypted SSH private key."
    exit 1
  fi
  printf '%s\n' "$github_ed25519_host_key" > "$credentials/known_hosts"
  {
    printf 'GIT_SSH_COMMAND=ssh -i "%s" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="%s"\n' \
      "$credentials/id_ed25519" "$credentials/known_hosts"
    printf 'GIT_CONFIG_COUNT=1\n'
    printf 'GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf\n'
    printf 'GIT_CONFIG_VALUE_0=https://github.com/\n'
  } > "$transport"
else
  GITHUB_ENV="$transport" sh "$here/arkforge-package-auth.sh" setup
fi
while IFS='=' read -r name value; do
  export "$name=$value"
done < "$transport"

# Cargo's built-in Git ignores GIT_SSH_COMMAND and GIT_CONFIG_*; the Git CLI
# honours both.
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked

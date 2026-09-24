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

remove() {
  sh "$here/arkforge-package-auth.sh" cleanup
  rm -f "$transport"
}
trap remove EXIT

: > "$transport"
GITHUB_ENV="$transport" sh "$here/arkforge-package-auth.sh" setup
while IFS='=' read -r name value; do
  export "$name=$value"
done < "$transport"

# Cargo's built-in Git ignores GIT_SSH_COMMAND and GIT_CONFIG_*; the Git CLI
# honours both.
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked

#!/bin/sh
# Compare the workspace ArkForge pin with ArkForge's default branch and, when
# that pin is behind, rewrite every arkforge crate to the upstream commit and
# refresh Cargo.lock. The deploy key exists only in this process. Vectors run
# in the next workflow step, after this script removes the key.
set -eu
umask 077

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

auth="$root/scripts/ci/arkforge-package-auth.sh"
transport="${RUNNER_TEMP}/arkforge-pin-bump-transport.env"
clone="${RUNNER_TEMP}/arkforge-pin-bump.git"
status_file="${RUNNER_TEMP}/arkforge-pin-bump-status"

remove() {
  sh "$auth" cleanup
  rm -f "$transport" "$status_file"
  rm -rf "$clone"
}
trap remove EXIT

: > "$transport"
GITHUB_ENV="$transport" sh "$auth" setup
while IFS='=' read -r name value; do
  export "$name=$value"
done < "$transport"

# Blobless clone of the default branch. The pin must be a commit on that
# history; a missing or diverged pin fails closed in the Python tool.
git clone --bare --filter=blob:none "https://github.com/ArkDeck/ArkForge.git" "$clone"
python3 "$here/bump-arkforge-pin.py" \
  --repository "$root" \
  --upstream-repo "$clone" \
  --apply \
  --status-file "$status_file"
status=$(tr -d '[:space:]' < "$status_file")
case "$status" in
  bumped)
    revision=$(sed -n 's/^arkforge-ipc = { git = "https:\/\/github.com\/ArkDeck\/ArkForge.git", rev = "\([0-9a-f]\{40\}\)".*/\1/p' "$root/rust/Cargo.toml")
    if ! printf '%s' "$revision" | grep -Eq '^[0-9a-f]{40}$'; then
      echo "arkforge-pin-bump: rewritten pin is not a full revision" >&2
      exit 1
    fi
    printf 'bumped=true\nrevision=%s\n' "$revision" >> "$GITHUB_OUTPUT"
    ;;
  current) printf 'bumped=false\n' >> "$GITHUB_OUTPUT" ;;
  *) echo "arkforge-pin-bump: unexpected status $status" >&2; exit 1 ;;
esac
printf 'status=%s\n' "$status" >> "$GITHUB_OUTPUT"

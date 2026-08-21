#!/bin/sh
# Configure the two compiled CI lanes to fetch ArkForge's private, pinned
# Swift package with a repository-scoped read-only deploy key.  The secret is
# present only in this setup process; later steps inherit the key path and Git
# transport configuration through GITHUB_ENV, never the secret value itself.

set -eu
umask 077

readonly github_ed25519_host_key='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

usage() {
  echo "usage: $0 setup|cleanup" >&2
  exit 64
}

require_runner_environment() {
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  auth_directory="${RUNNER_TEMP}/arkforge-ssh"
  key_path="${auth_directory}/id_ed25519"
  known_hosts_path="${auth_directory}/known_hosts"
}

setup() {
  require_runner_environment
  : "${GITHUB_ENV:?GITHUB_ENV is required}"

  if [ -z "${ARKFORGE_DEPLOY_KEY:-}" ]; then
    echo "::error title=ArkForge package authentication missing::Configure the ARKFORGE_DEPLOY_KEY repository secret with ArkForge's read-only deploy key."
    exit 1
  fi

  install -d -m 0700 "$auth_directory"
  printf '%s\n' "$ARKFORGE_DEPLOY_KEY" > "$key_path"
  chmod 0600 "$key_path"
  if ! ssh-keygen -y -f "$key_path" </dev/null >/dev/null 2>&1; then
    echo "::error title=ArkForge package authentication invalid::ARKFORGE_DEPLOY_KEY must be an unencrypted SSH private key."
    exit 1
  fi

  # GitHub's published Ed25519 host key is pinned instead of learned from the
  # network.  See GitHub Docs: "GitHub's SSH key fingerprints".
  printf '%s\n' "$github_ed25519_host_key" > "$known_hosts_path"
  chmod 0600 "$known_hosts_path"

  {
    printf 'GIT_SSH_COMMAND=ssh -i "%s" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="%s"\n' \
      "$key_path" "$known_hosts_path"
    printf 'GIT_CONFIG_COUNT=1\n'
    printf 'GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf\n'
    printf 'GIT_CONFIG_VALUE_0=https://github.com/\n'
  } >> "$GITHUB_ENV"
}

cleanup() {
  require_runner_environment
  rm -f "$key_path" "$known_hosts_path"
  rmdir "$auth_directory" 2>/dev/null || true
}

case "${1:-}" in
  setup) setup ;;
  cleanup) cleanup ;;
  *) usage ;;
esac

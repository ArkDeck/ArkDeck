#!/bin/sh
# The workspace checkpoint oracle's stand-in for /usr/bin/git. Its bytes are
# fixed, so the materialized plans and the capabilities name the same
# executable on every host; it runs the host's own git with exactly the argv
# the Runtime lowered, in a closed environment that reads no system or user
# configuration, with the author, the committer and their dates fixed, so a
# checkpoint object (`stash create`) repeats on every host.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=Oracle \
  GIT_AUTHOR_EMAIL=oracle@invalid.example GIT_COMMITTER_NAME=Oracle \
  GIT_COMMITTER_EMAIL=oracle@invalid.example \
  GIT_AUTHOR_DATE=2026-09-25T00:00:00Z GIT_COMMITTER_DATE=2026-09-25T00:00:00Z \
  /usr/bin/git "$@"

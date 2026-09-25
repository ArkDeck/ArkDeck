#!/bin/sh
# The workspace read oracle's stand-in for /usr/bin/git. Its bytes are fixed,
# so the materialized plans name the same executable on every host; it runs
# the host's own git with exactly the argv the Runtime lowered, in a closed
# environment that reads no system or user configuration, so the recording
# does not depend on a caller's locale or git settings.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null /usr/bin/git "$@"

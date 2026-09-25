#!/bin/sh
# The workspace checkpoint oracle's stand-in for /usr/bin/bsdtar, the archive
# checkpoint preset. Its bytes are fixed, so the materialized plans and the
# capabilities name the same executable on every host; it runs the host's own
# bsdtar with exactly the argv the Runtime lowered, in a closed environment,
# writing a portable ustar archive with fixed ownership and no Mac metadata,
# so a sealed archive repeats on every host.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C /usr/bin/bsdtar \
  --format ustar --uid 0 --gid 0 --uname root --gname wheel \
  --no-mac-metadata --no-xattrs --no-acls --no-fflags "$@"

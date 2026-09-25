#!/bin/sh
# The workspace checkpoint oracle's stand-in for /usr/bin/sed, the reader a
# Runtime-owned copy's source range is read with. Its bytes are fixed, so the
# materialized plans name the same executable on every host; it runs the
# host's own sed with exactly the argv the Runtime lowered, in a closed
# environment.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C /usr/bin/sed "$@"

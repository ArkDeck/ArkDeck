#!/bin/sh
# The workspace read oracle's stand-in for /usr/bin/sed. Its bytes are fixed,
# so the materialized plans name the same executable on every host; it runs
# the host's own sed with exactly the argv the Runtime lowered, in a closed
# environment, so the recording does not depend on a caller's locale.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C /usr/bin/sed "$@"

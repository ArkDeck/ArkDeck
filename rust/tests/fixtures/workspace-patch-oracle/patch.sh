#!/bin/sh
# The workspace patch oracle's stand-in for /usr/bin/patch. Its bytes are
# fixed, so the materialized plan, the capability it is admitted under and
# the durable records name the same executable on every host; it runs the
# host's own patch with exactly the argv the Runtime lowered.
exec /usr/bin/patch "$@"

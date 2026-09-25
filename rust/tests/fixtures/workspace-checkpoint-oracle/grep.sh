#!/bin/sh
# The workspace checkpoint oracle's stand-in for /usr/bin/grep, the profiles'
# inspection and patch presets, which the recording never runs. Its bytes are
# fixed, so the materialized plans and the capabilities name the same
# executables on every host.
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C /usr/bin/grep "$@"

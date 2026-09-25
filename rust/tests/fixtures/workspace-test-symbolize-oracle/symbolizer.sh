#!/bin/sh
# The workspace test and symbolize oracle's stand-in for the pinned daemon in
# its one-shot `--symbolize-crash <source map> <dump>` mode (TASK-XPA-015).
# Its bytes are fixed, so the plans name the same executable on every host.
# It resolves nothing: it names the map it was given and echoes the dump, or
# fails without output when the map is not there, as the daemon's mode fails.
set -u
if [ "$#" -ne 3 ] || [ "$1" != --symbolize-crash ]; then
  printf -- '--symbolize-crash requires an absolute source map path and dump path\n' >&2
  exit 64
fi
if [ ! -r "$2" ]; then
  printf 'crash symbolization failed: the source map is unreadable\n' >&2
  exit 1
fi
printf 'symbolized with %s\n' "${2##*/}"
/bin/cat "$3"

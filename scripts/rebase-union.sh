#!/bin/sh
# Re-parent the current agent/** branch onto the protected main after other
# pull requests merged, keeping both sides of the append-only records that
# `.gitattributes` marks `merge=union`, and print the lease push to run next.
#
#   scripts/rebase-union.sh                       # onto origin/main
#   scripts/rebase-union.sh --onto <base> <old>   # drop <old>'s commits (a
#                                                 # stacked predecessor that
#                                                 # was squash-merged), replay
#                                                 # the rest onto <base>
#
# The union merge driver resolves tasks.md / rust/README.md additions on its
# own; any other conflict stops the rebase here, for you to resolve and
# `git rebase --continue`. Nothing is pushed: the branch's old head is printed
# with the exact --force-with-lease refspec so the push cannot clobber a head
# you did not see. GitHub's conflict check does not read .gitattributes, so a
# DIRTY pull request clears only once the re-parented head is pushed.
set -eu

branch=$(git rev-parse --abbrev-ref HEAD)
case "$branch" in
  agent/*) ;;
  *) echo "rebase-union: not on an agent/** branch ($branch)" >&2; exit 2 ;;
esac
if [ -n "$(git status --porcelain)" ]; then
  echo "rebase-union: the working tree is not clean" >&2
  exit 2
fi

old=$(git rev-parse HEAD)
git fetch origin main
case "${1-}" in
  "")
    git rebase origin/main ;;
  --onto)
    [ "$#" -eq 3 ] || { echo "usage: $0 --onto <base> <old>" >&2; exit 2; }
    git rebase --onto "$2" "$3" ;;
  *)
    echo "usage: $0 [--onto <base> <old>]" >&2; exit 2 ;;
esac

python3 "$(dirname "$0")/check_union_merge.py"
echo "re-parented $branch: $old -> $(git rev-parse HEAD)"
echo "next: run the slice's tests, then"
echo "  git push --force-with-lease=refs/heads/$branch:$old origin $branch"

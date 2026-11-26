#!/bin/sh
# For a fork's touch-controls builds (.github/workflows/touch-test-build.yml): merges one of the public
# repository's releases (a v* tag of paulstraw/slashplayed) into the checkout, in the runner only, so the
# build carries the fork's touch controls on that release's code without the fork's branch being changed
# (a push of upstream's workflow files would need a token this build doesn't hold). Needs a checkout with
# its whole history (fetch-depth: 0). CHANGELOG.md merges as a union: both sides add entries at the top.
# A conflict anywhere else fails the build, with the files named: the fork needs a hand-made merge then.
# Usage: scripts/fork-merge-upstream.sh <tag>
set -eu
tag="$1"
case "$tag" in v[0-9]*) ;; *) echo "not a release tag: $tag" >&2; exit 2 ;; esac
git fetch --no-tags --quiet https://github.com/paulstraw/slashplayed.git "+refs/tags/$tag:refs/tags/$tag"
echo 'CHANGELOG.md merge=union' >> "$(git rev-parse --git-dir)/info/attributes"
if git merge-base --is-ancestor "refs/tags/$tag" HEAD; then
  echo "already has $tag"
  exit 0
fi
if ! git -c user.name="Touch controls build" -c user.email="touch-build@users.noreply.github.com" \
     merge --no-edit --no-ff -m "Merge Slashplayed $tag" "refs/tags/$tag"; then
  echo "::error::Merging Slashplayed $tag conflicts in: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  exit 1
fi
echo "merged Slashplayed $tag"

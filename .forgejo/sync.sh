#!/usr/bin/env bash
# Publishes main: the framework part of stable (what a build needs, nothing of the owner's), as
# one commit on top of origin/main listing the commits it brings. Built in a temporary index, so
# no branch is switched and the working tree stays as it is. Run by workflows/sync.yml after every
# merge into stable, or by hand through `just sync`.
set -euo pipefail

# what main carries; everything else in stable stays private
keep='^(modules/|flake\.(nix|lock)$|install\.sh$|README\.md$)'

git fetch --quiet origin
src=$(git rev-parse origin/stable)
parent=$(git rev-parse --quiet --verify origin/main || true)

GIT_INDEX_FILE=$(mktemp -u)
export GIT_INDEX_FILE
trap 'rm -f "$GIT_INDEX_FILE"' EXIT
git read-tree "$src"
git ls-files -z | grep -zvE "$keep" | xargs -0 -r git rm --cached --quiet --
tree=$(git write-tree)

if [ -n "$parent" ] && [ "$tree" = "$(git rev-parse "$parent^{tree}")" ]; then
  echo "Nothing to sync."
  exit 0
fi

# the commits since the stable commit the last sync came from
prev=$([ -n "$parent" ] && git log -1 --format=%B "$parent" | sed -n 's/^sync: (\([0-9a-f]\{7,40\}\))$/\1/p' || true)
if [ -n "$prev" ] && git cat-file -e "$prev^{commit}" 2>/dev/null; then range="$prev..$src"; else range="$src"; fi
body=$(git log --no-merges --reverse --format='- %s' "$range")

commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "sync: ($src)" -m "${body:-No individual commits.}")
git push origin "$commit:refs/heads/main"

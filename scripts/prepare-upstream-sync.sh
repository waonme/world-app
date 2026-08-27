#!/usr/bin/env bash

set -Eeuo pipefail

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "run this script inside the world-app repository" >&2
  exit 1
}
cd "$repository_root"

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is not clean; commit or stash all tracked and untracked changes first" >&2
  exit 1
fi

current_branch=$(git branch --show-current)
if [ "$current_branch" != "main" ]; then
  echo "run this script from local main (current: ${current_branch:-detached HEAD})" >&2
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "origin remote is missing" >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/concrnt/world-app.git
fi

git fetch --prune origin main
git fetch --prune upstream main
git merge --ff-only origin/main

local_main=$(git rev-parse HEAD)
origin_main=$(git rev-parse origin/main)
if [ "$local_main" != "$origin_main" ]; then
  echo "local main must exactly match origin/main before an upstream integration" >&2
  exit 1
fi

if git merge-base --is-ancestor upstream/main main; then
  echo "main already contains upstream/main ($(git rev-parse --short=12 upstream/main))"
  exit 0
fi

upstream_sha=$(git rev-parse upstream/main)
upstream_short=$(git rev-parse --short=12 upstream/main)
sync_date=$(date -u +%Y%m%d)
integration_branch="integrate/upstream-${sync_date}-${upstream_short}"

if git show-ref --verify --quiet "refs/heads/$integration_branch"; then
  echo "integration branch already exists: $integration_branch" >&2
  exit 1
fi

git switch -c "$integration_branch"
if ! git merge --no-ff upstream/main -m "Merge upstream world-app through ${sync_date} (${upstream_short})"; then
  echo "resolve conflicts using FORK.md, then run the required gates before committing" >&2
  exit 1
fi

echo "prepared $integration_branch at upstream $upstream_sha"
echo "run the gates in FORK.md, push this branch, and open a PR into main"

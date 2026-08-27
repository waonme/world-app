#!/usr/bin/env bash

set -Eeuo pipefail

github_repository_from_remote_url() {
  local remote_url=$1
  local repository=""

  case "$remote_url" in
    https://github.com/*)
      repository=${remote_url#https://github.com/}
      ;;
    git@github.com:*)
      repository=${remote_url#git@github.com:}
      ;;
    ssh://git@github.com/*)
      repository=${remote_url#ssh://git@github.com/}
      ;;
    *)
      return 1
      ;;
  esac

  repository=${repository%/}
  repository=${repository%.git}
  case "$repository" in
    */*/* | /* | */ | *\?* | *\#*) return 1 ;;
  esac
  [ -n "${repository%%/*}" ] || return 1
  [ -n "${repository#*/}" ] || return 1
  printf '%s\n' "$repository"
}

require_remote_repository() {
  local remote_name=$1
  local expected_repository=$2
  local remote_url
  local actual_repository

  if ! remote_url=$(git remote get-url "$remote_name" 2>/dev/null); then
    echo "$remote_name remote is missing" >&2
    return 1
  fi
  if ! actual_repository=$(github_repository_from_remote_url "$remote_url"); then
    echo "$remote_name must use a standard GitHub HTTPS or SSH URL for $expected_repository (current: $remote_url)" >&2
    return 1
  fi
  if [ "$actual_repository" != "$expected_repository" ]; then
    echo "$remote_name points to $actual_repository; expected $expected_repository" >&2
    return 1
  fi
}

prepare_upstream_sync() {
  local repository_root
  repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "run this script inside the world-app repository" >&2
    return 1
  }
  cd "$repository_root"

  if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is not clean; commit or stash all tracked and untracked changes first" >&2
    return 1
  fi

  local current_branch
  current_branch=$(git branch --show-current)
  if [ "$current_branch" != "main" ]; then
    echo "run this script from local main (current: ${current_branch:-detached HEAD})" >&2
    return 1
  fi

  require_remote_repository origin waonme/world-app

  if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream https://github.com/concrnt/world-app.git
  fi
  require_remote_repository upstream concrnt/world-app

  local origin_main
  local upstream_sha
  local upstream_short
  git fetch --prune origin main
  origin_main=$(git rev-parse 'origin/main^{commit}')
  git fetch --prune upstream main
  upstream_sha=$(git rev-parse 'upstream/main^{commit}')
  upstream_short=$(git rev-parse --short=12 "$upstream_sha")
  git merge --ff-only "$origin_main"

  local local_main
  local_main=$(git rev-parse HEAD)
  if [ "$local_main" != "$origin_main" ]; then
    echo "local main must exactly match origin/main before an upstream integration" >&2
    return 1
  fi

  if git merge-base --is-ancestor "$upstream_sha" main; then
    echo "main already contains upstream/main ($upstream_short)"
    return 0
  fi

  local sync_date
  local integration_branch
  sync_date=$(date -u +%Y%m%d)
  integration_branch="integrate/upstream-${sync_date}-${upstream_short}"

  if git show-ref --verify --quiet "refs/heads/$integration_branch"; then
    echo "integration branch already exists: $integration_branch" >&2
    return 1
  fi

  git switch -c "$integration_branch"
  if ! git merge --no-ff "$upstream_sha" -m "Merge upstream world-app through ${sync_date} (${upstream_short})"; then
    echo "resolve conflicts using FORK.md, then run the required gates before committing" >&2
    return 1
  fi

  echo "prepared $integration_branch at upstream $upstream_sha"
  echo "run the gates in FORK.md, push this branch, and open a PR into main"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  prepare_upstream_sync "$@"
fi

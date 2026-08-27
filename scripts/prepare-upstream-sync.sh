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

  if ! remote_url=$(git config --local --get "remote.$remote_name.url" 2>/dev/null); then
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

require_no_local_url_rewrites() {
  local rewrite_config
  local config_status

  if rewrite_config=$(git config --local --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null); then
    echo "local Git URL rewrite rules are not allowed during upstream synchronization:" >&2
    printf '%s\n' "$rewrite_config" >&2
    return 1
  else
    config_status=$?
  fi
  if [ "$config_status" -ne 1 ]; then
    echo "failed to inspect local Git URL rewrite rules" >&2
    return 1
  fi
}

fetch_canonical_main() {
  local remote_name=$1
  local canonical_url=$2

  require_no_local_url_rewrites || return
  env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    git -c protocol.file.allow=never fetch --no-tags --prune "$canonical_url" \
      "+refs/heads/main:refs/remotes/$remote_name/main"
}

prepare_upstream_sync() {
  local repository_root
  repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "run this script inside the world-app repository" >&2
    return 1
  }
  cd "$repository_root" || return

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

  require_no_local_url_rewrites || return
  require_remote_repository origin waonme/world-app || return

  if ! git config --local --get remote.upstream.url >/dev/null 2>&1; then
    git remote add upstream https://github.com/concrnt/world-app.git || return
  fi
  require_remote_repository upstream concrnt/world-app || return

  local origin_main
  local local_main
  local upstream_sha
  local upstream_short
  fetch_canonical_main origin https://github.com/waonme/world-app.git || return
  origin_main=$(git rev-parse 'origin/main^{commit}') || return
  local_main=$(git rev-parse HEAD) || return
  if [ "$local_main" != "$origin_main" ]; then
    echo "local main must exactly match origin/main before an upstream integration" >&2
    return 1
  fi

  fetch_canonical_main upstream https://github.com/concrnt/world-app.git || return
  upstream_sha=$(git rev-parse 'upstream/main^{commit}') || return
  upstream_short=$(git rev-parse --short=12 "$upstream_sha") || return

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

  git switch -c "$integration_branch" || return
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

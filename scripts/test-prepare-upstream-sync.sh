#!/usr/bin/env bash

set -Eeuo pipefail

repository_root=$(git rev-parse --show-toplevel)
task_test_parent=${TMPDIR:-/tmp}
task_test_dir=$(mktemp -d "$task_test_parent/world-app-upstream-test.XXXXXXXX")

cleanup() {
  case "$task_test_dir" in
    "$task_test_parent"/world-app-upstream-test.*) rm -rf -- "$task_test_dir" ;;
    *) echo "refusing to remove unexpected test directory: $task_test_dir" >&2 ;;
  esac
}
trap cleanup EXIT

# shellcheck source=prepare-upstream-sync.sh
source "$repository_root/scripts/prepare-upstream-sync.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_repository() {
  local expected=$1
  local remote_url=$2
  local actual
  if ! actual=$(github_repository_from_remote_url "$remote_url"); then
    fail "standard GitHub remote was rejected: $remote_url"
  fi
  if [ "$actual" != "$expected" ]; then
    fail "remote $remote_url resolved to $actual instead of $expected"
  fi
}

assert_repository waonme/world-app https://github.com/waonme/world-app.git
assert_repository waonme/world-app https://github.com/waonme/world-app/
assert_repository waonme/world-app git@github.com:waonme/world-app.git
assert_repository concrnt/world-app ssh://git@github.com/concrnt/world-app.git

for invalid_url in \
  https://example.com/waonme/world-app.git \
  https://github.com/waonme/world-app/extra \
  git@example.com:waonme/world-app.git; do
  if github_repository_from_remote_url "$invalid_url" >/dev/null 2>&1; then
    fail "nonstandard or lookalike remote was accepted: $invalid_url"
  fi
done

test_repository="$task_test_dir/repository"
git init -q "$test_repository"
git -C "$test_repository" remote add origin git@github.com:waonme/world-app.git
git -C "$test_repository" remote add upstream https://github.com/concrnt/world-app.git

(
  cd "$test_repository"
  require_remote_repository origin waonme/world-app
  require_remote_repository upstream concrnt/world-app
)

git -C "$test_repository" remote set-url origin https://github.com/concrnt/world-app.git
if (
  cd "$test_repository"
  require_remote_repository origin waonme/world-app
) >/dev/null 2>&1; then
  fail "origin pointing at the upstream repository must be rejected"
fi

git -C "$test_repository" remote set-url origin https://github.com/waonme/world-app.evil.git
if (
  cd "$test_repository"
  require_remote_repository origin waonme/world-app
) >/dev/null 2>&1; then
  fail "origin pointing at a lookalike repository must be rejected"
fi

git -C "$test_repository" remote set-url origin https://example.com/waonme/world-app.git
if (
  cd "$test_repository"
  require_remote_repository origin waonme/world-app
) >/dev/null 2>&1; then
  fail "origin on a non-GitHub host must be rejected"
fi

create_sync_fixture() {
  local fixture_name=$1
  local fixture_mode=$2
  local fixture_root="$task_test_dir/$fixture_name"
  local seed_repository="$fixture_root/seed"
  local origin_repository="$fixture_root/origin.git"
  local upstream_repository="$fixture_root/upstream.git"
  local work_repository="$fixture_root/work"
  local base_sha

  mkdir -p "$fixture_root"
  git init -q "$seed_repository"
  git -C "$seed_repository" config user.email test@example.invalid
  git -C "$seed_repository" config user.name "World App Sync Test"
  printf 'base\n' > "$seed_repository/shared.txt"
  git -C "$seed_repository" add shared.txt
  git -C "$seed_repository" commit -q -m base
  git -C "$seed_repository" branch -M main
  base_sha=$(git -C "$seed_repository" rev-parse HEAD)

  git init --bare -q "$origin_repository"
  git init --bare -q "$upstream_repository"
  git --git-dir="$origin_repository" symbolic-ref HEAD refs/heads/main
  git --git-dir="$upstream_repository" symbolic-ref HEAD refs/heads/main
  git -C "$seed_repository" remote add fixture-origin "$origin_repository"
  git -C "$seed_repository" remote add fixture-upstream "$upstream_repository"
  git -C "$seed_repository" push -q fixture-origin main
  git -C "$seed_repository" push -q fixture-upstream main

  git -C "$seed_repository" switch -q -c upstream-change "$base_sha"
  if [ "$fixture_mode" = conflict ]; then
    printf 'upstream\n' > "$seed_repository/shared.txt"
  else
    printf 'upstream-only\n' > "$seed_repository/upstream.txt"
  fi
  git -C "$seed_repository" add .
  git -C "$seed_repository" commit -q -m upstream
  git -C "$seed_repository" push -q fixture-upstream HEAD:main

  if [ "$fixture_mode" = conflict ]; then
    git -C "$seed_repository" switch -q -c fork-change "$base_sha"
    printf 'fork\n' > "$seed_repository/shared.txt"
    git -C "$seed_repository" add shared.txt
    git -C "$seed_repository" commit -q -m fork
    git -C "$seed_repository" push -q fixture-origin HEAD:main
  fi

  git clone -q "$origin_repository" "$work_repository"
  git -C "$work_repository" remote add upstream "$upstream_repository"
  git -C "$work_repository" config user.email test@example.invalid
  git -C "$work_repository" config user.name "World App Sync Test"
  printf '%s\n' "$work_repository"
}

run_prepare_with_local_remotes() {
  # URL parsing is tested above. These fixtures intentionally use local bare
  # remotes so the complete branch/merge state machine stays network-free.
  require_remote_repository() { return 0; }
  prepare_upstream_sync
}

success_work=$(create_sync_fixture success merge)
printf 'dirty\n' > "$success_work/untracked.txt"
if (
  cd "$success_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "a dirty working tree must be rejected before synchronization"
fi
rm -f "$success_work/untracked.txt"

git -C "$success_work" switch -q -c topic
if (
  cd "$success_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "a non-main starting branch must be rejected"
fi
git -C "$success_work" switch -q main

(
  cd "$success_work"
  run_prepare_with_local_remotes >/dev/null
  upstream_sha=$(git rev-parse upstream/main)
  git merge-base --is-ancestor "$upstream_sha" HEAD
  [ "$(git branch --show-current)" = "integrate/upstream-$(date -u +%Y%m%d)-$(git rev-parse --short=12 "$upstream_sha")" ]
  [ "$(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" = 3 ]
) || fail "the full synchronization flow must create a merge integration branch at the fetched upstream SHA"

ahead_work=$(create_sync_fixture local-ahead merge)
printf 'local-only\n' > "$ahead_work/local.txt"
git -C "$ahead_work" add local.txt
git -C "$ahead_work" commit -q -m local-only
if (
  cd "$ahead_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "local main that differs from origin/main must be rejected"
fi

existing_work=$(create_sync_fixture existing-branch merge)
existing_upstream_sha=$(git --git-dir="$task_test_dir/existing-branch/upstream.git" rev-parse main)
existing_branch="integrate/upstream-$(date -u +%Y%m%d)-${existing_upstream_sha:0:12}"
git -C "$existing_work" branch "$existing_branch"
if (
  cd "$existing_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "an existing integration branch must be rejected instead of reused"
fi

conflict_work=$(create_sync_fixture conflict conflict)
if (
  cd "$conflict_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "an unresolved semantic merge conflict must not report success"
fi
if [ -z "$(git -C "$conflict_work" ls-files -u)" ]; then
  fail "the conflict fixture must leave explicit unmerged entries for review"
fi

echo "upstream remote provenance and synchronization workflow tests passed"

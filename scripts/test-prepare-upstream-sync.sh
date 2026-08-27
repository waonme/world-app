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
  git -C "$work_repository" remote set-url origin https://github.com/waonme/world-app.git
  git -C "$work_repository" remote add upstream https://github.com/concrnt/world-app.git
  # Keep the production-facing URLs intact so the complete provenance checks run,
  # while redirecting transport to deterministic local bare repositories.
  git -C "$work_repository" config "url.file://$origin_repository.insteadOf" https://github.com/waonme/world-app.git
  git -C "$work_repository" config "url.file://$upstream_repository.insteadOf" https://github.com/concrnt/world-app.git
  git -C "$work_repository" config user.email test@example.invalid
  git -C "$work_repository" config user.name "World App Sync Test"
  printf '%s\n' "$work_repository"
}

run_prepare_with_local_remotes() {
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

printf 'dirty tracked\n' >> "$success_work/shared.txt"
if (
  cd "$success_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "an unstaged tracked change must be rejected before synchronization"
fi
git -C "$success_work" add shared.txt
if (
  cd "$success_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "a staged tracked change must be rejected before synchronization"
fi
git -C "$success_work" restore --staged --worktree shared.txt

git -C "$success_work" switch -q -c topic
if (
  cd "$success_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "a non-main starting branch must be rejected"
fi
git -C "$success_work" switch -q main

git -C "$success_work" switch -q --detach
if (
  cd "$success_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "a detached HEAD must be rejected before synchronization"
fi
git -C "$success_work" switch -q main

(
  cd "$success_work"
  expected_origin_sha=$(git ls-remote origin refs/heads/main | awk '{print $1}')
  expected_upstream_sha=$(git ls-remote upstream refs/heads/main | awk '{print $1}')
  expected_local_main=$(git rev-parse main)
  run_prepare_with_local_remotes >/dev/null
  upstream_sha=$(git rev-parse upstream/main)
  git merge-base --is-ancestor "$upstream_sha" HEAD
  [ "$(git branch --show-current)" = "integrate/upstream-$(date -u +%Y%m%d)-$(git rev-parse --short=12 "$upstream_sha")" ]
  set -- $(git rev-list --parents -n 1 HEAD)
  [ "$#" = 3 ]
  [ "$2" = "$expected_origin_sha" ]
  [ "$3" = "$expected_upstream_sha" ]
  [ "$(git rev-parse main)" = "$expected_local_main" ]
  [ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$expected_origin_sha" ]
) || fail "the full synchronization flow must create a merge integration branch at the fetched upstream SHA"

# Simulate another process moving the remote-tracking ref after the script has
# captured its immutable SHA. The merge must still use the captured commit.
moving_ref_work=$(create_sync_fixture moving-ref merge)
git -C "$moving_ref_work" fetch -q upstream main
moving_ref_expected_sha=$(git -C "$moving_ref_work" rev-parse upstream/main)
git -C "$moving_ref_work" switch -q --detach "$moving_ref_expected_sha"
printf 'future upstream\n' > "$moving_ref_work/future.txt"
git -C "$moving_ref_work" add future.txt
git -C "$moving_ref_work" commit -q -m future-upstream
moving_ref_future_sha=$(git -C "$moving_ref_work" rev-parse HEAD)
git -C "$moving_ref_work" update-ref refs/test/future-upstream "$moving_ref_future_sha"
git -C "$moving_ref_work" switch -q main
git -C "$moving_ref_work" update-ref -d refs/remotes/upstream/main

moving_ref_bin="$task_test_dir/moving-ref-bin"
mkdir -p "$moving_ref_bin"
real_git=$(command -v git)
cat > "$moving_ref_bin/git" <<'MOVING_REF_GIT'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = rev-parse ] && [ "${2:-}" = --short=12 ] && [ "${3:-}" = "$WORLD_APP_TEST_CAPTURED_UPSTREAM_SHA" ]; then
  "$WORLD_APP_TEST_REAL_GIT" "$@"
  "$WORLD_APP_TEST_REAL_GIT" update-ref refs/remotes/upstream/main "$WORLD_APP_TEST_FUTURE_UPSTREAM_SHA"
  exit 0
fi
exec "$WORLD_APP_TEST_REAL_GIT" "$@"
MOVING_REF_GIT
chmod +x "$moving_ref_bin/git"
(
  cd "$moving_ref_work"
  export WORLD_APP_TEST_REAL_GIT="$real_git"
  export WORLD_APP_TEST_CAPTURED_UPSTREAM_SHA="$moving_ref_expected_sha"
  export WORLD_APP_TEST_FUTURE_UPSTREAM_SHA="$moving_ref_future_sha"
  PATH="$moving_ref_bin:$PATH" run_prepare_with_local_remotes >/dev/null
  set -- $("$real_git" rev-list --parents -n 1 HEAD)
  [ "$#" = 3 ]
  [ "$3" = "$moving_ref_expected_sha" ]
  [ "$("$real_git" rev-parse upstream/main)" = "$moving_ref_future_sha" ]
) || fail "synchronization must merge the captured upstream SHA even if the tracking ref moves"

wrong_remote_work=$(create_sync_fixture wrong-remote merge)
git -C "$wrong_remote_work" config remote.upstream.url https://github.com/waonme/world-app.git
if (
  cd "$wrong_remote_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject an upstream remote pointing at the fork"
fi

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
conflict_main_sha=$(git -C "$conflict_work" rev-parse main)
conflict_origin_sha=$(git -C "$conflict_work" ls-remote origin refs/heads/main | awk '{print $1}')
conflict_output="$task_test_dir/conflict-output"
if (
  cd "$conflict_work"
  run_prepare_with_local_remotes
) >"$conflict_output" 2>&1; then
  fail "an unresolved semantic merge conflict must not report success"
fi
if [ -z "$(git -C "$conflict_work" ls-files -u)" ]; then
  fail "the conflict fixture must leave explicit unmerged entries for review"
fi
grep -Fq "resolve conflicts using FORK.md" "$conflict_output" || fail "the conflict flow must direct the maintainer to the fork contract"
case "$(git -C "$conflict_work" branch --show-current)" in
  integrate/upstream-*) ;;
  *) fail "conflicts must remain on an integration branch" ;;
esac
[ "$(git -C "$conflict_work" rev-parse main)" = "$conflict_main_sha" ] || fail "a conflict must not move local main"
[ "$(git -C "$conflict_work" ls-remote origin refs/heads/main | awk '{print $1}')" = "$conflict_origin_sha" ] || fail "a conflict must not move origin/main"

echo "upstream remote provenance and synchronization workflow tests passed"

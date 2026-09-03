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

test_real_git=$(command -v git)
transport_bin="$task_test_dir/transport-bin"
mkdir -p "$transport_bin"
cat > "$transport_bin/git" <<'FAKE_GIT_TRANSPORT'
#!/usr/bin/env bash
set -Eeuo pipefail

original_arguments=("$@")
if [ "${1:-}" = -c ] && [ "${2:-}" = core.attributesFile=/dev/null ] &&
  [ "${3:-}" = -c ] && [ "${4:-}" = core.commitGraph=false ] &&
  [ "${5:-}" = -c ] && [ "${6:-}" = core.fsmonitor=false ] &&
  [ "${7:-}" = -c ] && [ "${8:-}" = core.hooksPath=/dev/null ]; then
  shift 8
else
  echo "trusted Git prefix is missing" >&2
  exit 3
fi

if [ "${1:-}" = -c ] && [ "${2:-}" = protocol.file.allow=never ] &&
  [ "${3:-}" = fetch ] && [ "${4:-}" = --no-tags ] &&
  [ "${5:-}" = --no-recurse-submodules ] && [ "${6:-}" = --prune ]; then
  [ "${GIT_CONFIG_NOSYSTEM:-}" = 1 ] || { echo "system Git config was not disabled" >&2; exit 3; }
  [ "${GIT_ATTR_NOSYSTEM:-}" = 1 ] || { echo "system Git attributes were not disabled" >&2; exit 3; }
  [ "${GIT_CONFIG_GLOBAL:-}" = /dev/null ] || { echo "global Git config was not disabled" >&2; exit 3; }
  [ "${GIT_TERMINAL_PROMPT:-}" = 0 ] || { echo "interactive Git prompting was not disabled" >&2; exit 3; }
  [ -z "${GIT_CONFIG_COUNT+x}" ] || { echo "command Git config count was not removed" >&2; exit 3; }
  [ -z "${GIT_CONFIG_PARAMETERS+x}" ] || { echo "command Git config parameters were not removed" >&2; exit 3; }
  [ -z "${GIT_CONFIG+x}" ] || { echo "legacy Git config override was not removed" >&2; exit 3; }
  [ -z "${GIT_ATTR_SOURCE+x}" ] || { echo "Git attribute source override was not removed" >&2; exit 3; }
  [ "${GIT_NO_REPLACE_OBJECTS:-}" = 1 ] || { echo "replacement objects were not disabled" >&2; exit 3; }
  [ "${GIT_NO_LAZY_FETCH:-}" = 1 ] || { echo "lazy object fetching was not disabled" >&2; exit 3; }
  [ -z "${GIT_REPLACE_REF_BASE+x}" ] || { echo "replacement ref base was not removed" >&2; exit 3; }
  [ -z "${GIT_OBJECT_DIRECTORY+x}" ] || { echo "object directory override was not removed" >&2; exit 3; }
  [ -z "${GIT_ALTERNATE_OBJECT_DIRECTORIES+x}" ] || { echo "alternate object directory override was not removed" >&2; exit 3; }
  [ "${GIT_GRAFT_FILE:-}" = /dev/null/world-app-disabled ] || { echo "graft file override was not neutralized" >&2; exit 3; }
  [ "${GIT_SHALLOW_FILE:-}" = /dev/null/world-app-disabled ] || { echo "shallow file override was not neutralized" >&2; exit 3; }
  [ -z "${GIT_SSL_NO_VERIFY+x}" ] || { echo "TLS verification override was not removed" >&2; exit 3; }
  [ -z "${GIT_SSL_CAINFO+x}" ] || { echo "TLS CA override was not removed" >&2; exit 3; }
  [ -z "${HTTPS_PROXY+x}" ] || { echo "HTTPS proxy override was not removed" >&2; exit 3; }
  [ -z "${https_proxy+x}" ] || { echo "lowercase HTTPS proxy override was not removed" >&2; exit 3; }
  [ -z "${CURL_CA_BUNDLE+x}" ] || { echo "curl CA override was not removed" >&2; exit 3; }
  case "${7:-}" in
    https://github.com/waonme/world-app.git) transport_repository=$WORLD_APP_TEST_ORIGIN_REPOSITORY ;;
    https://github.com/concrnt/world-app.git) transport_repository=$WORLD_APP_TEST_UPSTREAM_REPOSITORY ;;
    *) echo "unexpected canonical fetch URL: ${7:-<missing>}" >&2; exit 2 ;;
  esac
  exec "$WORLD_APP_TEST_REAL_GIT" -c protocol.file.allow=always fetch --no-tags --prune \
    "$transport_repository" "${8:?missing fetch refspec}"
fi

if [ -n "${WORLD_APP_TEST_CAPTURED_UPSTREAM_SHA:-}" ] &&
  [ "${1:-}" = rev-parse ] && [ "${2:-}" = --short=12 ] &&
  [ "${3:-}" = "$WORLD_APP_TEST_CAPTURED_UPSTREAM_SHA" ]; then
  "$WORLD_APP_TEST_REAL_GIT" "${original_arguments[@]}"
  "$WORLD_APP_TEST_REAL_GIT" update-ref refs/remotes/upstream/main "$WORLD_APP_TEST_FUTURE_UPSTREAM_SHA"
  exit 0
fi

if [ "${1:-}" = -c ] && [ "${2:-}" = commit.gpgSign=false ] &&
  [ "${3:-}" = -c ] && [ "${4:-}" = merge.autoStash=false ] &&
  [ "${5:-}" = -c ] && [ "${6:-}" = merge.renormalize=false ] &&
  [ "${7:-}" = -c ] && [ "${8:-}" = rerere.enabled=false ] &&
  [ "${9:-}" = -c ] && [ "${10:-}" = rerere.autoupdate=false ] &&
  [ "${11:-}" = merge ] && [ "${12:-}" = --no-ff ]; then
  if [[ ! "${GIT_ATTR_SOURCE:-}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "merge attributes were not pinned to the captured fork commit" >&2
    exit 3
  fi
fi

if [ -n "${GIT_CONFIG_PARAMETERS+x}" ]; then
  exec env -u GIT_CONFIG_PARAMETERS "$WORLD_APP_TEST_REAL_GIT" "${original_arguments[@]}"
fi
exec "$WORLD_APP_TEST_REAL_GIT" "${original_arguments[@]}"
FAKE_GIT_TRANSPORT
chmod +x "$transport_bin/git"

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
  git -C "$work_repository" config worldAppTest.originRepository "$origin_repository"
  git -C "$work_repository" config worldAppTest.upstreamRepository "$upstream_repository"
  git -C "$work_repository" config user.email test@example.invalid
  git -C "$work_repository" config user.name "World App Sync Test"
  printf '%s\n' "$work_repository"
}

run_prepare_with_local_remotes() (
  export WORLD_APP_TEST_REAL_GIT="$test_real_git"
  export WORLD_APP_TEST_ORIGIN_REPOSITORY
  export WORLD_APP_TEST_UPSTREAM_REPOSITORY
  WORLD_APP_TEST_ORIGIN_REPOSITORY=$(env -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_ATTR_SOURCE -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_SYSTEM -u GIT_OBJECT_DIRECTORY -u GIT_REPLACE_REF_BASE \
    "$test_real_git" config --local --get worldAppTest.originRepository)
  WORLD_APP_TEST_UPSTREAM_REPOSITORY=$(env -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_ATTR_SOURCE -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_SYSTEM -u GIT_OBJECT_DIRECTORY -u GIT_REPLACE_REF_BASE \
    "$test_real_git" config --local --get worldAppTest.upstreamRepository)
  PATH="$transport_bin:$PATH"
  export PATH
  prepare_upstream_sync
)

fixture_main_sha() {
  local work_repository=$1
  local remote_name=$2
  local repository_path
  repository_path=$(git -C "$work_repository" config --local --get "worldAppTest.${remote_name}Repository")
  git --git-dir="$repository_path" rev-parse refs/heads/main
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
  expected_origin_sha=$(fixture_main_sha "$success_work" origin)
  expected_upstream_sha=$(fixture_main_sha "$success_work" upstream)
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
  [ "$(fixture_main_sha "$success_work" origin)" = "$expected_origin_sha" ]
) || fail "the full synchronization flow must create a merge integration branch at the fetched upstream SHA"

config_isolation_work=$(create_sync_fixture config-isolation merge)
hostile_global_config="$task_test_dir/config-isolation/hostile-global.gitconfig"
hostile_system_config="$task_test_dir/config-isolation/hostile-system.gitconfig"
git config --file "$hostile_global_config" \
  url.https://global-lookalike.invalid/.insteadOf https://github.com/
git config --file "$hostile_system_config" \
  url.https://system-lookalike.invalid/.insteadOf https://github.com/
(
  cd "$config_isolation_work"
  export GIT_CONFIG_NOSYSTEM=0
  export GIT_CONFIG_SYSTEM="$hostile_system_config"
  export GIT_CONFIG_GLOBAL="$hostile_global_config"
  export GIT_TERMINAL_PROMPT=1
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=http.extraHeader
  export GIT_CONFIG_VALUE_0='Authorization: hostile-command-config'
  export GIT_CONFIG_PARAMETERS=hostile
  export GIT_CONFIG="$task_test_dir/config-isolation/hostile-config"
  export GIT_ATTR_SOURCE=hostile-attribute-tree
  export GIT_REPLACE_REF_BASE=refs/hostile-replacements
  export GIT_GRAFT_FILE="$task_test_dir/config-isolation/hostile-grafts"
  export GIT_SHALLOW_FILE="$task_test_dir/config-isolation/hostile-shallow"
  export GIT_OBJECT_DIRECTORY="$task_test_dir/config-isolation/hostile-objects"
  export GIT_ALTERNATE_OBJECT_DIRECTORIES="$task_test_dir/config-isolation/hostile-alternates"
  export GIT_SSL_NO_VERIFY=1
  export GIT_SSL_CAINFO="$task_test_dir/config-isolation/hostile-ca.pem"
  export HTTPS_PROXY=http://127.0.0.1:9
  export https_proxy=http://127.0.0.1:9
  export CURL_CA_BUNDLE="$task_test_dir/config-isolation/hostile-curl-ca.pem"
  run_prepare_with_local_remotes >/dev/null
) || fail "canonical synchronization fetches must isolate hostile system, global, and command Git config"

# An ignored, untracked attributes file can otherwise select a local merge
# driver while status still reports a clean worktree. Reject executable merge
# policy in local config before branch creation.
merge_driver_work=$(create_sync_fixture merge-driver conflict)
merge_driver_head=$(git -C "$merge_driver_work" rev-parse HEAD)
printf '/.gitattributes\n' >> "$merge_driver_work/.git/info/exclude"
printf 'shared.txt merge=owned\n' > "$merge_driver_work/.gitattributes"
git -C "$merge_driver_work" config merge.owned.driver \
  'printf "substituted-by-local-driver\n" > %A'
[ -z "$(git -C "$merge_driver_work" status --porcelain)" ] || \
  fail "merge-driver attack fixture must be hidden from normal status"
if (
  cd "$merge_driver_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the synchronization flow must reject repository-local merge drivers"
fi
[ "$(git -C "$merge_driver_work" rev-parse HEAD)" = "$merge_driver_head" ] || \
  fail "a rejected local merge driver must not create an integration commit"
[ "$(git -C "$merge_driver_work" branch --show-current)" = main ] || \
  fail "a rejected local merge driver must not leave main"

# Even without local config, Git's built-in union driver could be selected by
# an ignored worktree .gitattributes. Pinning GIT_ATTR_SOURCE to captured main
# must make the genuine conflict remain explicit for review.
ignored_attributes_work=$(create_sync_fixture ignored-attributes conflict)
printf '/.gitattributes\n' >> "$ignored_attributes_work/.git/info/exclude"
printf 'shared.txt merge=union\n' > "$ignored_attributes_work/.gitattributes"
[ -z "$(git -C "$ignored_attributes_work" status --porcelain)" ] || \
  fail "ignored-attributes fixture must be hidden from normal status"
if (
  cd "$ignored_attributes_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "ignored worktree attributes must not silently resolve an upstream conflict"
fi
[ -n "$(git -C "$ignored_attributes_work" ls-files -u)" ] || \
  fail "canonical attributes must leave the held-out semantic conflict unresolved"

global_attributes_work=$(create_sync_fixture global-attributes conflict)
global_attributes_home="$task_test_dir/global-attributes/xdg"
mkdir -p "$global_attributes_home/git"
printf 'shared.txt merge=union\n' > "$global_attributes_home/git/attributes"
if (
  cd "$global_attributes_work"
  export XDG_CONFIG_HOME="$global_attributes_home"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "user-global attributes must not silently resolve an upstream conflict"
fi
[ -n "$(git -C "$global_attributes_work" ls-files -u)" ] || \
  fail "disabling global attributes must leave the held-out semantic conflict unresolved"

# Index flags can hide modified tracked content from status. Refuse both flag
# classes before any integration branch is created.
assume_unchanged_work=$(create_sync_fixture assume-unchanged merge)
assume_unchanged_head=$(git -C "$assume_unchanged_work" rev-parse HEAD)
git -C "$assume_unchanged_work" update-index --assume-unchanged shared.txt
printf 'hidden tracked mutation\n' > "$assume_unchanged_work/shared.txt"
[ -z "$(git -C "$assume_unchanged_work" status --porcelain)" ] || \
  fail "assume-unchanged fixture must be hidden from normal status"
if (
  cd "$assume_unchanged_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "assume-unchanged index state must be rejected"
fi
[ "$(git -C "$assume_unchanged_work" rev-parse HEAD)" = "$assume_unchanged_head" ] || \
  fail "rejected assume-unchanged state must not move HEAD"

skip_worktree_work=$(create_sync_fixture skip-worktree merge)
skip_worktree_head=$(git -C "$skip_worktree_work" rev-parse HEAD)
git -C "$skip_worktree_work" update-index --skip-worktree shared.txt
if (
  cd "$skip_worktree_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "skip-worktree index state must be rejected"
fi
[ "$(git -C "$skip_worktree_work" rev-parse HEAD)" = "$skip_worktree_head" ] || \
  fail "rejected skip-worktree state must not move HEAD"

# Simulate another process moving the remote-tracking ref after the script has
# captured its immutable SHA. The merge must still use the captured commit.
moving_ref_work=$(create_sync_fixture moving-ref merge)
moving_ref_upstream_repository=$(git -C "$moving_ref_work" config --local --get worldAppTest.upstreamRepository)
git -C "$moving_ref_work" -c protocol.file.allow=always fetch -q "$moving_ref_upstream_repository" \
  +refs/heads/main:refs/remotes/upstream/main
moving_ref_expected_sha=$(git -C "$moving_ref_work" rev-parse upstream/main)
git -C "$moving_ref_work" switch -q --detach "$moving_ref_expected_sha"
printf 'future upstream\n' > "$moving_ref_work/future.txt"
git -C "$moving_ref_work" add future.txt
git -C "$moving_ref_work" commit -q -m future-upstream
moving_ref_future_sha=$(git -C "$moving_ref_work" rev-parse HEAD)
git -C "$moving_ref_work" update-ref refs/test/future-upstream "$moving_ref_future_sha"
git -C "$moving_ref_work" switch -q main
git -C "$moving_ref_work" update-ref -d refs/remotes/upstream/main

(
  cd "$moving_ref_work"
  export WORLD_APP_TEST_CAPTURED_UPSTREAM_SHA="$moving_ref_expected_sha"
  export WORLD_APP_TEST_FUTURE_UPSTREAM_SHA="$moving_ref_future_sha"
  run_prepare_with_local_remotes >/dev/null
  set -- $("$test_real_git" rev-list --parents -n 1 HEAD)
  [ "$#" = 3 ]
  [ "$3" = "$moving_ref_expected_sha" ]
  [ "$("$test_real_git" rev-parse upstream/main)" = "$moving_ref_future_sha" ]
) || fail "synchronization must merge the captured upstream SHA even if the tracking ref moves"

wrong_remote_work=$(create_sync_fixture wrong-remote merge)
git -C "$wrong_remote_work" config remote.upstream.url https://github.com/waonme/world-app.git
if (
  cd "$wrong_remote_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject an upstream remote pointing at the fork"
fi

core_worktree_work=$(create_sync_fixture core-worktree-redirect merge)
core_worktree_git_dir="$core_worktree_work/.git"
core_worktree_decoy="$task_test_dir/core-worktree-redirect/decoy"
mkdir -p "$core_worktree_decoy"
core_worktree_decoy=$(cd "$core_worktree_decoy" && pwd -P)
core_worktree_head=$(git --git-dir="$core_worktree_git_dir" rev-parse HEAD)
git --git-dir="$core_worktree_git_dir" config core.worktree "$core_worktree_decoy"
[ "$(git -C "$core_worktree_work" rev-parse --show-toplevel)" = "$core_worktree_decoy" ] || \
  fail "core.worktree attack fixture did not redirect Git's reported repository root"
if (
  cd "$core_worktree_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "core.worktree must be rejected before repository-root discovery"
fi
[ "$(git --git-dir="$core_worktree_git_dir" rev-parse HEAD)" = "$core_worktree_head" ] || \
  fail "a rejected core.worktree redirect must not move HEAD"
[ "$(git --git-dir="$core_worktree_git_dir" symbolic-ref --short HEAD)" = main ] || \
  fail "a rejected core.worktree redirect must not leave main"

http_policy_work=$(create_sync_fixture http-transport-policy merge)
http_policy_head=$(git -C "$http_policy_work" rev-parse HEAD)
http_policy_refs=$(git -C "$http_policy_work" for-each-ref \
  --format='%(refname):%(objectname)' refs/heads/ refs/remotes/)
git -C "$http_policy_work" config http.sslVerify false
git -C "$http_policy_work" config --add http.curloptResolve \
  '+github.com:443:127.0.0.1'
if (
  cd "$http_policy_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "repository-local HTTP/TLS transport policy must be rejected before fetch"
fi
[ "$(git -C "$http_policy_work" rev-parse HEAD)" = "$http_policy_head" ] || \
  fail "rejected HTTP transport policy must not move HEAD"
[ "$(git -C "$http_policy_work" branch --show-current)" = main ] || \
  fail "rejected HTTP transport policy must not leave main"
[ "$(git -C "$http_policy_work" for-each-ref --format='%(refname):%(objectname)' refs/heads/ refs/remotes/)" = "$http_policy_refs" ] || \
  fail "rejected HTTP transport policy must not update local refs"

diff_policy_work=$(create_sync_fixture diff-merge-policy merge)
diff_policy_head=$(git -C "$diff_policy_work" rev-parse HEAD)
git -C "$diff_policy_work" config diff.renameLimit 0
if (
  cd "$diff_policy_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "repository-local diff policy that can affect merge results must be rejected"
fi
[ "$(git -C "$diff_policy_work" rev-parse HEAD)" = "$diff_policy_head" ] || \
  fail "rejected diff merge policy must not move HEAD"
[ "$(git -C "$diff_policy_work" branch --show-current)" = main ] || \
  fail "rejected diff merge policy must not leave main"

rewrite_work=$(create_sync_fixture url-rewrite merge)
rewrite_origin_repository=$(git -C "$rewrite_work" config --local --get worldAppTest.originRepository)
git -C "$rewrite_work" config "url.file://$rewrite_origin_repository.insteadOf" https://github.com/concrnt/world-app.git
if (
  cd "$rewrite_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject local Git URL rewrite rules"
fi

include_work=$(create_sync_fixture included-url-rewrite merge)
include_config="$task_test_dir/included-url-rewrite/hostile-include.gitconfig"
git config --file "$include_config" \
  url.https://included-lookalike.invalid/.insteadOf https://github.com/
git -C "$include_work" config include.path "$include_config"
if (
  cd "$include_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject include.path before an included URL rewrite can apply"
fi
git -C "$include_work" config --unset include.path
git -C "$include_work" config \
  "includeIf.gitdir:$include_work/.path" "$include_config"
if (
  cd "$include_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject includeIf before a conditional URL rewrite can apply"
fi

object_indirection_work=$(create_sync_fixture object-indirection merge)
object_indirection_main=$(git -C "$object_indirection_work" rev-parse main)
object_indirection_branch=$(git -C "$object_indirection_work" branch --show-current)
git -C "$object_indirection_work" switch -q --orphan replacement-object
printf 'substituted\n' > "$object_indirection_work/shared.txt"
git -C "$object_indirection_work" add shared.txt
git -C "$object_indirection_work" commit -q -m replacement-object
object_indirection_substitute=$(git -C "$object_indirection_work" rev-parse HEAD)
git -C "$object_indirection_work" switch -q "$object_indirection_branch"
git -C "$object_indirection_work" replace "$object_indirection_main" "$object_indirection_substitute"
[ "$(git -C "$object_indirection_work" show main:shared.txt)" = substituted ] || \
  fail "replacement attack fixture did not substitute the canonical tree"
if (
  cd "$object_indirection_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject Git replacement refs"
fi
[ "$(git -C "$object_indirection_work" rev-parse main)" = "$object_indirection_main" ] || \
  fail "rejected replacement refs must not move local main"
git -C "$object_indirection_work" replace -d "$object_indirection_main" >/dev/null

object_indirection_git_dir=$(git -C "$object_indirection_work" rev-parse --git-common-dir)
case "$object_indirection_git_dir" in
  /*) ;;
  *) object_indirection_git_dir="$object_indirection_work/$object_indirection_git_dir" ;;
esac
mkdir -p "$object_indirection_git_dir/info" "$object_indirection_git_dir/objects/info"
printf '%s\n' "$object_indirection_main" > "$object_indirection_git_dir/info/grafts"
if (
  cd "$object_indirection_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject info/grafts ancestry rewriting"
fi
rm -f "$object_indirection_git_dir/info/grafts"
mkfifo "$object_indirection_git_dir/info/grafts"
if (
  cd "$object_indirection_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject a FIFO graft source"
fi
rm -f "$object_indirection_git_dir/info/grafts"
printf '%s\n' "$object_indirection_main" > "$object_indirection_git_dir/shallow"
if (
  cd "$object_indirection_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject shallow ancestry"
fi
rm -f "$object_indirection_git_dir/shallow"

git -C "$object_indirection_work" config core.attributesFile /tmp/hostile-sync-attributes
git -C "$object_indirection_work" config filter.evil.clean cat
if (
  cd "$object_indirection_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject local clean/smudge filter config"
fi
git -C "$object_indirection_work" config --unset core.attributesFile
git -C "$object_indirection_work" config --remove-section filter.evil

git -C "$object_indirection_work" config extensions.worktreeConfig true
printf '[url "https://lookalike.invalid/"]\n\tinsteadOf = https://github.com/\n' > \
  "$object_indirection_git_dir/config.worktree"
if (
  cd "$object_indirection_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject worktree-scope config"
fi
rm -f "$object_indirection_git_dir/config.worktree"
git -C "$object_indirection_work" config --unset extensions.worktreeConfig

git -C "$object_indirection_work" config fsck.missingEmail ignore
if (
  cd "$object_indirection_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "the complete synchronization flow must reject local fsck policy overrides"
fi
git -C "$object_indirection_work" config --unset fsck.missingEmail

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

behind_work=$(create_sync_fixture local-behind merge)
behind_origin_repository=$(git -C "$behind_work" config --local --get worldAppTest.originRepository)
behind_advancer="$task_test_dir/local-behind/advancer"
git clone -q "$behind_origin_repository" "$behind_advancer"
git -C "$behind_advancer" config user.email test@example.invalid
git -C "$behind_advancer" config user.name "World App Sync Test"
printf 'remote-only\n' > "$behind_advancer/remote.txt"
git -C "$behind_advancer" add remote.txt
git -C "$behind_advancer" commit -q -m remote-only
git -C "$behind_advancer" push -q origin main
behind_local_sha=$(git -C "$behind_work" rev-parse main)
if (
  cd "$behind_work"
  run_prepare_with_local_remotes
) >/dev/null 2>&1; then
  fail "local main behind origin/main must be rejected instead of being fast-forwarded"
fi
[ "$(git -C "$behind_work" rev-parse main)" = "$behind_local_sha" ] || fail "a rejected behind main must remain unchanged"

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
conflict_origin_sha=$(fixture_main_sha "$conflict_work" origin)
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
[ "$(fixture_main_sha "$conflict_work" origin)" = "$conflict_origin_sha" ] || fail "a conflict must not move origin/main"

echo "upstream remote provenance and synchronization workflow tests passed"

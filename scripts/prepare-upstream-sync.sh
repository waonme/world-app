#!/usr/bin/env bash

set -Eeuo pipefail

forbidden_local_config_pattern='^(include\.path|includeif\..*\.path|extensions\.(partialclone|worktreeconfig)|remote\..*\.(promisor|proxy|proxyauthmethod)|http\..*|core\.(attributesfile|worktree|sparsecheckout|sparsecheckoutcone|ignorestat)|index\.sparse|filter\..*|diff\..*|merge\..*|rerere\..*|branch\..*\.mergeoptions|fsck\..*|fetch\.fsckobjects|receive\.fsck\..*|transfer\.fsckobjects)$'

run_trusted_git_internal() {
  local attribute_source=$1
  shift
  local -a attribute_source_environment=(-u GIT_ATTR_SOURCE)
  if [ -n "$attribute_source" ]; then
    attribute_source_environment=(-u GIT_ATTR_SOURCE "GIT_ATTR_SOURCE=$attribute_source")
  fi

  env -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_PROXY_COMMAND \
    -u GIT_SSL_CAINFO \
    -u GIT_SSL_CAPATH \
    -u GIT_SSL_NO_VERIFY \
    -u GIT_COMMON_DIR \
    -u GIT_CONFIG \
    -u GIT_CONFIG_COUNT \
    -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_SYSTEM \
    -u GIT_DIR \
    -u GIT_EXEC_PATH \
    -u GIT_GRAFT_FILE \
    -u GIT_INDEX_FILE \
    -u GIT_NAMESPACE \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_REPLACE_REF_BASE \
    -u GIT_SHALLOW_FILE \
    -u GIT_TEMPLATE_DIR \
    -u GIT_WORK_TREE \
    -u ALL_PROXY \
    -u HTTPS_PROXY \
    -u HTTP_PROXY \
    -u NO_PROXY \
    -u all_proxy \
    -u https_proxy \
    -u http_proxy \
    -u no_proxy \
    -u CURL_CA_BUNDLE \
    -u SSL_CERT_DIR \
    -u SSL_CERT_FILE \
    "${attribute_source_environment[@]}" \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_GRAFT_FILE=/dev/null/world-app-disabled \
    GIT_NO_LAZY_FETCH=1 \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_SHALLOW_FILE=/dev/null/world-app-disabled \
    GIT_TERMINAL_PROMPT=0 \
    git -c core.attributesFile=/dev/null -c core.commitGraph=false \
      -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

run_trusted_git() {
  run_trusted_git_internal "" "$@"
}

run_trusted_merge_git() {
  local attribute_source=$1
  shift

  run_trusted_git_internal "$attribute_source" \
    -c commit.gpgSign=false \
    -c merge.autoStash=false \
    -c merge.renormalize=false \
    -c rerere.enabled=false \
    -c rerere.autoupdate=false \
    "$@"
}

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

  if ! remote_url=$(run_trusted_git config --local --no-includes --get "remote.$remote_name.url" 2>/dev/null); then
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

  if rewrite_config=$(run_trusted_git config --local --no-includes --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null); then
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

require_safe_invocation_config() {
  local dangerous_config
  local config_status

  if dangerous_config=$(run_trusted_git config --local --no-includes --get-regexp \
    "$forbidden_local_config_pattern" 2>/dev/null); then
    echo "local Git config cannot redirect or customize upstream synchronization:" >&2
    printf '%s\n' "$dangerous_config" >&2
    return 1
  else
    config_status=$?
  fi
  if [ "$config_status" -ne 1 ]; then
    echo "failed to inspect invocation repository Git config" >&2
    return 1
  fi
}

require_no_local_object_indirection() {
  local repository_root=$1
  local common_git_dir
  local worktree_git_dir
  local replacement_refs
  local dangerous_config
  local config_status
  local forbidden_path

  common_git_dir=$(run_trusted_git rev-parse --git-common-dir) || return 1
  case "$common_git_dir" in
    /*) ;;
    *) common_git_dir="$repository_root/$common_git_dir" ;;
  esac

  worktree_git_dir=$(run_trusted_git rev-parse --git-dir) || return 1
  case "$worktree_git_dir" in
    /*) ;;
    *) worktree_git_dir="$repository_root/$worktree_git_dir" ;;
  esac

  for forbidden_path in \
    "$common_git_dir/config.worktree" \
    "$worktree_git_dir/config.worktree" \
    "$common_git_dir/info/grafts" \
    "$common_git_dir/info/attributes" \
    "$worktree_git_dir/info/attributes" \
    "$common_git_dir/info/sparse-checkout" \
    "$worktree_git_dir/info/sparse-checkout" \
    "$common_git_dir/shallow" \
    "$common_git_dir/objects/info/alternates" \
    "$common_git_dir/objects/info/http-alternates"; do
    if [ -e "$forbidden_path" ] || [ -L "$forbidden_path" ]; then
      echo "local Git object/worktree indirection is not allowed during upstream synchronization: $forbidden_path" >&2
      return 1
    fi
  done

  replacement_refs=$(run_trusted_git for-each-ref --format='%(refname)' refs/replace/) || return 1
  if [ -n "$replacement_refs" ]; then
    echo "local Git replacement refs are not allowed during upstream synchronization:" >&2
    printf '%s\n' "$replacement_refs" >&2
    return 1
  fi

  if dangerous_config=$(run_trusted_git config --local --no-includes --get-regexp \
    "$forbidden_local_config_pattern" 2>/dev/null); then
    echo "local Git config indirection is not allowed during upstream synchronization:" >&2
    printf '%s\n' "$dangerous_config" >&2
    return 1
  else
    config_status=$?
  fi
  if [ "$config_status" -ne 1 ]; then
    echo "failed to inspect local Git object indirection config" >&2
    return 1
  fi
}

require_no_hidden_index_entries() {
  local index_listing
  local index_entry
  local index_marker

  index_listing=$(mktemp "${TMPDIR:-/tmp}/world-app-index.XXXXXXXX") || return 1
  if ! run_trusted_git ls-files -v -z > "$index_listing"; then
    rm -f -- "$index_listing"
    return 1
  fi

  while IFS= read -r -d '' index_entry; do
    index_marker=${index_entry:0:1}
    case "$index_marker" in
      [a-z] | S)
        echo "assume-unchanged/skip-worktree index state is not allowed during upstream synchronization: ${index_entry:2}" >&2
        rm -f -- "$index_listing"
        return 1
        ;;
    esac
  done < "$index_listing"
  rm -f -- "$index_listing"
}

require_direct_ref() {
  local reference=$1
  local description=$2
  local symbolic_target
  local symbolic_status

  if symbolic_target=$(run_trusted_git symbolic-ref --quiet --no-recurse "$reference" 2>/dev/null); then
    echo "$description must be a direct ref, not a symbolic ref to $symbolic_target" >&2
    return 1
  else
    symbolic_status=$?
  fi
  if [ "$symbolic_status" -ne 1 ]; then
    echo "failed to inspect whether $description is symbolic" >&2
    return 1
  fi
}

require_ref_path_without_symlinks() {
  local reference=$1
  local description=$2
  local common_git_dir
  local relative_path
  local current_path
  local component
  local saved_ifs

  common_git_dir=$(run_trusted_git rev-parse --path-format=absolute --git-common-dir) || return 1
  if ! run_trusted_git check-ref-format "$reference"; then
    echo "$description has an invalid ref name: $reference" >&2
    return 1
  fi
  relative_path=$reference
  current_path=$common_git_dir
  saved_ifs=$IFS
  IFS=/
  for component in $relative_path; do
    current_path="$current_path/$component"
    if [ -L "$current_path" ]; then
      IFS=$saved_ifs
      echo "$description uses a symbolic filesystem path: $current_path" >&2
      return 1
    fi
  done
  IFS=$saved_ifs
}

snapshot_refs_except() {
  local excluded_reference=$1
  local refs
  local ref_line

  refs=$(run_trusted_git for-each-ref --format='%(refname):%(objectname):%(symref)') || return 1
  while IFS= read -r ref_line; do
    [ -n "$ref_line" ] || continue
    case "$ref_line" in
      "$excluded_reference":*) ;;
      *) printf '%s\n' "$ref_line" ;;
    esac
  done <<EOF_REFS
$refs
EOF_REFS
}

require_checked_out_main() {
  local head_target
  local head_sha
  local main_sha

  if ! head_target=$(run_trusted_git symbolic-ref --quiet --no-recurse HEAD); then
    echo "upstream synchronization requires a symbolic HEAD at refs/heads/main" >&2
    return 1
  fi
  if [ "$head_target" != refs/heads/main ]; then
    echo "run this script from local main (current ref: $head_target)" >&2
    return 1
  fi
  require_direct_ref refs/heads/main "local main" || return 1
  require_ref_path_without_symlinks refs/heads/main "local main" || return 1
  head_sha=$(run_trusted_git rev-parse 'HEAD^{commit}') || return 1
  main_sha=$(run_trusted_git rev-parse 'refs/heads/main^{commit}') || return 1
  if [ "$head_sha" != "$main_sha" ]; then
    echo "HEAD and refs/heads/main do not resolve to the same commit" >&2
    return 1
  fi
}

require_git_attribute_source_support() {
  local captured_main=$1
  local impossible_source=refs/world-app/attribute-source-probe-must-not-exist

  if ! run_trusted_git_internal "$captured_main" check-attr --all -- . >/dev/null; then
    echo "installed Git cannot read attributes from the captured main tree" >&2
    return 1
  fi
  if run_trusted_git show-ref --verify --quiet "$impossible_source"; then
    echo "reserved Git attribute-source probe ref already exists: $impossible_source" >&2
    return 1
  fi
  if run_trusted_git_internal "$impossible_source" check-attr --all -- . >/dev/null 2>&1; then
    echo "installed Git does not enforce GIT_ATTR_SOURCE; refusing an unpinned merge" >&2
    return 1
  fi
}

fetch_canonical_main() {
  local remote_name=$1
  local canonical_url=$2
  local destination_ref
  local head_target
  local head_sha
  local refs_before
  local fetch_status=0
  local head_target_after
  local head_sha_after
  local refs_after

  case "$remote_name" in
    origin | upstream) ;;
    *)
      echo "unsupported canonical fetch destination: $remote_name" >&2
      return 1
      ;;
  esac
  destination_ref="refs/remotes/$remote_name/main"

  require_no_local_url_rewrites || return
  require_direct_ref "$destination_ref" "$remote_name/main fetch destination" || return
  require_ref_path_without_symlinks "$destination_ref" "$remote_name/main fetch destination" || return
  if ! head_target=$(run_trusted_git symbolic-ref --quiet --no-recurse HEAD); then
    echo "canonical fetch requires a checked-out direct branch" >&2
    return 1
  fi
  if [ "$head_target" = "$destination_ref" ]; then
    echo "canonical fetch destination must not be the checked-out branch" >&2
    return 1
  fi
  require_direct_ref "$head_target" "checked-out branch" || return
  require_ref_path_without_symlinks "$head_target" "checked-out branch" || return
  head_sha=$(run_trusted_git rev-parse 'HEAD^{commit}') || return
  refs_before=$(snapshot_refs_except "$destination_ref") || return

  run_trusted_git -c protocol.file.allow=never fetch --no-tags --no-recurse-submodules \
    --no-write-fetch-head --no-prune "$canonical_url" \
    "+refs/heads/main:$destination_ref" || fetch_status=$?

  require_direct_ref "$destination_ref" "$remote_name/main fetch destination" || return 1
  require_ref_path_without_symlinks "$destination_ref" "$remote_name/main fetch destination" || return 1
  if ! head_target_after=$(run_trusted_git symbolic-ref --quiet --no-recurse HEAD); then
    echo "HEAD stopped naming the checked-out branch during canonical fetch" >&2
    return 1
  fi
  head_sha_after=$(run_trusted_git rev-parse 'HEAD^{commit}') || return 1
  refs_after=$(snapshot_refs_except "$destination_ref") || return 1
  if [ "$head_target_after" != "$head_target" ] || [ "$head_sha_after" != "$head_sha" ] ||
    [ "$refs_after" != "$refs_before" ]; then
    echo "canonical fetch changed a local ref outside $destination_ref; refusing synchronization" >&2
    return 1
  fi
  if [ "$fetch_status" -ne 0 ]; then
    return "$fetch_status"
  fi
}

prepare_upstream_sync() {
  local repository_root
  require_safe_invocation_config || return
  repository_root=$(run_trusted_git rev-parse --show-toplevel 2>/dev/null) || {
    echo "run this script inside the world-app repository" >&2
    return 1
  }
  cd "$repository_root" || return

  require_no_local_url_rewrites || return
  require_no_local_object_indirection "$repository_root" || return
  require_no_hidden_index_entries || return

  if [ -n "$(run_trusted_git status --porcelain)" ]; then
    echo "working tree is not clean; commit or stash all tracked and untracked changes first" >&2
    return 1
  fi

  local current_branch
  local origin_main
  local local_main
  local upstream_sha
  local upstream_short
  current_branch=$(run_trusted_git branch --show-current)
  if [ "$current_branch" != "main" ]; then
    echo "run this script from local main (current: ${current_branch:-detached HEAD})" >&2
    return 1
  fi
  require_checked_out_main || return
  local_main=$(run_trusted_git rev-parse 'refs/heads/main^{commit}') || return

  require_remote_repository origin waonme/world-app || return

  if ! run_trusted_git config --local --no-includes --get remote.upstream.url >/dev/null 2>&1; then
    run_trusted_git remote add upstream https://github.com/concrnt/world-app.git || return
  fi
  require_remote_repository upstream concrnt/world-app || return

  fetch_canonical_main origin https://github.com/waonme/world-app.git || return
  require_no_local_object_indirection "$repository_root" || return
  require_no_hidden_index_entries || return
  origin_main=$(run_trusted_git rev-parse 'origin/main^{commit}') || return
  if [ "$(run_trusted_git rev-parse 'refs/heads/main^{commit}')" != "$local_main" ]; then
    echo "local main changed while fetching canonical origin" >&2
    return 1
  fi
  if [ "$local_main" != "$origin_main" ]; then
    echo "local main must exactly match origin/main before an upstream integration" >&2
    return 1
  fi
  require_git_attribute_source_support "$local_main" || return

  fetch_canonical_main upstream https://github.com/concrnt/world-app.git || return
  require_no_local_object_indirection "$repository_root" || return
  require_no_hidden_index_entries || return
  if [ "$(run_trusted_git rev-parse 'refs/heads/main^{commit}')" != "$local_main" ]; then
    echo "local main changed while fetching canonical upstream" >&2
    return 1
  fi
  upstream_sha=$(run_trusted_git rev-parse 'upstream/main^{commit}') || return
  upstream_short=$(run_trusted_git rev-parse --short=12 "$upstream_sha") || return

  if run_trusted_git merge-base --is-ancestor "$upstream_sha" main; then
    echo "main already contains upstream/main ($upstream_short)"
    return 0
  fi

  local sync_date
  local integration_branch
  sync_date=$(date -u +%Y%m%d)
  integration_branch="integrate/upstream-${sync_date}-${upstream_short}"

  if run_trusted_git show-ref --verify --quiet "refs/heads/$integration_branch"; then
    echo "integration branch already exists: $integration_branch" >&2
    return 1
  fi

  run_trusted_git switch -c "$integration_branch" || return
  if ! run_trusted_merge_git "$local_main" merge --no-ff "$upstream_sha" \
    -m "Merge upstream world-app through ${sync_date} (${upstream_short})"; then
    echo "resolve conflicts using FORK.md, then run the required gates before committing" >&2
    return 1
  fi

  local merge_sha
  local merge_parents
  merge_sha=$(run_trusted_git rev-parse 'HEAD^{commit}') || return
  merge_parents=$(run_trusted_git show -s --format=%P "$merge_sha") || return
  if [ "$merge_parents" != "$local_main $upstream_sha" ]; then
    echo "prepared integration commit has unexpected parents: $merge_parents" >&2
    return 1
  fi
  if [ "$(run_trusted_git rev-parse 'refs/heads/main^{commit}')" != "$local_main" ]; then
    echo "local main changed while preparing the integration branch" >&2
    return 1
  fi
  require_no_local_object_indirection "$repository_root" || return
  require_no_hidden_index_entries || return
  if ! run_trusted_git diff --no-ext-diff --no-textconv --quiet "$merge_sha" -- ||
    [ -n "$(run_trusted_git status --porcelain --untracked-files=normal)" ]; then
    echo "prepared integration worktree differs from its merge commit" >&2
    return 1
  fi

  echo "prepared $integration_branch at upstream $upstream_sha"
  echo "run the gates in FORK.md, push this branch, and open a PR into main"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  prepare_upstream_sync "$@"
fi

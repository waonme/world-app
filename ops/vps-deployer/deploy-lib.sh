#!/usr/bin/env bash

# Shared, side-effect-limited helpers for deploy.sh. This file is sourced by the
# production deployer and by test-deploy.sh.

wait_for_job() {
  local job_namespace=$1
  local job_name=$2
  local timeout_seconds=$3
  local poll_interval=${WORLD_APP_JOB_POLL_INTERVAL_SECONDS:-2}
  local deadline=$((SECONDS + timeout_seconds))

  while [ "$SECONDS" -lt "$deadline" ]; do
    local status
    if ! status=$(microk8s kubectl -n "$job_namespace" get job "$job_name" -o json); then
      echo "failed to read Kubernetes Job $job_namespace/$job_name" >&2
      return 1
    fi

    local succeeded
    local failed
    if ! succeeded=$(printf '%s' "$status" | jq -er '.status.succeeded // 0'); then
      echo "failed to read succeeded status for Kubernetes Job $job_namespace/$job_name" >&2
      return 1
    fi
    if ! failed=$(printf '%s' "$status" | jq -er '.status.failed // 0'); then
      echo "failed to read failed status for Kubernetes Job $job_namespace/$job_name" >&2
      return 1
    fi
    if [[ ! "$succeeded" =~ ^[0-9]+$ ]] || [[ ! "$failed" =~ ^[0-9]+$ ]]; then
      echo "Kubernetes Job $job_namespace/$job_name returned non-numeric status" >&2
      return 1
    fi

    if [ "$succeeded" -ge 1 ]; then
      return 0
    fi
    if [ "$failed" -ge 1 ]; then
      return 1
    fi
    sleep "$poll_interval"
  done
  return 124
}

wait_for_deployment_rollout() {
  local rollout_namespace=$1
  local rollout_deployment=$2

  # kubectl's rollout timeout does not necessarily bound the initial API
  # request. GNU timeout provides a process-group deadline for the complete
  # command, including connection setup and any child processes.
  timeout --signal=TERM --kill-after=10s 210s \
    microk8s kubectl -n "$rollout_namespace" rollout status \
      "deployment/$rollout_deployment" --timeout=180s
}

deployment_requires_rollback() {
  local deployment_was_mutated=$1
  local deployment_was_successful=$2
  [ "$deployment_was_mutated" = true ] && [ "$deployment_was_successful" != true ]
}

github_repository_from_remote_url() {
  local remote_url=$1
  local repository=""

  case "$remote_url" in
    https://github.com/*) repository=${remote_url#https://github.com/} ;;
    git@github.com:*) repository=${remote_url#git@github.com:} ;;
    ssh://git@github.com/*) repository=${remote_url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac

  repository=${repository%/}
  repository=${repository%.git}
  case "$repository" in
    */*/* | /* | */ | *\?* | *\#*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  [ -n "${repository%%/*}" ] || return 1
  [ -n "${repository#*/}" ] || return 1
  printf '%s\n' "$repository"
}

require_github_repository_url() {
  local remote_url=$1
  local expected_repository=$2
  local description=$3
  local actual_repository

  if ! actual_repository=$(github_repository_from_remote_url "$remote_url"); then
    echo "$description must use a standard GitHub HTTPS or SSH URL for $expected_repository (current: $remote_url)" >&2
    return 1
  fi
  if [ "$actual_repository" != "$expected_repository" ]; then
    echo "$description points to $actual_repository; expected $expected_repository" >&2
    return 1
  fi
}

require_mirror_origin_repository() {
  local repository_git_dir=$1
  local expected_repository=$2
  local origin_url

  if ! origin_url=$(git --git-dir="$repository_git_dir" config --local --get remote.origin.url 2>/dev/null); then
    echo "deployment mirror origin is missing" >&2
    return 1
  fi
  require_github_repository_url "$origin_url" "$expected_repository" "deployment mirror origin"
}

require_mirror_without_url_rewrites() {
  local repository_git_dir=$1
  local rewrite_config
  local config_status

  if rewrite_config=$(git --git-dir="$repository_git_dir" config --local --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null); then
    echo "deployment mirror contains forbidden Git URL rewrite rules:" >&2
    printf '%s\n' "$rewrite_config" >&2
    return 1
  else
    config_status=$?
  fi
  if [ "$config_status" -ne 1 ]; then
    echo "failed to inspect deployment mirror URL rewrite rules" >&2
    return 1
  fi
}

run_isolated_git() {
  env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    git -c protocol.file.allow=never "$@"
}

require_fast_forward_update() {
  local repository_git_dir=$1
  local deployed_sha=$2
  local target_sha=$3

  if [[ ! "$deployed_sha" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$target_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "refusing fast-forward check with invalid commit state: $deployed_sha -> $target_sha" >&2
    return 1
  fi
  if ! git --git-dir="$repository_git_dir" cat-file -e "$deployed_sha^{commit}"; then
    echo "refusing deployment because the recorded commit is unavailable: $deployed_sha" >&2
    return 1
  fi
  if ! git --git-dir="$repository_git_dir" cat-file -e "$target_sha^{commit}"; then
    echo "refusing deployment because the target commit is unavailable: $target_sha" >&2
    return 1
  fi
  if ! git --git-dir="$repository_git_dir" merge-base --is-ancestor "$deployed_sha" "$target_sha"; then
    echo "refusing non-fast-forward main update: $deployed_sha -> $target_sha" >&2
    return 1
  fi
}

world_app_image_sha() {
  local image=$1
  local image_repository=$2
  local candidate=${image#"$image_repository:"}

  if [ "$candidate" = "$image" ] || [[ ! "$candidate" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  printf '%s\n' "$candidate"
}

resolve_deployed_sha() {
  local recorded_sha=$1
  local current_image=$2
  local image_repository=$3
  local allow_initial_bootstrap=$4
  local image_sha=""

  image_sha=$(world_app_image_sha "$current_image" "$image_repository" 2>/dev/null || true)

  if [ -n "$recorded_sha" ]; then
    if [[ ! "$recorded_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "refusing invalid deployed commit state: $recorded_sha" >&2
      return 1
    fi
    if [ -z "$image_sha" ]; then
      echo "refusing recorded deployed state because the current image is unrecognized: ${current_image:-<empty>}" >&2
      return 1
    fi
    if [ "$image_sha" != "$recorded_sha" ]; then
      echo "refusing inconsistent deployed state: state=$recorded_sha image=$image_sha" >&2
      return 1
    fi
    printf '%s\n' "$recorded_sha"
    return 0
  fi

  if [ -n "$image_sha" ]; then
    echo "recovering missing deployed-sha from current image $current_image" >&2
    printf '%s\n' "$image_sha"
    return 0
  fi

  if [ -z "$current_image" ]; then
    echo "refusing deployment because the current container image is empty" >&2
    return 1
  fi
  if [ "$allow_initial_bootstrap" = "1" ]; then
    echo "explicit initial bootstrap allowed from unrecognized image: ${current_image:-<empty>}" >&2
    return 0
  fi

  echo "deployed-sha is missing and the current image does not contain a commit; set WORLD_APP_ALLOW_INITIAL_BOOTSTRAP=1 for one reviewed bootstrap run" >&2
  return 1
}

file_mtime_epoch() {
  local path=$1
  stat -c %Y "$path" 2>/dev/null || stat -f %m "$path"
}

retry_backoff_remaining() {
  local failed_sha_file=$1
  local target_sha=$2
  local now=$3
  local retry_window=$4

  [ -f "$failed_sha_file" ] || return 1
  [ "$(tr -d '\n' < "$failed_sha_file")" = "$target_sha" ] || return 1

  local failed_at
  if ! failed_at=$(file_mtime_epoch "$failed_sha_file"); then
    echo "cannot read retry timestamp from $failed_sha_file" >&2
    return 2
  fi

  local elapsed=$((now - failed_at))
  if [ "$elapsed" -lt 0 ]; then
    elapsed=0
  fi
  if [ "$elapsed" -ge "$retry_window" ]; then
    return 1
  fi

  printf '%s\n' $((retry_window - elapsed))
}

record_sha_state() {
  local sha_file=$1
  local sha=$2
  local temporary_file="${sha_file}.tmp.$$"

  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "refusing to record invalid commit state: $sha" >&2
    return 1
  fi
  if ! printf '%s\n' "$sha" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi
  if ! mv -f "$temporary_file" "$sha_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi
}

record_text_state() {
  local state_file=$1
  local value=$2
  local temporary_file="${state_file}.tmp.$$"

  if ! printf '%s\n' "$value" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi
  if ! mv -f "$temporary_file" "$state_file"; then
    rm -f -- "$temporary_file"
    return 1
  fi
}

read_sha_state() {
  local sha_file=$1
  local sha

  [ -f "$sha_file" ] || return 1
  sha=$(tr -d '\n' < "$sha_file")
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "invalid commit state in $sha_file: $sha" >&2
    return 2
  fi
  printf '%s\n' "$sha"
}

restore_sha_state() {
  local sha_file=$1
  local previous_sha=$2

  if [ -n "$previous_sha" ]; then
    record_sha_state "$sha_file" "$previous_sha"
  else
    rm -f -- "$sha_file"
  fi
}

safe_remove_deploy_path() {
  local path=$1
  local parent=${2%/}

  if [ "${path%/*}" != "$parent" ]; then
    echo "refusing non-child deploy cleanup path: $path" >&2
    return 1
  fi
  case "${path##*/}" in
    deploy-?*) ;;
    *)
      echo "refusing non-deploy cleanup path: $path" >&2
      return 1
      ;;
  esac
  [ -e "$path" ] || [ -L "$path" ] || return 0
  rm -rf -- "$path"
}

cleanup_stale_deploy_attempts() {
  local repository_git_dir=$1
  local worktree_parent=${2%/}
  local artifact_parent=${3%/}
  local cleanup_failed=false
  local stale_path

  for stale_path in "$worktree_parent"/deploy-*; do
    [ -e "$stale_path" ] || [ -L "$stale_path" ] || continue
    if [ -d "$repository_git_dir" ] && ! git --git-dir="$repository_git_dir" worktree remove --force "$stale_path" >/dev/null 2>&1; then
      echo "git could not unregister stale worktree; removing validated path directly: $stale_path" >&2
    fi
    if [ -e "$stale_path" ] || [ -L "$stale_path" ]; then
      if ! safe_remove_deploy_path "$stale_path" "$worktree_parent"; then
        cleanup_failed=true
      fi
    fi
  done

  if [ -d "$repository_git_dir" ] && ! git --git-dir="$repository_git_dir" worktree prune --expire=now; then
    echo "failed to prune stale deployment worktree registrations" >&2
    cleanup_failed=true
  fi

  for stale_path in "$artifact_parent"/deploy-*; do
    [ -e "$stale_path" ] || [ -L "$stale_path" ] || continue
    if ! safe_remove_deploy_path "$stale_path" "$artifact_parent"; then
      cleanup_failed=true
    fi
  done

  [ "$cleanup_failed" = false ]
}

mark_cleanup_issue() {
  local state_dir=$1
  local message=$2
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  record_text_state "$state_dir/cleanup-required" "$timestamp $message"
}

transaction_directory_from_marker() {
  local state_dir=${1%/}
  local marker="$state_dir/inflight"
  local transaction_name

  [ -f "$marker" ] || return 1
  transaction_name=$(tr -d '\n' < "$marker")
  if [[ ! "$transaction_name" =~ ^transaction\.[[:alnum:]]{8}$ ]]; then
    echo "invalid inflight transaction marker: $transaction_name" >&2
    return 2
  fi
  printf '%s/%s\n' "$state_dir" "$transaction_name"
}

create_deployment_transaction() {
  local state_dir=${1%/}
  local deployment_snapshot=$2
  local container_name=$3
  local target_sha=$4
  local previous_sha=$5
  local transaction_dir
  local transaction_name

  if [ -e "$state_dir/inflight" ]; then
    echo "refusing to replace an existing deployment transaction" >&2
    return 1
  fi
  if [[ ! "$target_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "refusing transaction with invalid target SHA: $target_sha" >&2
    return 1
  fi
  if [ -n "$previous_sha" ] && [[ ! "$previous_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "refusing transaction with invalid previous SHA: $previous_sha" >&2
    return 1
  fi
  if ! jq -e --arg container_name "$container_name" '
    (.metadata.uid | type == "string" and length > 0) and
    (.metadata.resourceVersion | type == "string" and length > 0) and
    ([.spec.template.spec.containers[] | select(.name == $container_name)] | length == 1)
  ' "$deployment_snapshot" >/dev/null; then
    echo "deployment snapshot is invalid or does not contain exactly one $container_name container" >&2
    return 1
  fi

  transaction_dir=$(mktemp -d "$state_dir/transaction.XXXXXXXX")
  transaction_name=${transaction_dir##*/}
  if ! cp "$deployment_snapshot" "$transaction_dir/deployment.json" ||
    ! jq 'del(.status, .metadata.managedFields)' "$deployment_snapshot" > "$transaction_dir/restore-template.json" ||
    ! record_sha_state "$transaction_dir/target-sha" "$target_sha"; then
    rm -rf -- "$transaction_dir"
    return 1
  fi
  if [ -n "$previous_sha" ] && ! record_sha_state "$transaction_dir/previous-deployed-sha" "$previous_sha"; then
    rm -rf -- "$transaction_dir"
    return 1
  fi
  if ! record_text_state "$state_dir/inflight" "$transaction_name"; then
    rm -rf -- "$transaction_dir"
    return 1
  fi
  printf '%s\n' "$transaction_dir"
}

clear_deployment_transaction() {
  local state_dir=${1%/}
  local transaction_dir

  transaction_dir=$(transaction_directory_from_marker "$state_dir") || {
    local marker_status=$?
    [ "$marker_status" -eq 1 ] && return 0
    return "$marker_status"
  }
  if [ ! -d "$transaction_dir" ]; then
    echo "inflight transaction directory is missing: $transaction_dir" >&2
    return 1
  fi
  if ! rm -f -- "$state_dir/inflight"; then
    echo "failed to clear inflight transaction marker" >&2
    return 1
  fi
  if ! rm -rf -- "$transaction_dir"; then
    echo "failed to remove completed deployment transaction: $transaction_dir" >&2
    return 1
  fi
}

cleanup_orphaned_transactions() {
  local state_dir=${1%/}
  local active_transaction=""
  local candidate

  if [ -f "$state_dir/inflight" ]; then
    active_transaction=$(transaction_directory_from_marker "$state_dir") || return
  fi
  for candidate in "$state_dir"/transaction.*; do
    [ -d "$candidate" ] || continue
    if [ "$candidate" = "$active_transaction" ]; then
      continue
    fi
    if ! rm -rf -- "$candidate"; then
      echo "failed to remove orphaned deployment transaction: $candidate" >&2
      return 1
    fi
  done
}

deployment_container_image() {
  local deployment_json=$1
  local container_name=$2
  jq -er --arg container_name "$container_name" '
    [.spec.template.spec.containers[] | select(.name == $container_name)] as $containers |
    if ($containers | length) == 1 then $containers[0].image else empty end
  ' "$deployment_json"
}

deployment_desired_state() {
  local deployment_json=$1
  jq -S '
    {
      metadata: {
        labels: (.metadata.labels // {}),
        annotations: ((.metadata.annotations // {}) | del(."deployment.kubernetes.io/revision")),
        finalizers: (.metadata.finalizers // []),
        ownerReferences: (.metadata.ownerReferences // [])
      },
      spec: .spec
    }
  ' "$deployment_json"
}

deployment_desired_state_matches() {
  local expected_json=$1
  local actual_json=$2
  local expected_state
  local actual_state

  expected_state=$(deployment_desired_state "$expected_json") || return 1
  actual_state=$(deployment_desired_state "$actual_json") || return 1
  [ "$expected_state" = "$actual_state" ]
}

validate_transaction_postpatch() {
  local transaction_dir=$1
  local snapshot_uid=$2
  local container_name=$3
  local image_repository=$4
  local target_sha=$5
  local transaction_name=${transaction_dir##*/}
  local postpatch_json="$transaction_dir/postpatch-deployment.json"

  [ -s "$postpatch_json" ] || {
    echo "transaction postpatch Deployment is missing" >&2
    return 1
  }
  if ! jq -e \
    --arg snapshot_uid "$snapshot_uid" \
    --arg container_name "$container_name" \
    --arg target_image "$image_repository:$target_sha" \
    --arg transaction_name "$transaction_name" '
      .metadata.uid == $snapshot_uid and
      .spec.template.metadata.annotations["world-app.waon.me/deploy-transaction"] == $transaction_name and
      ([.spec.template.spec.containers[] |
        select(.name == $container_name and .image == $target_image)] | length == 1)
    ' "$postpatch_json" >/dev/null; then
    echo "transaction postpatch Deployment is invalid" >&2
    return 1
  fi
}

restore_deployment_transaction() {
  local production_namespace=$1
  local deployment_name=$2
  local container_name=$3
  local state_dir=${4%/}
  local image_repository=$5
  local transaction_dir
  local current_json
  local replacement_json
  local verified_json
  local target_sha
  local previous_sha=""
  local snapshot_uid
  local current_uid
  local current_resource_version
  local current_image
  local original_image
  local current_matches_original=false
  local current_matches_postpatch=false

  transaction_dir=$(transaction_directory_from_marker "$state_dir") || return 1
  [ -f "$transaction_dir/deployment.json" ] || return 1
  [ -f "$transaction_dir/restore-template.json" ] || return 1
  target_sha=$(read_sha_state "$transaction_dir/target-sha") || return 1
  if [ -f "$transaction_dir/previous-deployed-sha" ]; then
    previous_sha=$(read_sha_state "$transaction_dir/previous-deployed-sha") || return 1
  fi
  current_json=$(mktemp "$transaction_dir/current.XXXXXXXX")
  replacement_json=$(mktemp "$transaction_dir/replacement.XXXXXXXX")
  verified_json=$(mktemp "$transaction_dir/verified.XXXXXXXX")

  if ! microk8s kubectl --request-timeout=20s -n "$production_namespace" get deployment "$deployment_name" -o json > "$current_json"; then
    return 1
  fi
  snapshot_uid=$(jq -er '.metadata.uid' "$transaction_dir/deployment.json") || return 1
  current_uid=$(jq -er '.metadata.uid' "$current_json") || return 1
  if [ "$snapshot_uid" != "$current_uid" ]; then
    echo "refusing rollback because Deployment UID changed: $snapshot_uid -> $current_uid" >&2
    return 1
  fi
  current_image=$(deployment_container_image "$current_json" "$container_name") || return 1
  original_image=$(deployment_container_image "$transaction_dir/deployment.json" "$container_name") || return 1
  if [ "$current_image" = "$original_image" ] &&
    deployment_desired_state_matches "$transaction_dir/deployment.json" "$current_json"; then
    current_matches_original=true
  elif [ "$current_image" = "$image_repository:$target_sha" ]; then
    validate_transaction_postpatch "$transaction_dir" "$snapshot_uid" "$container_name" "$image_repository" "$target_sha" || return 1
    if ! deployment_desired_state_matches "$transaction_dir/postpatch-deployment.json" "$current_json"; then
      echo "refusing rollback because Deployment desired state changed after this transaction patch" >&2
      return 1
    fi
    current_matches_postpatch=true
  else
    echo "refusing rollback because current Deployment state is outside this transaction" >&2
    return 1
  fi

  if [ "$current_matches_postpatch" = true ]; then
    current_resource_version=$(jq -er '.metadata.resourceVersion' "$current_json") || return 1
    if ! jq --arg resource_version "$current_resource_version" '.metadata.resourceVersion = $resource_version' \
      "$transaction_dir/restore-template.json" > "$replacement_json"; then
      return 1
    fi
    if ! microk8s kubectl --request-timeout=20s -n "$production_namespace" replace -f "$replacement_json"; then
      echo "failed to restore the previous Deployment object" >&2
      return 1
    fi
  elif [ "$current_matches_original" = true ]; then
    echo "Deployment already matches the saved prepatch state; restoring transaction metadata only" >&2
  fi
  if ! restore_sha_state "$state_dir/deployed-sha" "$previous_sha"; then
    echo "failed to restore previous deployed-sha state" >&2
    return 1
  fi
  if ! wait_for_deployment_rollout "$production_namespace" "$deployment_name"; then
    echo "rollback rollout did not complete" >&2
    return 1
  fi
  if ! microk8s kubectl --request-timeout=20s -n "$production_namespace" get deployment "$deployment_name" -o json > "$verified_json"; then
    return 1
  fi
  if ! deployment_desired_state_matches "$transaction_dir/deployment.json" "$verified_json"; then
    echo "restored Deployment desired state differs from the saved snapshot" >&2
    return 1
  fi
  clear_deployment_transaction "$state_dir"
}

recover_inflight_deployment() {
  local production_namespace=$1
  local deployment_name=$2
  local container_name=$3
  local state_dir=${4%/}
  local image_repository=$5
  local transaction_dir
  local target_sha
  local previous_sha=""
  local deployed_sha=""
  local current_json
  local current_image
  local original_image

  transaction_dir=$(transaction_directory_from_marker "$state_dir") || {
    local marker_status=$?
    [ "$marker_status" -eq 1 ] && return 0
    return "$marker_status"
  }
  target_sha=$(read_sha_state "$transaction_dir/target-sha") || return 1
  if [ -f "$transaction_dir/previous-deployed-sha" ]; then
    previous_sha=$(read_sha_state "$transaction_dir/previous-deployed-sha") || return 1
  fi
  if [ -f "$state_dir/deployed-sha" ]; then
    deployed_sha=$(read_sha_state "$state_dir/deployed-sha") || return 1
  fi
  current_json=$(mktemp "$transaction_dir/recovery-current.XXXXXXXX")
  if ! microk8s kubectl --request-timeout=20s -n "$production_namespace" get deployment "$deployment_name" -o json > "$current_json"; then
    return 1
  fi
  current_image=$(deployment_container_image "$current_json" "$container_name") || return 1
  original_image=$(deployment_container_image "$transaction_dir/deployment.json" "$container_name") || return 1

  if [ "$deployed_sha" = "$target_sha" ] && [ "$current_image" = "$image_repository:$target_sha" ]; then
    echo "recovering committed deployment transaction for $target_sha"
    clear_deployment_transaction "$state_dir"
    return
  fi

  if { [ -z "$previous_sha" ] && [ -z "$deployed_sha" ]; } ||
    [ "$deployed_sha" = "$previous_sha" ] || [ "$deployed_sha" = "$target_sha" ]; then
    case "$current_image" in
      "$original_image" | "$image_repository:$target_sha")
        echo "rolling back interrupted deployment transaction for $target_sha" >&2
        restore_deployment_transaction "$production_namespace" "$deployment_name" "$container_name" "$state_dir" "$image_repository"
        return
        ;;
    esac
  fi

  echo "refusing ambiguous deployment transaction recovery: state=${deployed_sha:-<empty>} image=$current_image" >&2
  return 1
}

commit_deployment_success() {
  local state_dir=$1
  local target_sha=$2

  trap '' INT TERM HUP
  if ! record_sha_state "$state_dir/deployed-sha" "$target_sha"; then
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    return 1
  fi

  # The atomic deployed-sha rename is the commit point. Keep these global flags
  # in the same signal-masked section so EXIT can never roll back committed state.
  deployment_succeeded=true
  deployment_mutated=false

  if ! rm -f -- "$state_dir/last-failed-sha"; then
    echo "deployment committed but failed to remove last-failed-sha" >&2
    mark_cleanup_issue "$state_dir" "last-failed-sha removal failed after commit" || true
  fi
  if ! clear_deployment_transaction "$state_dir"; then
    echo "deployment committed but transaction cleanup is incomplete" >&2
    mark_cleanup_issue "$state_dir" "transaction cleanup failed after commit" || true
  fi

  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

finish_deployment_actions() {
  local original_exit_code=$1
  local final_exit_code=$original_exit_code
  local rollback_code=0
  local rollback_required=false

  if deployment_requires_rollback "$deployment_mutated" "$deployment_succeeded"; then
    rollback_required=true
    rollback_once
    rollback_code=$?
  fi
  if [ "$deployment_succeeded" != true ] && [ "$record_failure_on_exit" = true ] && [ -n "$target_sha" ]; then
    if ! record_sha_state "$state_dir/last-failed-sha" "$target_sha"; then
      echo "failed to record deployment failure for $target_sha" >&2
    fi
  fi
  if ! cleanup_attempt; then
    echo "deployment attempt cleanup is incomplete; see $state_dir/cleanup-required" >&2
  fi

  if [ "$final_exit_code" -eq 0 ] && [ "$rollback_required" = true ]; then
    final_exit_code=${rollback_code:-1}
    [ "$final_exit_code" -ne 0 ] || final_exit_code=1
  fi
  return "$final_exit_code"
}

verify_exact_worktree() {
  local repository_git_dir=$1
  local worktree_path=$2
  local expected_sha=$3
  local actual_sha

  if ! actual_sha=$(git -C "$worktree_path" rev-parse 'HEAD^{commit}'); then
    echo "cannot resolve build worktree HEAD: $worktree_path" >&2
    return 1
  fi
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "build worktree is at the wrong commit: expected=$expected_sha actual=$actual_sha" >&2
    return 1
  fi
  if ! git --git-dir="$repository_git_dir" cat-file -e "$expected_sha^{commit}"; then
    echo "expected build commit is unavailable: $expected_sha" >&2
    return 1
  fi
  if ! git -C "$worktree_path" diff --quiet "$expected_sha" --; then
    echo "build worktree has tracked content that differs from $expected_sha" >&2
    return 1
  fi
  if [ -n "$(git -C "$worktree_path" status --porcelain --untracked-files=all)" ]; then
    echo "build worktree contains uncommitted or untracked content" >&2
    return 1
  fi
}

verify_http_deployment_once() {
  local site_url=${1%/}
  local expected_sha=$2
  local info
  local version
  local root_document
  local asset_path

  if ! info=$(curl -fsS --max-time 10 "$site_url/cc-info"); then
    return 1
  fi
  if ! version=$(printf '%s' "$info" | jq -er '.version // empty'); then
    return 1
  fi
  [ "$version" = "$expected_sha" ] || return 1

  # Fetch the root document once. Re-fetching it in an unguarded assignment can
  # make errexit bypass the caller's rollback path.
  if ! root_document=$(curl -fsS --max-time 10 "$site_url/"); then
    return 1
  fi
  asset_path=$(printf '%s' "$root_document" | sed -n 's/.*src="\([^\"]*\/assets\/[^\"]*\.js\)".*/\1/p' | head -n 1)
  case "$asset_path" in
    /assets/*.js | /web/assets/*.js) ;;
    *) return 1 ;;
  esac

  curl -fsS --max-time 10 "$site_url$asset_path" >/dev/null
}

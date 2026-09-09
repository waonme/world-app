#!/usr/bin/env bash

set -Eeuo pipefail

repository_root=$(git rev-parse --show-toplevel)
task_test_parent=${TMPDIR:-/tmp}
task_test_dir=$(mktemp -d "$task_test_parent/world-app-deploy-test.XXXXXXXX")

cleanup() {
  case "$task_test_dir" in
    "$task_test_parent"/world-app-deploy-test.*) rm -rf -- "$task_test_dir" ;;
    *) echo "refusing to remove unexpected test directory: $task_test_dir" >&2 ;;
  esac
}
trap cleanup EXIT

# shellcheck source=deploy-lib.sh
source "$repository_root/ops/vps-deployer/deploy-lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  local description=$3
  if [ "$actual" != "$expected" ]; then
    fail "$description (expected '$expected', got '$actual')"
  fi
}

capture_status() {
  set +e
  "$@"
  captured_status=$?
  set -e
}

deploy_script="$repository_root/ops/vps-deployer/deploy.sh"
deploy_library="$repository_root/ops/vps-deployer/deploy-lib.sh"
deploy_test="$repository_root/ops/vps-deployer/test-deploy.sh"
service_unit="$repository_root/ops/vps-deployer/world-app-vps-deploy.service"
bash -n "$deploy_script" "$deploy_library" "$deploy_test"

sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

deployment_requires_rollback true false || fail "a post-patch failure must require rollback"
if deployment_requires_rollback true true || deployment_requires_rollback false false; then
  fail "rollback decision matrix accepted a committed or pre-patch state"
fi

resolved=$(resolve_deployed_sha "" "localhost/world-app:$sha_a" localhost/world-app 0)
assert_equal "$sha_a" "$resolved" "missing state should recover the exact SHA from the current image"
if resolve_deployed_sha "" "" localhost/world-app 1 >/dev/null 2>&1; then
  fail "an empty current image must be rejected even during explicit bootstrap"
fi
resolve_deployed_sha "" "registry.example/world-app:legacy" localhost/world-app 1 >/dev/null
if resolve_deployed_sha "$sha_a" "localhost/world-app:$sha_b" localhost/world-app 0 >/dev/null 2>&1; then
  fail "recorded state and a recognized current image must not disagree"
fi

failed_sha_file="$task_test_dir/last-failed-sha"
record_sha_state "$failed_sha_file" "$sha_a"
failed_at=$(file_mtime_epoch "$failed_sha_file")
remaining=$(retry_backoff_remaining "$failed_sha_file" "$sha_a" $((failed_at + 15)) 600)
assert_equal 585 "$remaining" "retry backoff should report remaining seconds"
assert_equal "$failed_at" "$(file_mtime_epoch "$failed_sha_file")" "checking backoff must not extend its timestamp"

test_repository="$task_test_dir/repository"
git init -q "$test_repository"
git -C "$test_repository" config user.email test@example.invalid
git -C "$test_repository" config user.name "World App Test"
printf 'first\n' > "$test_repository/tracked.txt"
ln -s canonical-target "$test_repository/tracked-link"
git -C "$test_repository" add tracked.txt tracked-link
git -C "$test_repository" commit -q -m first
first_sha=$(git -C "$test_repository" rev-parse HEAD)
verify_exact_worktree "$test_repository/.git" "$test_repository" "$first_sha"

printf 'dirty\n' > "$test_repository/tracked.txt"
if verify_exact_worktree "$test_repository/.git" "$test_repository" "$first_sha" >/dev/null 2>&1; then
  fail "tracked build-source mutation must be rejected"
fi
git -C "$test_repository" restore --source="$first_sha" tracked.txt
printf 'untracked\n' > "$test_repository/untracked.txt"
if verify_exact_worktree "$test_repository/.git" "$test_repository" "$first_sha" >/dev/null 2>&1; then
  fail "untracked build-source content must be rejected"
fi
rm -f "$test_repository/untracked.txt"

rm -f "$test_repository/tracked-link"
ln -s $'canonical-target\n' "$test_repository/tracked-link"
if verify_exact_worktree "$test_repository/.git" "$test_repository" "$first_sha" >/dev/null 2>&1; then
  fail "a symlink target with extra trailing bytes must be rejected"
fi
git -C "$test_repository" restore --source="$first_sha" tracked-link

printf 'second\n' > "$test_repository/tracked.txt"
git -C "$test_repository" add tracked.txt
git -C "$test_repository" commit -q -m second
second_sha=$(git -C "$test_repository" rev-parse HEAD)
if verify_exact_worktree "$test_repository/.git" "$test_repository" "$first_sha" >/dev/null 2>&1; then
  fail "a worktree at the wrong HEAD must be rejected"
fi

git -C "$test_repository" switch -q -c divergent "$first_sha"
printf 'divergent\n' > "$test_repository/tracked.txt"
git -C "$test_repository" commit -qam divergent
divergent_sha=$(git -C "$test_repository" rev-parse HEAD)
require_fast_forward_update "$test_repository/.git" "$first_sha" "$second_sha"
if require_fast_forward_update "$test_repository/.git" "$second_sha" "$divergent_sha" >/dev/null 2>&1; then
  fail "non-fast-forward deployment history must be rejected"
fi

mirror_repository="$task_test_dir/mirror.git"
git init -q --bare "$mirror_repository"
git --git-dir="$mirror_repository" remote add origin git@github.com:waonme/world-app.git
require_mirror_origin_repository "$mirror_repository" waonme/world-app
require_mirror_without_url_rewrites "$mirror_repository"
require_fresh_mirror_config "$mirror_repository"
git --git-dir="$mirror_repository" config url.file:///tmp/lookalike.insteadOf https://github.com/waonme/world-app.git
if require_mirror_without_url_rewrites "$mirror_repository" >/dev/null 2>&1; then
  fail "deployment mirror URL rewrite rules must be rejected"
fi
git --git-dir="$mirror_repository" config --unset-all url.file:///tmp/lookalike.insteadOf
git --git-dir="$mirror_repository" remote set-url origin https://github.com/concrnt/world-app.git
if require_mirror_origin_repository "$mirror_repository" waonme/world-app >/dev/null 2>&1; then
  fail "deployment mirror pointing at upstream must be rejected"
fi
if require_github_repository_url file:///tmp/world-app.git waonme/world-app test >/dev/null 2>&1; then
  fail "local deployment repository URLs must be rejected"
fi

isolated_git_bin="$task_test_dir/isolated-git-bin"
isolated_git_log="$task_test_dir/isolated-git.log"
mkdir -p "$isolated_git_bin"
cat > "$isolated_git_bin/git" <<'FAKE_ISOLATED_GIT'
#!/usr/bin/env bash
[ "${GIT_CONFIG_NOSYSTEM:-}" = 1 ] || exit 11
[ "${GIT_ATTR_NOSYSTEM:-}" = 1 ] || exit 10
[ "${GIT_CONFIG_GLOBAL:-}" = /dev/null ] || exit 12
[ "${GIT_TERMINAL_PROMPT:-}" = 0 ] || exit 13
[ -z "${GIT_CONFIG_COUNT+x}" ] || exit 14
[ -z "${GIT_CONFIG_PARAMETERS+x}" ] || exit 15
[ -z "${GIT_CONFIG+x}" ] || exit 24
[ -z "${GIT_ATTR_SOURCE+x}" ] || exit 25
[ "${GIT_NO_REPLACE_OBJECTS:-}" = 1 ] || exit 16
[ "${GIT_NO_LAZY_FETCH:-}" = 1 ] || exit 17
[ -z "${GIT_REPLACE_REF_BASE+x}" ] || exit 18
[ -z "${GIT_OBJECT_DIRECTORY+x}" ] || exit 19
[ -z "${GIT_ALTERNATE_OBJECT_DIRECTORIES+x}" ] || exit 20
[ "${GIT_GRAFT_FILE:-}" = /dev/null/world-app-disabled ] || exit 22
[ "${GIT_SHALLOW_FILE:-}" = /dev/null/world-app-disabled ] || exit 23
[ -z "${GIT_SSL_NO_VERIFY+x}" ] || exit 26
[ -z "${GIT_SSL_CAINFO+x}" ] || exit 27
[ -z "${HTTPS_PROXY+x}" ] || exit 28
[ -z "${https_proxy+x}" ] || exit 29
[ -z "${CURL_CA_BUNDLE+x}" ] || exit 30
[ "$*" = "-c core.attributesFile=/dev/null -c core.commitGraph=false -c core.fsmonitor=false -c core.hooksPath=/dev/null -c protocol.file.allow=never fetch canonical-sentinel" ] || exit 21
printf '%s\n' "$*" > "$WORLD_APP_TEST_ISOLATED_GIT_LOG"
FAKE_ISOLATED_GIT
chmod +x "$isolated_git_bin/git"
(
  export WORLD_APP_TEST_ISOLATED_GIT_LOG="$isolated_git_log"
  export GIT_CONFIG_NOSYSTEM=0
  export GIT_CONFIG_GLOBAL="$task_test_dir/hostile-global.gitconfig"
  export GIT_TERMINAL_PROMPT=1
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=http.extraHeader
  export GIT_CONFIG_VALUE_0='Authorization: hostile-command-config'
  export GIT_CONFIG_PARAMETERS=hostile
  export GIT_CONFIG="$task_test_dir/hostile-config"
  export GIT_ATTR_SOURCE=hostile-attribute-tree
  export GIT_REPLACE_REF_BASE=refs/hostile-replacements
  export GIT_GRAFT_FILE="$task_test_dir/hostile-grafts"
  export GIT_SHALLOW_FILE="$task_test_dir/hostile-shallow"
  export GIT_OBJECT_DIRECTORY="$task_test_dir/hostile-objects"
  export GIT_ALTERNATE_OBJECT_DIRECTORIES="$task_test_dir/hostile-alternates"
  export GIT_SSL_NO_VERIFY=1
  export GIT_SSL_CAINFO="$task_test_dir/hostile-ca.pem"
  export HTTPS_PROXY=http://127.0.0.1:9
  export https_proxy=http://127.0.0.1:9
  export CURL_CA_BUNDLE="$task_test_dir/hostile-curl-ca.pem"
  export PATH="$isolated_git_bin:$PATH"
  run_isolated_git fetch canonical-sentinel
) || fail "deployment Git transport did not isolate hostile config sources"
assert_equal "-c core.attributesFile=/dev/null -c core.commitGraph=false -c core.fsmonitor=false -c core.hooksPath=/dev/null -c protocol.file.allow=never fetch canonical-sentinel" "$(cat "$isolated_git_log")" \
  "deployment Git transport must retain only its explicit protocol policy"

# A replace ref can make a worktree contain a substitute tree while HEAD still
# reports the canonical commit. Both the mirror gate and byte/tree verification
# must reject that state, and trusted Git commands must ignore the replacement.
replace_repository="$task_test_dir/replace-repository"
replace_attacked_worktree="$task_test_dir/replace-attacked-worktree"
replace_trusted_worktree="$task_test_dir/replace-trusted-worktree"
git init -q "$replace_repository"
git -C "$replace_repository" config user.email test@example.invalid
git -C "$replace_repository" config user.name "World App Test"
printf 'canonical\n' > "$replace_repository/payload.txt"
git -C "$replace_repository" add payload.txt
git -C "$replace_repository" commit -q -m canonical
canonical_branch=$(git -C "$replace_repository" branch --show-current)
canonical_sha=$(git -C "$replace_repository" rev-parse HEAD)
git -C "$replace_repository" switch -q --orphan substitute
printf 'substituted\n' > "$replace_repository/payload.txt"
git -C "$replace_repository" add payload.txt
git -C "$replace_repository" commit -q -m substitute
substitute_sha=$(git -C "$replace_repository" rev-parse HEAD)
git -C "$replace_repository" switch -q "$canonical_branch"
git -C "$replace_repository" replace "$canonical_sha" "$substitute_sha"
git --git-dir="$replace_repository/.git" worktree add -q --detach "$replace_attacked_worktree" "$canonical_sha"
assert_equal substituted "$(tr -d '\n' < "$replace_attacked_worktree/payload.txt")" \
  "held-out attack fixture must materialize the replacement tree"
if verify_exact_worktree "$replace_repository/.git" "$replace_attacked_worktree" "$canonical_sha" >/dev/null 2>&1; then
  fail "exact-worktree verification accepted a replacement tree under the canonical SHA"
fi
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted refs/replace indirection"
fi
run_trusted_git --git-dir="$replace_repository/.git" worktree add -q --detach \
  "$replace_trusted_worktree" "$canonical_sha"
assert_equal canonical "$(tr -d '\n' < "$replace_trusted_worktree/payload.txt")" \
  "trusted worktree creation must ignore replacement refs"
run_trusted_git --git-dir="$replace_repository/.git" worktree remove --force "$replace_attacked_worktree"
run_trusted_git --git-dir="$replace_repository/.git" worktree remove --force "$replace_trusted_worktree"
git -C "$replace_repository" replace -d "$canonical_sha" >/dev/null

mkdir -p "$replace_repository/.git/info" "$replace_repository/.git/objects/info"
printf '%s\n' "$canonical_sha" > "$replace_repository/.git/info/grafts"
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted info/grafts ancestry rewriting"
fi
rm -f "$replace_repository/.git/info/grafts"
mkfifo "$replace_repository/.git/info/grafts"
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted a FIFO graft source"
fi
rm -f "$replace_repository/.git/info/grafts"
printf '%s\n' "$canonical_sha" > "$replace_repository/.git/shallow"
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted shallow ancestry"
fi
rm -f "$replace_repository/.git/shallow"
printf '%s\n' /tmp/hostile-object-store > "$replace_repository/.git/objects/info/alternates"
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted an alternate object database"
fi
rm -f "$replace_repository/.git/objects/info/alternates"
git -C "$replace_repository" config extensions.partialClone hostile
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted partial-clone object indirection"
fi
git -C "$replace_repository" config --unset extensions.partialClone
git -C "$replace_repository" config include.path /tmp/hostile-deployment-config
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted included config indirection"
fi
git -C "$replace_repository" config --unset include.path

filter_attributes="$task_test_dir/hostile-attributes"
filter_worktree="$task_test_dir/filter-attacked-worktree"
printf 'payload.txt filter=evil\n' > "$filter_attributes"
git -C "$replace_repository" config core.attributesFile "$filter_attributes"
git -C "$replace_repository" config filter.evil.smudge 'sed s/canonical/PWNED/'
git -C "$replace_repository" config filter.evil.clean 'sed s/PWNED/canonical/'
git --git-dir="$replace_repository/.git" worktree add -q --detach \
  "$filter_worktree" "$canonical_sha"
assert_equal PWNED "$(tr -d '\n' < "$filter_worktree/payload.txt")" \
  "filter attack fixture must alter materialized bytes"
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted a local clean/smudge filter"
fi
if require_fresh_mirror_config "$replace_repository/.git" >/dev/null 2>&1; then
  fail "fresh mirror allowlist accepted a local clean/smudge filter"
fi
if verify_exact_worktree "$replace_repository/.git" "$filter_worktree" "$canonical_sha" >/dev/null 2>&1; then
  fail "raw worktree oracle accepted bytes hidden by a clean filter"
fi
run_trusted_git --git-dir="$replace_repository/.git" worktree remove --force "$filter_worktree"
git -C "$replace_repository" config --unset core.attributesFile
git -C "$replace_repository" config --remove-section filter.evil

git -C "$replace_repository" config extensions.worktreeConfig true
printf '[url "https://lookalike.invalid/"]\n\tinsteadOf = https://github.com/\n' > \
  "$replace_repository/.git/config.worktree"
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted worktree-scope config"
fi
rm -f "$replace_repository/.git/config.worktree"
git -C "$replace_repository" config --unset extensions.worktreeConfig

git -C "$replace_repository" config fsck.missingEmail ignore
if require_mirror_without_object_indirection "$replace_repository/.git" >/dev/null 2>&1; then
  fail "deployment mirror accepted local fsck weakening"
fi
git -C "$replace_repository" config --unset fsck.missingEmail

stale_worktrees="$task_test_dir/worktrees"
stale_artifacts="$task_test_dir/artifacts"
mkdir -p "$stale_worktrees/deploy-old/source" "$stale_worktrees/keep-me" "$stale_artifacts/deploy-old/context" "$stale_artifacts/keep-me"
cleanup_stale_deploy_attempts "$task_test_dir/missing.git" "$stale_worktrees" "$stale_artifacts"
[ ! -e "$stale_worktrees/deploy-old" ] || fail "stale deploy worktree was not reclaimed"
[ ! -e "$stale_artifacts/deploy-old" ] || fail "stale deploy artifact was not reclaimed"
[ -d "$stale_worktrees/keep-me" ] && [ -d "$stale_artifacts/keep-me" ] || fail "stale cleanup removed a non-deploy directory"

cleanup_marker_dir="$task_test_dir/cleanup-state"
mkdir -p "$cleanup_marker_dir"
mark_cleanup_issue "$cleanup_marker_dir" "simulated cleanup failure"
grep -Fq "simulated cleanup failure" "$cleanup_marker_dir/cleanup-required" || fail "cleanup failure was not persisted for operators"

record_text_state "$cleanup_marker_dir/inflight" 'transaction.valid123/../../outside'
capture_status transaction_directory_from_marker "$cleanup_marker_dir"
assert_equal 2 "$captured_status" "an inflight marker containing path traversal must be rejected"
mkdir -p "$cleanup_marker_dir/transaction.keep1234"
capture_status cleanup_orphaned_transactions "$cleanup_marker_dir"
[ "$captured_status" -ne 0 ] || fail "orphan cleanup accepted an invalid inflight marker"
[ -d "$cleanup_marker_dir/transaction.keep1234" ] || fail "orphan cleanup removed state after an invalid inflight marker"
rm -f "$cleanup_marker_dir/inflight"
rm -rf -- "$cleanup_marker_dir/transaction.keep1234"

# A marker-removal failure must not be hidden by a later successful directory
# removal (functions called from `if !` do not inherit reliable errexit behavior).
clear_failure_state="$task_test_dir/clear-failure-state"
clear_failure_transaction="$clear_failure_state/transaction.fail1234"
mkdir -p "$clear_failure_transaction"
record_text_state "$clear_failure_state/inflight" "${clear_failure_transaction##*/}"
if (
  rm() {
    if [ "$1" = -f ] && [ "$2" = -- ] && [ "$3" = "$clear_failure_state/inflight" ]; then
      return 1
    fi
    command rm "$@"
  }
  clear_deployment_transaction "$clear_failure_state"
); then
  fail "transaction cleanup hid an inflight marker removal failure"
fi
[ -f "$clear_failure_state/inflight" ] || fail "failed marker removal must leave the recovery marker intact"
[ -d "$clear_failure_transaction" ] || fail "failed marker removal must not discard the recovery transaction"
rm -rf -- "$clear_failure_state"

fake_bin="$task_test_dir/fake-job-bin"
mkdir -p "$fake_bin"
fake_call_log="$task_test_dir/fake-job-calls"
: > "$fake_call_log"

cat > "$fake_bin/microk8s" <<'FAKE_MICROK8S'
#!/usr/bin/env bash
printf 'microk8s %s\n' "$*" >> "$WORLD_APP_TEST_CALL_LOG"
case "${WORLD_APP_TEST_JOB_MODE:-read-failure}" in
  success) printf '{"status":{"succeeded":1}}\n' ;;
  failed) printf '{"status":{"failed":1}}\n' ;;
  pending) printf '{"status":{}}\n' ;;
  read-failure) exit 42 ;;
  *) exit 2 ;;
esac
FAKE_MICROK8S

cat > "$fake_bin/jq" <<'FAKE_JQ'
#!/usr/bin/env bash
input=$(cat)
case "$*" in
  *succeeded*)
    value=$(printf '%s' "$input" | sed -n 's/.*"succeeded":\([0-9][0-9]*\).*/\1/p')
    printf '%s\n' "${value:-0}"
    ;;
  *failed*)
    value=$(printf '%s' "$input" | sed -n 's/.*"failed":\([0-9][0-9]*\).*/\1/p')
    printf '%s\n' "${value:-0}"
    ;;
  *version*) printf '%s\n' "$WORLD_APP_TEST_SHA" ;;
  *) printf '0\n' ;;
esac
FAKE_JQ

cat > "$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
url=${!#}
printf '%s\n' "$url" >> "$WORLD_APP_TEST_CALL_LOG"
case "$url" in
  */cc-info) printf '{"version":"%s"}\n' "$WORLD_APP_TEST_SHA" ;;
  */assets/app.js) exit "${WORLD_APP_TEST_ASSET_EXIT:-0}" ;;
  */) printf '<script type="module" src="/assets/app.js"></script>\n' ;;
  *) exit 1 ;;
esac
FAKE_CURL
chmod +x "$fake_bin/microk8s" "$fake_bin/jq" "$fake_bin/curl"

task_original_path=$PATH
export PATH="$fake_bin:$task_original_path"
export WORLD_APP_TEST_CALL_LOG="$fake_call_log"
export WORLD_APP_TEST_SHA="$sha_a"
export WORLD_APP_JOB_POLL_INTERVAL_SECONDS=0

export WORLD_APP_TEST_JOB_MODE=success
wait_for_job test-namespace test-job 5
export WORLD_APP_TEST_JOB_MODE=failed
capture_status wait_for_job test-namespace test-job 5
assert_equal 1 "$captured_status" "failed Kubernetes Job should fail"
export WORLD_APP_TEST_JOB_MODE=read-failure
capture_status wait_for_job test-namespace test-job 5
assert_equal 1 "$captured_status" "kubectl Job read failure should fail immediately"
export WORLD_APP_TEST_JOB_MODE=pending
capture_status wait_for_job test-namespace test-job 0
assert_equal 124 "$captured_status" "pending Kubernetes Job should time out"

: > "$fake_call_log"
verify_http_deployment_once https://arakoshi.example "$sha_a"
assert_equal 1 "$(grep -c '^https://arakoshi.example/$' "$fake_call_log")" "smoke verification should fetch the root document once"
: > "$fake_call_log"
export WORLD_APP_TEST_ASSET_EXIT=22
if verify_http_deployment_once https://arakoshi.example "$sha_a" >/dev/null 2>&1; then
  fail "an asset fetch failure must fail smoke verification"
fi
assert_equal 1 "$(grep -c '^https://arakoshi.example/$' "$fake_call_log")" "failed smoke verification should fetch the root once"
unset WORLD_APP_TEST_ASSET_EXIT
export PATH="$task_original_path"

real_jq=$(command -v jq || true)
if [ -n "$real_jq" ]; then
  kubernetes_state="$task_test_dir/fake-kubernetes"
  kubernetes_bin="$task_test_dir/fake-kubernetes-bin"
  mkdir -p "$kubernetes_state" "$kubernetes_bin"
  export WORLD_APP_TEST_KUBE_STATE="$kubernetes_state"
  export WORLD_APP_TEST_REAL_JQ="$real_jq"
  export WORLD_APP_TEST_KUBE_LOG="$kubernetes_state/commands.log"
  : > "$WORLD_APP_TEST_KUBE_LOG"

  cat > "$kubernetes_bin/microk8s" <<'FAKE_KUBERNETES'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORLD_APP_TEST_KUBE_LOG"
case " $* " in
  *" get deployment "*) cat "$WORLD_APP_TEST_KUBE_STATE/deployment.json" ;;
  *" replace -f "*)
    replacement=${!#}
    if [ "${WORLD_APP_TEST_REPLACE_FAIL:-0}" = 1 ]; then exit 1; fi
    "$WORLD_APP_TEST_REAL_JQ" '.metadata.resourceVersion = ((.metadata.resourceVersion | tonumber) + 1 | tostring)' \
      "$replacement" > "$WORLD_APP_TEST_KUBE_STATE/deployment.next.json"
    mv "$WORLD_APP_TEST_KUBE_STATE/deployment.next.json" "$WORLD_APP_TEST_KUBE_STATE/deployment.json"
    ;;
  *" rollout status "*)
    [ "${WORLD_APP_TEST_ROLLOUT_FAIL:-0}" != 1 ]
    ;;
  *) exit 2 ;;
esac
FAKE_KUBERNETES
  cat > "$kubernetes_bin/timeout" <<'FAKE_TIMEOUT'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >> "$WORLD_APP_TEST_KUBE_LOG"
[ "${1:-}" = --signal=TERM ] || exit 2
[ "${2:-}" = --kill-after=10s ] || exit 2
[ "${3:-}" = 210s ] || exit 2
shift 3
exec "$@"
FAKE_TIMEOUT
  chmod +x "$kubernetes_bin/microk8s" "$kubernetes_bin/timeout"
  export PATH="$kubernetes_bin:$task_original_path"

  original_deployment="$kubernetes_state/original.json"
  cat > "$original_deployment" <<EOF_DEPLOYMENT
{
  "apiVersion": "apps/v1",
  "kind": "Deployment",
  "metadata": {
    "name": "world-app",
    "namespace": "concrnt",
    "uid": "deployment-uid-1",
    "resourceVersion": "1",
    "labels": {"preserve": "label"},
    "annotations": {"preserve": "deployment-annotation"},
    "managedFields": [{"manager": "test"}]
  },
  "spec": {
    "replicas": 2,
    "selector": {"matchLabels": {"app": "world-app"}},
    "strategy": {"type": "Recreate"},
    "template": {
      "metadata": {
        "labels": {"app": "world-app"},
        "annotations": {"world-app.waon.me/source-revision": "old-revision", "preserve": "template-annotation"}
      },
      "spec": {
        "containers": [
          {
            "name": "world-app",
            "image": "localhost/world-app:$sha_a",
            "imagePullPolicy": "Always",
            "startupProbe": {"httpGet": {"path": "/old-start", "port": 8080}},
            "readinessProbe": {"httpGet": {"path": "/old-ready", "port": 8080}},
            "livenessProbe": {"httpGet": {"path": "/old-live", "port": 8080}}
          },
          {"name": "sidecar", "image": "example.invalid/sidecar:1", "imagePullPolicy": "Never"}
        ]
      }
    }
  },
  "status": {"availableReplicas": 2}
}
EOF_DEPLOYMENT
  cp "$original_deployment" "$kubernetes_state/deployment.json"

  transaction_state="$task_test_dir/transaction-state"
  mkdir -p "$transaction_state"
  record_sha_state "$transaction_state/deployed-sha" "$sha_a"
  transaction_dir=$(create_deployment_transaction "$transaction_state" "$original_deployment" world-app "$sha_b" "$sha_a")
  transaction_name=${transaction_dir##*/}
  "$real_jq" --arg target "$sha_b" --arg transaction_name "$transaction_name" '
    .metadata.resourceVersion = "2" |
    .spec.strategy = {"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}} |
    .spec.template.metadata.annotations["world-app.waon.me/source-revision"] = $target |
    .spec.template.metadata.annotations["world-app.waon.me/deploy-transaction"] = $transaction_name |
    (.spec.template.spec.containers[] | select(.name == "world-app")) |=
      (.image = ("localhost/world-app:" + $target) | .imagePullPolicy = "IfNotPresent" |
       .startupProbe.httpGet.path = "/new-start" | .readinessProbe.httpGet.path = "/new-ready" |
       .livenessProbe.httpGet.path = "/new-live")
  ' "$original_deployment" > "$kubernetes_state/deployment.json"
  cp "$kubernetes_state/deployment.json" "$transaction_dir/postpatch-deployment.json"
  # Simulate TERM after the target state rename but before the old success flag.
  record_sha_state "$transaction_state/deployed-sha" "$sha_b"
  restore_deployment_transaction concrnt world-app world-app "$transaction_state" localhost/world-app
  assert_equal "$sha_a" "$(read_sha_state "$transaction_state/deployed-sha")" "rollback must atomically restore the previous SHA"
  [ ! -e "$transaction_state/inflight" ] || fail "successful rollback must clear its journal"
  deployment_desired_state_matches "$original_deployment" "$kubernetes_state/deployment.json" ||
    fail "rollback did not restore the complete Deployment desired state"
  "$real_jq" -e '
    .metadata.labels.preserve == "label" and
    .metadata.annotations.preserve == "deployment-annotation" and
    .spec.replicas == 2 and
    .spec.selector.matchLabels.app == "world-app" and
    .spec.strategy.type == "Recreate" and
    .spec.template.metadata.annotations["world-app.waon.me/source-revision"] == "old-revision" and
    (.spec.template.spec.containers[] | select(.name == "world-app") |
      .imagePullPolicy == "Always" and .startupProbe.httpGet.path == "/old-start" and
      .readinessProbe.httpGet.path == "/old-ready" and .livenessProbe.httpGet.path == "/old-live") and
    ([.spec.template.spec.containers[] | select(.name == "sidecar")] | length == 1)
  ' "$kubernetes_state/deployment.json" >/dev/null || fail "rollback lost metadata, replicas, selector, strategy, annotation, probe, pull-policy, or sidecar state"
  grep -Fq "replace -f" "$WORLD_APP_TEST_KUBE_LOG" || fail "rollback did not use full Deployment replacement"
  grep -Fq "rollout status" "$WORLD_APP_TEST_KUBE_LOG" || fail "rollback did not wait for rollout"
  grep -Fq "timeout --signal=TERM --kill-after=10s 210s microk8s kubectl -n concrnt rollout status deployment/world-app --timeout=180s" \
    "$WORLD_APP_TEST_KUBE_LOG" || fail "rollback rollout must have a process-group hard timeout"

  # A config-only external update after our patch must block automatic rollback
  # instead of being overwritten by the saved snapshot.
  cp "$original_deployment" "$kubernetes_state/deployment.json"
  transaction_dir=$(create_deployment_transaction "$transaction_state" "$original_deployment" world-app "$sha_b" "$sha_a")
  transaction_name=${transaction_dir##*/}
  "$real_jq" --arg target "$sha_b" --arg transaction_name "$transaction_name" '
    .metadata.resourceVersion = "20" |
    .spec.template.metadata.annotations["world-app.waon.me/deploy-transaction"] = $transaction_name |
    (.spec.template.spec.containers[] | select(.name == "world-app")).image = ("localhost/world-app:" + $target)
  ' "$original_deployment" > "$transaction_dir/postpatch-deployment.json"
  "$real_jq" '.spec.replicas = 7 | .metadata.resourceVersion = "21"' \
    "$transaction_dir/postpatch-deployment.json" > "$kubernetes_state/deployment.json"
  : > "$WORLD_APP_TEST_KUBE_LOG"
  capture_status restore_deployment_transaction concrnt world-app world-app "$transaction_state" localhost/world-app
  [ "$captured_status" -ne 0 ] || fail "rollback overwrote an external postpatch Deployment change"
  [ -f "$transaction_state/inflight" ] || fail "an ambiguous postpatch Deployment must retain its journal"
  if grep -Fq "replace -f" "$WORLD_APP_TEST_KUBE_LOG"; then
    fail "ambiguous postpatch Deployment state reached kubectl replace"
  fi
  clear_deployment_transaction "$transaction_state"

  # A config-only update between the prepatch GET and conditional PATCH is also
  # outside the transaction and must not be reverted automatically.
  cp "$original_deployment" "$kubernetes_state/deployment.json"
  create_deployment_transaction "$transaction_state" "$original_deployment" world-app "$sha_b" "$sha_a" >/dev/null
  "$real_jq" '.metadata.resourceVersion = "30" | .metadata.labels.external = "preserve-me"' \
    "$original_deployment" > "$kubernetes_state/deployment.json"
  : > "$WORLD_APP_TEST_KUBE_LOG"
  capture_status restore_deployment_transaction concrnt world-app world-app "$transaction_state" localhost/world-app
  [ "$captured_status" -ne 0 ] || fail "rollback overwrote a prepatch external Deployment change"
  [ -f "$transaction_state/inflight" ] || fail "an ambiguous prepatch Deployment must retain its journal"
  if grep -Fq "replace -f" "$WORLD_APP_TEST_KUBE_LOG"; then
    fail "ambiguous prepatch Deployment state reached kubectl replace"
  fi
  clear_deployment_transaction "$transaction_state"

  # A failed rollback remains journaled and can be retried idempotently.
  cp "$original_deployment" "$kubernetes_state/deployment.json"
  create_deployment_transaction "$transaction_state" "$original_deployment" world-app "$sha_b" "$sha_a" >/dev/null
  export WORLD_APP_TEST_ROLLOUT_FAIL=1
  capture_status restore_deployment_transaction concrnt world-app world-app "$transaction_state" localhost/world-app
  [ "$captured_status" -ne 0 ] || fail "failed rollback rollout was reported successful"
  [ -f "$transaction_state/inflight" ] || fail "failed rollback must retain its recovery journal"
  unset WORLD_APP_TEST_ROLLOUT_FAIL
  restore_deployment_transaction concrnt world-app world-app "$transaction_state" localhost/world-app

  # Startup recovery recognizes a committed target and does not undo it.
  cp "$original_deployment" "$kubernetes_state/deployment.json"
  create_deployment_transaction "$transaction_state" "$original_deployment" world-app "$sha_b" "$sha_a" >/dev/null
  "$real_jq" --arg target "$sha_b" '
    .metadata.resourceVersion = "9" |
    (.spec.template.spec.containers[] | select(.name == "world-app")).image = ("localhost/world-app:" + $target)
  ' "$original_deployment" > "$kubernetes_state/deployment.json"
  record_sha_state "$transaction_state/deployed-sha" "$sha_b"
  recover_inflight_deployment concrnt world-app world-app "$transaction_state" localhost/world-app
  assert_equal "$sha_b" "$(read_sha_state "$transaction_state/deployed-sha")" "committed recovery must retain target state"
  [ ! -e "$transaction_state/inflight" ] || fail "committed recovery must clear stale journal"
  export PATH="$task_original_path"
else
  fail "jq is required; refusing to skip the full fake-Kubernetes rollback test"
fi

# Exercise the signal-masked commit point dynamically. The overridden atomic
# writer sends TERM after the target rename; commit must still finish coherently.
commit_harness="$task_test_dir/commit-signal.sh"
cat > "$commit_harness" <<'COMMIT_HARNESS'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$WORLD_APP_TEST_DEPLOY_LIB"
state_dir=$1
target_sha=$2
deployment_succeeded=false
deployment_mutated=true
record_sha_state() {
  local state_file=$1
  local value=$2
  printf '%s\n' "$value" > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
  kill -TERM "$$"
}
trap 'exit 91' TERM
commit_deployment_success "$state_dir" "$target_sha"
[ "$deployment_succeeded" = true ]
[ "$deployment_mutated" = false ]
[ "$(tr -d '\n' < "$state_dir/deployed-sha")" = "$target_sha" ]
COMMIT_HARNESS
chmod +x "$commit_harness"
commit_state="$task_test_dir/commit-state"
mkdir -p "$commit_state"
export WORLD_APP_TEST_DEPLOY_LIB="$deploy_library"
"$commit_harness" "$commit_state" "$sha_b" || fail "TERM interrupted the deployment commit point"

# A future post-patch early return must not report success merely because its
# rollback succeeded.
zero_exit_state="$task_test_dir/zero-exit-state"
mkdir -p "$zero_exit_state"
(
  state_dir=$zero_exit_state
  target_sha=$sha_b
  deployment_mutated=true
  deployment_succeeded=false
  record_failure_on_exit=true
  rollback_once() { return 0; }
  cleanup_attempt() { return 0; }
  set +e
  finish_deployment_actions 0
  [ "$?" -ne 0 ]
) || fail "an uncommitted post-patch exit must never be reported as success"

# Exercise the actual EXIT action router. A second TERM raised inside rollback
# must be ignored so rollback/state recording/cleanup all complete.
exit_harness="$task_test_dir/exit-rollback.sh"
cat > "$exit_harness" <<'EXIT_HARNESS'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$WORLD_APP_TEST_DEPLOY_LIB"
state_dir=$1
target_sha=$2
deployment_mutated=true
deployment_succeeded=false
record_failure_on_exit=true
rollback_once() {
  kill -TERM "$$"
  printf 'rollback\n' >> "$state_dir/actions"
}
cleanup_attempt() {
  printf 'cleanup\n' >> "$state_dir/actions"
}
finish() {
  local status=$?
  trap - EXIT
  trap '' INT TERM HUP
  set +e
  finish_deployment_actions "$status"
  status=$?
  exit "$status"
}
trap finish EXIT
trap 'exit 143' TERM
false
EXIT_HARNESS
chmod +x "$exit_harness"
exit_state="$task_test_dir/exit-state"
mkdir -p "$exit_state"
capture_status "$exit_harness" "$exit_state" "$sha_b"
assert_equal 1 "$captured_status" "EXIT rollback should preserve the original failure status"
assert_equal $'rollback\ncleanup' "$(cat "$exit_state/actions")" "EXIT rollback must finish rollback before cleanup"
assert_equal "$sha_b" "$(read_sha_state "$exit_state/last-failed-sha")" "EXIT rollback must record the failed target"

grep -Fq 'TimeoutStopSec=6min' "$service_unit" || fail "systemd must allow bounded API calls plus the 180 second rollback"
grep -Fq 'TimeoutStartSec=60min' "$service_unit" || fail "systemd must cover both build Jobs, rollout, and smoke verification"
grep -Fq 'KillMode=control-group' "$service_unit" || fail "systemd must interrupt the active child so the deployer TERM trap runs promptly"
grep -Fq 'wait_for_deployment_rollout "$production_namespace" "$deployment_name"' "$deploy_script" || fail "forward rollout must use the hard-bounded helper"
grep -Fq 'timeout --signal=TERM --kill-after=10s 210s' "$deploy_library" || fail "rollout helper must hard-bound the complete kubectl process group"
grep -Fq 'run_isolated_git clone --mirror --no-tags' "$deploy_script" || fail "fresh mirror clone must use isolated canonical Git transport"
grep -Fq 'run_isolated_git --git-dir="$repo_dir" fetch' "$deploy_script" || fail "mirror fetch must use isolated canonical Git transport"
grep -Fq 'require_fresh_mirror_config "$repo_dir"' "$deploy_script" || fail "each deployment must enforce the fresh mirror config allowlist"
grep -Fq 'require_mirror_without_object_indirection "$repo_dir"' "$deploy_script" || fail "deployment must reject replace, graft, shallow, and alternate object indirection"
grep -Fq 'run_trusted_git --git-dir="$repo_dir" worktree add' "$deploy_script" || fail "worktree creation must disable replacement objects"
grep -Fq 'hash-object --no-filters' "$deploy_library" || fail "worktree verification must compare raw bytes with canonical blob IDs"
grep -Fq '"resourceVersion": "$prepatch_resource_version"' "$deploy_script" || fail "Deployment patch must be conditional on the prepatch resourceVersion"
grep -Fq 'world-app.waon.me/deploy-transaction' "$deploy_script" || fail "Deployment patch must carry its transaction identity"

echo "deployer safety tests passed"

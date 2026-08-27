#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

base_dir="${WORLD_APP_DEPLOY_BASE:-/home/orange/world-app-deployer}"
repository_url="${WORLD_APP_REPOSITORY_URL:-https://github.com/waonme/world-app.git}"
namespace="${WORLD_APP_BUILD_NAMESPACE:-concrnt-build}"
production_namespace="${WORLD_APP_NAMESPACE:-concrnt}"
deployment_name="${WORLD_APP_DEPLOYMENT:-world-app}"
container_name="${WORLD_APP_CONTAINER:-world-app}"
node_image="node:22.22.1-bookworm@sha256:f90672bf4c76dfc077d17be4c115b1ae7731d2e8558b457d86bca42aeb193866"
buildkit_image="moby/buildkit:v0.32.2-rootless@sha256:504731e577c20559c00f968f33219f30115e70be29ab96728d1d06e963fc494b"
image_repository="localhost/world-app"
jq_version="1.8.2"
jq_amd64_sha256="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"
jq_arm64_sha256="8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309"

repo_dir="$base_dir/repository.git"
worktrees_dir="$base_dir/worktrees"
artifacts_dir="$base_dir/artifacts"
cache_dir="$base_dir/cache"
state_dir="$base_dir/state"
logs_dir="$base_dir/logs"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

mkdir -p "$worktrees_dir" "$artifacts_dir" "$cache_dir/corepack" "$cache_dir/pnpm" "$cache_dir/buildkit" "$state_dir" "$logs_dir"

# shellcheck source=deploy-lib.sh
source "$script_dir/deploy-lib.sh"

if ! command -v timeout >/dev/null 2>&1; then
  echo "GNU coreutils timeout is required for bounded Kubernetes rollout checks" >&2
  exit 1
fi

exec 9>"$state_dir/deploy.lock"
if ! flock -n 9; then
  echo "another world-app deployment is already running"
  exit 0
fi

target_sha=""
deployment_succeeded=false
deployment_mutated=false
record_failure_on_exit=true
rollback_attempted=false
worktree_dir=""
attempt_dir=""
build_job=""
image_job=""

rollback_once() {
  if [ "$rollback_attempted" = true ]; then
    return 0
  fi
  rollback_attempted=true

  echo "deployment verification failed; restoring the saved Deployment snapshot" >&2
  if ! restore_deployment_transaction "$production_namespace" "$deployment_name" "$container_name" "$state_dir" "$image_repository"; then
    echo "full Deployment rollback failed; inflight journal retained" >&2
    return 1
  fi
  deployment_mutated=false
}

cleanup_attempt() {
  local cleanup_failed=false

  if [ -n "$build_job" ] || [ -n "$image_job" ]; then
    if ! microk8s kubectl -n "$namespace" delete job "$build_job" "$image_job" --ignore-not-found=true --wait=true >/dev/null 2>&1; then
      echo "failed to delete deployment build Jobs" >&2
      cleanup_failed=true
    fi
  fi

  if [ -n "$worktree_dir" ] && [ -e "$worktree_dir" ]; then
    if ! git --git-dir="$repo_dir" worktree remove --force "$worktree_dir" >/dev/null 2>&1; then
      echo "failed to unregister deployment worktree: $worktree_dir" >&2
      cleanup_failed=true
    fi
    if [ -e "$worktree_dir" ] && ! safe_remove_deploy_path "$worktree_dir" "$worktrees_dir"; then
      cleanup_failed=true
    fi
  fi

  if [ -n "$attempt_dir" ]; then
    if ! safe_remove_deploy_path "$attempt_dir" "$artifacts_dir"; then
      cleanup_failed=true
    fi
  fi

  if [ "$cleanup_failed" = true ]; then
    mark_cleanup_issue "$state_dir" "current deployment attempt cleanup failed" || true
    return 1
  fi
}

finish_deployment() {
  local exit_code=$?
  trap - EXIT
  trap '' INT TERM HUP
  set +e
  finish_deployment_actions "$exit_code"
  exit_code=$?
  exit "$exit_code"
}
trap finish_deployment EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

require_github_repository_url "$repository_url" waonme/world-app "WORLD_APP_REPOSITORY_URL"

if [ ! -d "$repo_dir" ]; then
  for abandoned_clone in "$base_dir"/.repository.git.clone.*; do
    [ -d "$abandoned_clone" ] || continue
    case "${abandoned_clone##*/}" in
      .repository.git.clone.?*) rm -rf -- "$abandoned_clone" ;;
      *) echo "refusing unexpected mirror clone path: $abandoned_clone" >&2; exit 1 ;;
    esac
  done
  mirror_clone_dir=$(mktemp -d "$base_dir/.repository.git.clone.XXXXXXXX")
  if ! run_isolated_git clone --mirror https://github.com/waonme/world-app.git "$mirror_clone_dir"; then
    rm -rf -- "$mirror_clone_dir"
    exit 1
  fi
  require_mirror_origin_repository "$mirror_clone_dir" waonme/world-app
  require_mirror_without_url_rewrites "$mirror_clone_dir"
  mv "$mirror_clone_dir" "$repo_dir"
fi

if [ "$(git --git-dir="$repo_dir" rev-parse --is-bare-repository 2>/dev/null || true)" != true ]; then
  echo "refusing incomplete or non-bare deployment mirror: $repo_dir" >&2
  exit 1
fi
require_mirror_origin_repository "$repo_dir" waonme/world-app
require_mirror_without_url_rewrites "$repo_dir"

# Resolve any transaction left by TERM, SIGKILL, or power loss before starting
# another build. A committed state is retained; an uncommitted state is fully
# restored from its saved Deployment object.
recover_inflight_deployment "$production_namespace" "$deployment_name" "$container_name" "$state_dir" "$image_repository"
startup_cleanup_failed=false
if ! cleanup_orphaned_transactions "$state_dir"; then
  startup_cleanup_failed=true
  mark_cleanup_issue "$state_dir" "orphaned deployment transaction cleanup failed" || true
fi

# Stop stale Jobs before reclaiming their hostPath worktrees and artifacts.
microk8s kubectl create namespace "$namespace" --dry-run=client -o yaml | microk8s kubectl apply -f -
if ! microk8s kubectl -n "$namespace" delete job -l "app.kubernetes.io/part-of=world-app" --ignore-not-found=true --wait=true; then
  echo "failed to stop stale deployment build Jobs; refusing hostPath cleanup" >&2
  exit 1
fi
if ! cleanup_stale_deploy_attempts "$repo_dir" "$worktrees_dir" "$artifacts_dir"; then
  startup_cleanup_failed=true
  echo "stale deployment directory cleanup is incomplete; continuing with a fresh isolated attempt" >&2
  mark_cleanup_issue "$state_dir" "stale deployment directory cleanup failed" || true
fi
if [ "$startup_cleanup_failed" = false ]; then
  rm -f -- "$state_dir/cleanup-required"
fi

require_mirror_without_url_rewrites "$repo_dir"
run_isolated_git --git-dir="$repo_dir" fetch --no-tags --prune \
    https://github.com/waonme/world-app.git '+refs/heads/main:refs/remotes/origin/main'
target_sha=$(git --git-dir="$repo_dir" rev-parse 'refs/remotes/origin/main^{commit}')
if [[ ! "$target_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refusing invalid target commit: $target_sha" >&2
  exit 1
fi

current_image=$(microk8s kubectl -n "$production_namespace" get deployment "$deployment_name" -o "jsonpath={.spec.template.spec.containers[?(@.name=='$container_name')].image}")
recorded_deployed_sha=""
if [ -f "$state_dir/deployed-sha" ]; then
  recorded_deployed_sha=$(read_sha_state "$state_dir/deployed-sha") || exit 1
fi
if ! deployed_sha=$(resolve_deployed_sha "$recorded_deployed_sha" "$current_image" "$image_repository" "${WORLD_APP_ALLOW_INITIAL_BOOTSTRAP:-0}"); then
  exit 1
fi
if [ -z "$recorded_deployed_sha" ] && [ -n "$deployed_sha" ]; then
  record_sha_state "$state_dir/deployed-sha" "$deployed_sha"
  recorded_deployed_sha=$deployed_sha
fi
expected_image="localhost/world-app:$target_sha"

# A normal revert remains a descendant and is allowed. A reset/force-push is not:
# production must never follow rewritten main history without an explicit operator recovery.
if [ -n "$deployed_sha" ]; then
  require_fast_forward_update "$repo_dir" "$deployed_sha" "$target_sha"
fi

if [ "$deployed_sha" = "$target_sha" ] && [ "$current_image" = "$expected_image" ]; then
  echo "world-app is already deployed at $target_sha"
  deployment_succeeded=true
  exit 0
fi

now=$(date +%s)
if backoff_remaining=$(retry_backoff_remaining "$state_dir/last-failed-sha" "$target_sha" "$now" 600); then
  echo "deployment of $target_sha is in retry backoff for another ${backoff_remaining}s" >&2
  # This is an observable temporary failure. Do not rewrite last-failed-sha,
  # because doing so would extend the retry window on every timer invocation.
  record_failure_on_exit=false
  exit 75
else
  backoff_status=$?
  if [ "$backoff_status" -eq 2 ]; then
    exit 1
  fi
fi

short_sha=${target_sha:0:12}
attempt_dir=$(mktemp -d "$artifacts_dir/deploy-$short_sha.XXXXXXXX")
attempt_name=$(basename "$attempt_dir")
worktree_dir="$worktrees_dir/$attempt_name"
artifact_dir="$attempt_dir"
context_dir="$artifact_dir/context"
image_archive="$artifact_dir/world-app-$target_sha.oci.tar"
build_job="world-app-pnpm-builder"
image_job="world-app-image-builder"

git --git-dir="$repo_dir" worktree add --detach "$worktree_dir" "$target_sha"
verify_exact_worktree "$repo_dir" "$worktree_dir" "$target_sha"

cat <<YAML | microk8s kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: world-app-build-budget
  namespace: $namespace
spec:
  hard:
    pods: "4"
    requests.cpu: "3"
    requests.memory: 3Gi
    limits.cpu: "3"
    limits.memory: 3Gi
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: world-app-build-isolation
  namespace: $namespace
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 100.64.0.0/10
              - 127.0.0.0/8
              - 169.254.0.0/16
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - {protocol: TCP, port: 80}
        - {protocol: TCP, port: 443}
YAML

cat <<YAML | microk8s kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $build_job
  namespace: $namespace
  labels:
    app.kubernetes.io/name: world-app-vps-builder
    app.kubernetes.io/part-of: world-app
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: world-app-vps-builder
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: pnpm-build
          image: $node_image
          imagePullPolicy: IfNotPresent
          workingDir: /workspace
          command: ["/bin/bash", "-lc"]
          args:
            - |
              set -Eeuo pipefail
              export COREPACK_HOME=/cache/corepack
              export PNPM_HOME=/cache/pnpm
              export XDG_CONFIG_HOME=/tmp/world-app-xdg/config
              export XDG_CACHE_HOME=/tmp/world-app-xdg/cache
              export XDG_DATA_HOME=/tmp/world-app-xdg/data
              export NODE_OPTIONS=--max-old-space-size=1536
              export HUSKY=0
              mkdir -p "\$COREPACK_HOME" "\$PNPM_HOME" "\$XDG_CONFIG_HOME" "\$XDG_CACHE_HOME" "\$XDG_DATA_HOME" /cache/pnpm-store /tmp/corepack-bin /tmp/world-app-tools
              case "\$(uname -m)" in
                x86_64)
                  jq_asset=jq-linux-amd64
                  jq_checksum=$jq_amd64_sha256
                  ;;
                aarch64 | arm64)
                  jq_asset=jq-linux-arm64
                  jq_checksum=$jq_arm64_sha256
                  ;;
                *)
                  echo "unsupported architecture for pinned jq: \$(uname -m)" >&2
                  exit 1
                  ;;
              esac
              curl -fsSL --retry 3 --max-time 60 \
                "https://github.com/jqlang/jq/releases/download/jq-$jq_version/\$jq_asset" \
                -o /tmp/world-app-tools/jq
              printf '%s  %s\n' "\$jq_checksum" /tmp/world-app-tools/jq | sha256sum -c -
              chmod 0755 /tmp/world-app-tools/jq
              corepack enable --install-directory /tmp/corepack-bin
              export PATH=/tmp/world-app-tools:/tmp/corepack-bin:\$PATH
              jq --version
              pnpm config set store-dir /cache/pnpm-store
              pnpm install --frozen-lockfile
              bash -n ops/vps-deployer/deploy.sh ops/vps-deployer/deploy-lib.sh ops/vps-deployer/test-deploy.sh
              ops/vps-deployer/test-deploy.sh
              scripts/test-prepare-upstream-sync.sh
              scripts/check-fork-contract.sh
              pnpm --filter @concrnt/client test
              pnpm --filter @concrnt/worldlib test:fork
              pnpm --filter @concrnt/ui test:popover
              pnpm --filter web test:fork
              pnpm --workspace-concurrency=1 --filter web... build
              test -s web/dist/index.html
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
          volumeMounts:
            - name: workspace
              mountPath: /workspace
            - name: cache
              mountPath: /cache
            - name: deployment-home
              mountPath: $base_dir
              readOnly: true
      volumes:
        - name: workspace
          hostPath:
            path: $worktree_dir
            type: Directory
        - name: cache
          hostPath:
            path: $cache_dir
            type: Directory
        - name: deployment-home
          hostPath:
            path: $base_dir
            type: Directory
YAML

if ! wait_for_job "$namespace" "$build_job" 1800; then
  microk8s kubectl -n "$namespace" logs "job/$build_job" --all-containers=true > "$logs_dir/$target_sha-pnpm.log" 2>&1 || true
  microk8s kubectl -n "$namespace" get pods -l "job-name=$build_job" -o wide || true
  tail -n 200 "$logs_dir/$target_sha-pnpm.log" || true
  exit 1
fi
microk8s kubectl -n "$namespace" logs "job/$build_job" --all-containers=true > "$logs_dir/$target_sha-pnpm.log"

# The build may create ignored outputs, but it must not alter tracked source or
# move HEAD. This prevents a writable reused workspace from being mislabeled.
verify_exact_worktree "$repo_dir" "$worktree_dir" "$target_sha"

mkdir -p "$context_dir/web"
cp "$worktree_dir/web/Dockerfile" "$context_dir/web/Dockerfile"
cp "$worktree_dir/web/nginx.conf" "$context_dir/web/nginx.conf"
cp -a "$worktree_dir/web/dist" "$context_dir/web/dist"

cat <<YAML | microk8s kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $image_job
  namespace: $namespace
  labels:
    app.kubernetes.io/name: world-app-vps-image-builder
    app.kubernetes.io/part-of: world-app
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: world-app-vps-image-builder
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: buildkit
          image: $buildkit_image
          imagePullPolicy: IfNotPresent
          command: ["buildctl-daemonless.sh"]
          args:
            - build
            - --frontend=dockerfile.v0
            - --local=context=/context
            - --local=dockerfile=/context/web
            - --opt=filename=Dockerfile
            - --opt=build-arg:VERSION=$target_sha
            - --output=type=oci,name=localhost/world-app:$target_sha,dest=/output/world-app-$target_sha.oci.tar
          env:
            - name: BUILDKITD_FLAGS
              value: --oci-worker-no-process-sandbox --oci-worker-snapshotter=native
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            seccompProfile:
              type: Unconfined
            appArmorProfile:
              type: Unconfined
          volumeMounts:
            - name: context
              mountPath: /context
              readOnly: true
            - name: output
              mountPath: /output
            - name: buildkit-cache
              mountPath: /home/user/.local/share/buildkit
      volumes:
        - name: context
          hostPath:
            path: $context_dir
            type: Directory
        - name: output
          hostPath:
            path: $artifact_dir
            type: Directory
        - name: buildkit-cache
          hostPath:
            path: $cache_dir/buildkit
            type: Directory
YAML

if ! wait_for_job "$namespace" "$image_job" 900; then
  microk8s kubectl -n "$namespace" logs "job/$image_job" --all-containers=true > "$logs_dir/$target_sha-image.log" 2>&1 || true
  microk8s kubectl -n "$namespace" get pods -l "job-name=$image_job" -o wide || true
  tail -n 200 "$logs_dir/$target_sha-image.log" || true
  exit 1
fi
microk8s kubectl -n "$namespace" logs "job/$image_job" --all-containers=true > "$logs_dir/$target_sha-image.log"
test -s "$image_archive"

microk8s ctr images import "$image_archive"
microk8s ctr images ls -q | grep -Fx "$expected_image"

# Re-read production immediately before mutation. The build can run for many
# minutes; never roll back to a stale pre-build image/spec if an operator changed
# production while it was building.
prepatch_snapshot="$attempt_dir/prepatch-deployment.json"
microk8s kubectl --request-timeout=20s -n "$production_namespace" get deployment "$deployment_name" -o json > "$prepatch_snapshot"
prepatch_image=$(deployment_container_image "$prepatch_snapshot" "$container_name")
prepatch_resource_version=$(jq -er '.metadata.resourceVersion' "$prepatch_snapshot")
prepatch_uid=$(jq -er '.metadata.uid' "$prepatch_snapshot")
prepatch_recorded_sha=""
if [ -f "$state_dir/deployed-sha" ]; then
  prepatch_recorded_sha=$(read_sha_state "$state_dir/deployed-sha")
fi
if ! prepatch_deployed_sha=$(resolve_deployed_sha "$prepatch_recorded_sha" "$prepatch_image" "$image_repository" "${WORLD_APP_ALLOW_INITIAL_BOOTSTRAP:-0}"); then
  exit 1
fi
if [ "$prepatch_deployed_sha" != "$deployed_sha" ]; then
  echo "production deployment state changed during the build; refusing stale rollout" >&2
  exit 1
fi
if [ -z "$deployed_sha" ] && [ "$prepatch_image" != "$current_image" ]; then
  echo "bootstrap source image changed during the build; refusing stale rollout" >&2
  exit 1
fi
transaction_dir=$(create_deployment_transaction "$state_dir" "$prepatch_snapshot" "$container_name" "$target_sha" "$prepatch_deployed_sha")
transaction_name=${transaction_dir##*/}

# Mark the Deployment as potentially changed before patching. From this point,
# every non-successful exit is routed through finish_deployment and rollback_once.
deployment_mutated=true
microk8s kubectl --request-timeout=30s -n "$production_namespace" patch deployment "$deployment_name" --type=strategic -o json -p "$(cat <<JSON
{
  "metadata": {
    "resourceVersion": "$prepatch_resource_version"
  },
  "spec": {
    "strategy": {
      "type": "RollingUpdate",
      "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}
    },
    "template": {
      "metadata": {
        "annotations": {
          "world-app.waon.me/source-revision": "$target_sha",
          "world-app.waon.me/deploy-transaction": "$transaction_name"
        }
      },
      "spec": {
        "containers": [{
          "name": "$container_name",
          "image": "$expected_image",
          "imagePullPolicy": "IfNotPresent",
          "startupProbe": {
            "httpGet": {"path": "/web/index.html", "port": 80},
            "periodSeconds": 2,
            "timeoutSeconds": 2,
            "failureThreshold": 30
          },
          "readinessProbe": {
            "httpGet": {"path": "/web/index.html", "port": 80},
            "periodSeconds": 3,
            "timeoutSeconds": 2,
            "failureThreshold": 3
          },
          "livenessProbe": {
            "httpGet": {"path": "/web/index.html", "port": 80},
            "initialDelaySeconds": 10,
            "periodSeconds": 10,
            "timeoutSeconds": 2,
            "failureThreshold": 3
          }
        }]
      }
    }
  }
}
JSON
)" > "$transaction_dir/postpatch-deployment.json"
validate_transaction_postpatch "$transaction_dir" "$prepatch_uid" "$container_name" "$image_repository" "$target_sha"

if ! wait_for_deployment_rollout "$production_namespace" "$deployment_name"; then
  exit 1
fi

smoke_ok=false
for attempt in $(seq 1 20); do
  if verify_http_deployment_once https://arakoshi.com "$target_sha"; then
    smoke_ok=true
    break
  fi
  echo "smoke verification attempt $attempt did not observe $target_sha"
  sleep 3
done

if [ "$smoke_ok" != true ]; then
  exit 1
fi

commit_deployment_success "$state_dir" "$target_sha"
echo "world-app $target_sha deployed and verified"

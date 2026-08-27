#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

base_dir="${WORLD_APP_DEPLOY_BASE:-/home/orange/world-app-deployer}"
repository_url="${WORLD_APP_REPOSITORY_URL:-https://github.com/waonme/world-app.git}"
namespace="${WORLD_APP_BUILD_NAMESPACE:-concrnt-build}"
production_namespace="${WORLD_APP_NAMESPACE:-concrnt}"
deployment_name="${WORLD_APP_DEPLOYMENT:-world-app}"
container_name="${WORLD_APP_CONTAINER:-world-app}"
node_image="node:22.22.1-bookworm-slim@sha256:4f77a690f2f8946ab16fe1e791a3ac0667ae1c3575c3e4d0d4589e9ed5bfaf3d"
buildkit_image="moby/buildkit:v0.32.2-rootless@sha256:504731e577c20559c00f968f33219f30115e70be29ab96728d1d06e963fc494b"

repo_dir="$base_dir/repository.git"
worktrees_dir="$base_dir/worktrees"
artifacts_dir="$base_dir/artifacts"
cache_dir="$base_dir/cache"
state_dir="$base_dir/state"
logs_dir="$base_dir/logs"

mkdir -p "$worktrees_dir" "$artifacts_dir" "$cache_dir/corepack" "$cache_dir/pnpm" "$cache_dir/buildkit" "$state_dir" "$logs_dir"

wait_for_job() {
  local job_namespace=$1
  local job_name=$2
  local timeout_seconds=$3
  local deadline=$((SECONDS + timeout_seconds))

  while [ "$SECONDS" -lt "$deadline" ]; do
    local status
    status=$(microk8s kubectl -n "$job_namespace" get job "$job_name" -o json)
    if [ "$(printf '%s' "$status" | jq -r '.status.succeeded // 0')" -ge 1 ]; then
      return 0
    fi
    if [ "$(printf '%s' "$status" | jq -r '.status.failed // 0')" -ge 1 ]; then
      return 1
    fi
    sleep 2
  done
  return 124
}

exec 9>"$state_dir/deploy.lock"
if ! flock -n 9; then
  echo "another world-app deployment is already running"
  exit 0
fi

target_sha=""
deployment_succeeded=false

mark_failure() {
  local exit_code=$?
  if [ "$deployment_succeeded" != true ] && [ -n "$target_sha" ]; then
    printf '%s\n' "$target_sha" > "$state_dir/last-failed-sha"
  fi
  exit "$exit_code"
}
trap mark_failure EXIT

if [ ! -d "$repo_dir" ]; then
  git clone --mirror "$repository_url" "$repo_dir"
fi

git --git-dir="$repo_dir" fetch --prune origin '+refs/heads/main:refs/remotes/origin/main'
target_sha=$(git --git-dir="$repo_dir" rev-parse 'refs/remotes/origin/main^{commit}')
if [[ ! "$target_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refusing invalid target commit: $target_sha" >&2
  exit 1
fi

current_image=$(microk8s kubectl -n "$production_namespace" get deployment "$deployment_name" -o "jsonpath={.spec.template.spec.containers[?(@.name=='$container_name')].image}")
deployed_sha=$(test -f "$state_dir/deployed-sha" && tr -d '\n' < "$state_dir/deployed-sha" || true)
expected_image="localhost/world-app:$target_sha"

if [ "$deployed_sha" = "$target_sha" ] && [ "$current_image" = "$expected_image" ]; then
  echo "world-app is already deployed at $target_sha"
  deployment_succeeded=true
  exit 0
fi

if [ -f "$state_dir/last-failed-sha" ] && [ "$(tr -d '\n' < "$state_dir/last-failed-sha")" = "$target_sha" ]; then
  failed_at=$(stat -c %Y "$state_dir/last-failed-sha")
  now=$(date +%s)
  if [ $((now - failed_at)) -lt 600 ]; then
    echo "deployment of $target_sha is in a 10 minute retry backoff"
    deployment_succeeded=true
    exit 0
  fi
fi

short_sha=${target_sha:0:12}
worktree_dir="$worktrees_dir/$target_sha"
artifact_dir="$artifacts_dir/$target_sha"
context_dir="$artifact_dir/context"
image_archive="$artifact_dir/world-app-$target_sha.oci.tar"
build_job="world-app-pnpm-$short_sha"
image_job="world-app-image-$short_sha"

if [ ! -d "$worktree_dir/.git" ] && [ ! -f "$worktree_dir/.git" ]; then
  rm -rf "$worktree_dir"
  git --git-dir="$repo_dir" worktree add --detach "$worktree_dir" "$target_sha"
fi

microk8s kubectl create namespace "$namespace" --dry-run=client -o yaml | microk8s kubectl apply -f -
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
microk8s kubectl -n "$namespace" delete job "$build_job" "$image_job" --ignore-not-found=true --wait=true

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
              export HOME=/tmp/home
              export COREPACK_HOME=/cache/corepack
              export PNPM_HOME=/cache/pnpm
              export NODE_OPTIONS=--max-old-space-size=1536
              mkdir -p "\$HOME" "\$COREPACK_HOME" "\$PNPM_HOME" /tmp/corepack-bin
              corepack enable --install-directory /tmp/corepack-bin
              export PATH=/tmp/corepack-bin:\$PATH
              pnpm install --frozen-lockfile
              pnpm build
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
      volumes:
        - name: workspace
          hostPath:
            path: $worktree_dir
            type: Directory
        - name: cache
          hostPath:
            path: $cache_dir
            type: Directory
YAML

if ! wait_for_job "$namespace" "$build_job" 1800; then
  microk8s kubectl -n "$namespace" logs "job/$build_job" --all-containers=true > "$logs_dir/$target_sha-pnpm.log" 2>&1 || true
  microk8s kubectl -n "$namespace" get pods -l "job-name=$build_job" -o wide || true
  tail -n 200 "$logs_dir/$target_sha-pnpm.log" || true
  exit 1
fi
microk8s kubectl -n "$namespace" logs "job/$build_job" --all-containers=true > "$logs_dir/$target_sha-pnpm.log"

rm -rf "$context_dir"
mkdir -p "$context_dir/web"
cp "$worktree_dir/web/Dockerfile" "$context_dir/web/Dockerfile"
cp "$worktree_dir/web/nginx.conf" "$context_dir/web/nginx.conf"
cp -a "$worktree_dir/web/dist" "$context_dir/web/dist"
rm -f "$image_archive"

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

previous_image="$current_image"
printf '%s\n' "$previous_image" > "$state_dir/previous-image"

rollback() {
  echo "deployment verification failed; restoring $previous_image" >&2
  microk8s kubectl -n "$production_namespace" set image "deployment/$deployment_name" "$container_name=$previous_image"
  microk8s kubectl -n "$production_namespace" rollout status "deployment/$deployment_name" --timeout=180s
}

microk8s kubectl -n "$production_namespace" patch deployment "$deployment_name" --type=strategic -p "$(cat <<JSON
{
  "spec": {
    "strategy": {
      "type": "RollingUpdate",
      "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}
    },
    "template": {
      "metadata": {
        "annotations": {"world-app.waon.me/source-revision": "$target_sha"}
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
)"

if ! microk8s kubectl -n "$production_namespace" rollout status "deployment/$deployment_name" --timeout=180s; then
  rollback
  exit 1
fi

smoke_ok=false
for attempt in $(seq 1 20); do
  info=$(curl -fsS --max-time 10 https://arakoshi.com/cc-info 2>/dev/null || true)
  version=$(printf '%s' "$info" | jq -r '.version // empty' 2>/dev/null || true)
  if [ "$version" = "$target_sha" ] && curl -fsS --max-time 10 https://arakoshi.com/ >/dev/null; then
    asset_path=$(curl -fsS --max-time 10 https://arakoshi.com/ | sed -n 's/.*src="\([^"]*\/assets\/[^"]*\.js\)".*/\1/p' | head -n 1)
    if [ -n "$asset_path" ] && curl -fsS --max-time 10 "https://arakoshi.com$asset_path" >/dev/null; then
      smoke_ok=true
      break
    fi
  fi
  echo "smoke verification attempt $attempt did not observe $target_sha"
  sleep 3
done

if [ "$smoke_ok" != true ]; then
  rollback
  exit 1
fi

printf '%s\n' "$target_sha" > "$state_dir/deployed-sha"
rm -f "$state_dir/last-failed-sha"
deployment_succeeded=true
echo "world-app $target_sha deployed and verified"
